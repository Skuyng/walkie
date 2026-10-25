const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { WebSocketServer } = require('ws');

const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript',
  '.json': 'application/manifest+json',
  '.png': 'image/png'
};
const secretsPath = path.join(__dirname, 'room-secrets.json');

function loadSecrets() {
  try {
    const parsed = JSON.parse(fs.readFileSync(secretsPath, 'utf8'));
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    return {};
  }
}

function saveSecrets(secrets) {
  try {
    fs.writeFileSync(secretsPath, JSON.stringify(secrets));
  } catch (error) {
    console.error('Could not store room secrets:', error.message);
  }
}

let secrets = loadSecrets();

function normRoom(value) {
  return String(value || '').trim().toLowerCase().slice(0, 40);
}

function normName(value) {
  return String(value || '').trim().slice(0, 30);
}

function normPassword(value) {
  if (value == null) return '';
  return String(value).slice(0, 80);
}

function hashSecret(password) {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(password, salt, 32).toString('hex');
  return { salt, hash };
}

function secretMatches(password, record) {
  if (!record || !password) return false;
  const actual = crypto.scryptSync(password, record.salt, 32);
  const expected = Buffer.from(record.hash, 'hex');
  if (actual.length !== expected.length) return false;
  return crypto.timingSafeEqual(actual, expected);
}

const srv = http.createServer((q, r) => {
  let p = q.url.split('?')[0];
  if (p === '/') p = '/index.html';
  const f = path.join(__dirname, 'public', path.normalize(p));
  fs.readFile(f, (e, d) => {
    if (e) {
      r.writeHead(404);
      return r.end();
    }
    r.writeHead(200, {
      'Content-Type': types[path.extname(f)] || 'application/octet-stream',
      'Cache-Control': 'no-cache'
    });
    r.end(d);
  });
});

const wss = new WebSocketServer({ server: srv });

function listening(client, room) {
  return !!(client.rooms && client.rooms.has(room));
}

function authed(client, room) {
  return !!(client.auth && client.auth.has(room));
}

function bc(room, data, except, bin) {
  for (const client of wss.clients) {
    if (client === except || client.readyState !== 1) continue;
    if (bin) {
      if (!listening(client, room) || !authed(client, room)) continue;
    } else if (!authed(client, room)) {
      continue;
    }
    client.send(data, { binary: bin });
  }
}

function memberNames(room) {
  const names = [];
  for (const client of wss.clients) {
    if (client.readyState === 1 && authed(client, room) && client.name) names.push(client.name);
  }
  return names;
}

/// Online members of one room. Only sockets authorized for that room receive it.
function sendUsers(room) {
  bc(room, JSON.stringify({ t: 'users', room, users: memberNames(room) }), null, false);
}

function sendError(ws, room) {
  if (ws.readyState !== 1) return;
  ws.send(JSON.stringify({ t: 'error', room, error: 'Feil passord' }));
}

function evictOthers(room, except) {
  for (const client of wss.clients) {
    if (client === except) continue;
    const hadAuth = !!(client.auth && client.auth.has(room));
    const hadListen = !!(client.rooms && client.rooms.has(room));
    const hadTalk = client.talk === room;
    if (!hadAuth && !hadListen && !hadTalk) continue;
    sendError(client, room);
    if (client.auth) client.auth.delete(room);
    if (client.rooms) client.rooms.delete(room);
    if (hadTalk) {
      client.talk = firstRoom(client.auth) || '';
      client.room = client.talk;
    }
  }
}

function firstRoom(set) {
  if (!set || set.size === 0) return '';
  return set.values().next().value || '';
}

function authorize(room, password, create, ws) {
  const existing = secrets[room];
  if (existing) return secretMatches(password, existing);
  if (create && password) {
    secrets[room] = hashSecret(password);
    saveSecrets(secrets);
    evictOthers(room, ws);
  }
  return true;
}

function ensureSets(ws) {
  if (!ws.auth) ws.auth = new Set();
  if (!ws.rooms) ws.rooms = new Set();
}

function applyGroups(ws, message) {
  ensureSets(ws);
  const name = normName(message.name);
  if (name) ws.name = name;
  const prevAuth = new Set(ws.auth);
  const prevListen = new Set(ws.rooms);
  const nextAuth = new Set();
  const nextListen = new Set();
  const entries = Array.isArray(message.groups) ? message.groups : [];
  for (const entry of entries) {
    const room = normRoom(entry && entry.room);
    if (!room) continue;
    const password = normPassword(entry.password);
    const create = !!entry.create;
    if (!authorize(room, password, create, ws)) {
      sendError(ws, room);
      continue;
    }
    nextAuth.add(room);
    if (entry.listen !== false) nextListen.add(room);
  }
  ws.multi = true;
  ws.auth = nextAuth;
  ws.rooms = nextListen;
  const talk = normRoom(message.talk);
  if (talk && nextAuth.has(talk)) ws.talk = talk;
  else if (!talk) ws.talk = firstRoom(nextListen) || firstRoom(nextAuth);
  else ws.talk = '';
  ws.room = ws.talk || '';
  const affected = new Set([...prevAuth, ...nextAuth, ...prevListen]);
  for (const room of affected) sendUsers(room);
  for (const room of prevListen) {
    if (!nextListen.has(room) && ws.name) {
      bc(room, JSON.stringify({ t: 'stop', name: ws.name, room }), null, false);
    }
  }
}

function applyLegacyJoin(ws, message) {
  ensureSets(ws);
  const name = normName(message.name);
  if (name) ws.name = name;
  const room = normRoom(message.room);
  const password = normPassword(message.password);
  if (ws.multi) {
    if (room && authed(ws, room)) {
      ws.talk = room;
      ws.room = room;
    }
    return;
  }
  if (!room || !ws.name) return;
  if (!authorize(room, password, false, ws)) {
    sendError(ws, room);
    return;
  }
  const prev = new Set([...ws.auth, ...ws.rooms]);
  ws.auth = new Set([room]);
  ws.rooms = new Set([room]);
  ws.talk = room;
  ws.room = room;
  prev.add(room);
  for (const id of prev) sendUsers(id);
}

wss.on('connection', (ws) => {
  ws.isAlive = true;
  ws.auth = new Set();
  ws.rooms = new Set();
  ws.talk = '';
  ws.room = '';
  ws.multi = false;
  ws.on('pong', () => {
    ws.isAlive = true;
  });
  ws.on('message', (d, isBin) => {
    if (isBin) {
      const room = ws.talk;
      if (room && authed(ws, room)) bc(room, d, ws, true);
      return;
    }
    let message;
    try {
      message = JSON.parse(d);
    } catch {
      return;
    }
    if (!message || typeof message.t !== 'string') return;
    if (message.t === 'groups' || message.t === 'listen') {
      applyGroups(ws, message);
      return;
    }
    if (message.t === 'join') {
      applyLegacyJoin(ws, message);
      return;
    }
    if (message.t === 'talk') {
      const room = normRoom(message.room);
      const password = normPassword(message.password);
      if (!room) return;
      if (!authorize(room, password, false, ws)) {
        sendError(ws, room);
        return;
      }
      ensureSets(ws);
      const added = !ws.auth.has(room);
      ws.auth.add(room);
      ws.talk = room;
      ws.room = room;
      if (added) sendUsers(room);
      return;
    }
    if (message.t === 'start' || message.t === 'stop') {
      const room = normRoom(message.room) || ws.talk;
      if (!room || !ws.name || !authed(ws, room)) return;
      if (ws.talk && ws.talk !== room) return;
      bc(room, JSON.stringify({ t: message.t, name: ws.name, room }), ws, false);
    }
  });
  ws.on('close', () => {
    const name = ws.name;
    const rooms = new Set([...(ws.auth || []), ...(ws.rooms || [])]);
    ws.auth = new Set();
    ws.rooms = new Set();
    for (const room of rooms) {
      if (name) bc(room, JSON.stringify({ t: 'stop', name, room }), null, false);
      sendUsers(room);
    }
  });
});

setInterval(() => {
  for (const client of wss.clients) {
    if (!client.isAlive) client.terminate();
    client.isAlive = false;
    client.ping();
  }
}, 20000);

const port = process.env.PORT || 8080;
srv.listen(port, () => console.log('listening ' + port));
