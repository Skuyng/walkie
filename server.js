const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { WebSocketServer } = require('ws');
const { openStore, StoreError } = require('./store');

const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript',
  '.json': 'application/manifest+json',
  '.png': 'image/png'
};

function normRoom(value) {
  return String(value || '').trim().toLowerCase().slice(0, 40);
}

function normName(value) {
  return String(value || '').trim().slice(0, 30);
}

function normUser(value) {
  return String(value || '').trim().toLowerCase().slice(0, 20);
}

function validUser(username) {
  return /^[a-z0-9._-]{3,20}$/.test(username);
}

function normPassword(value) {
  if (value == null) return '';
  return String(value).slice(0, 80);
}

function gitSha() {
  return process.env.RENDER_GIT_COMMIT || process.env.GIT_COMMIT || process.env.SOURCE_VERSION || '';
}

let store;

const srv = http.createServer((q, r) => {
  let p = q.url.split('?')[0];
  if (p === '/version') {
    const sha = gitSha();
    r.writeHead(200, {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-cache'
    });
    return r.end(JSON.stringify({ sha, commit: sha, store: store ? store.kind : 'starting' }));
  }
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

function memberList(room) {
  const members = [];
  for (const client of wss.clients) {
    if (client.readyState === 1 && authed(client, room) && client.name && client.peerId) {
      members.push({ id: client.peerId, name: client.name });
    }
  }
  return members;
}

function sendUsers(room) {
  const members = memberList(room);
  const users = members.map((member) => member.name);
  for (const client of wss.clients) {
    if (client.readyState !== 1 || !authed(client, room)) continue;
    client.send(JSON.stringify({ t: 'users', room, users, members, self: client.peerId }));
  }
}

function sendError(ws, room, error) {
  if (ws.readyState !== 1) return;
  ws.send(JSON.stringify({ t: 'error', room: room || '', error: error || 'Noe gikk galt' }));
}

function send(ws, payload) {
  if (ws.readyState !== 1) return;
  ws.send(JSON.stringify(payload));
}

function firstRoom(set) {
  if (!set || set.size === 0) return '';
  return set.values().next().value || '';
}

function ensureSets(ws) {
  if (!ws.auth) ws.auth = new Set();
  if (!ws.rooms) ws.rooms = new Set();
  if (!ws.muted) ws.muted = new Set();
}

async function sendInbox(ws) {
  if (!ws.user) return;
  const groups = await store.groupsFor(ws.user.id);
  const invites = await store.invitesFor(ws.user.id);
  const requests = await store.requestsForAdmin(ws.user.id);
  send(ws, { t: 'inbox', groups, invites, requests });
  return groups;
}

function applyMembership(ws, groups) {
  ensureSets(ws);
  const allowed = new Set(groups.map((group) => group.id));
  ws.auth = allowed;
  ws.rooms = new Set([...allowed].filter((id) => !ws.muted.has(id)));
  if (!allowed.has(ws.talk)) ws.talk = firstRoom(ws.rooms) || firstRoom(allowed);
  ws.room = ws.talk || '';
  return allowed;
}

async function syncAll(extraRooms) {
  const affected = new Set(extraRooms || []);
  for (const client of wss.clients) {
    if (client.readyState !== 1 || !client.user) continue;
    const previous = new Set([...(client.auth || []), ...(client.rooms || [])]);
    const groups = await sendInbox(client);
    applyMembership(client, groups || []);
    for (const room of previous) affected.add(room);
    for (const room of client.auth) affected.add(room);
  }
  for (const room of affected) sendUsers(room);
}

async function establish(ws, user, token) {
  ensureSets(ws);
  ws.user = user;
  ws.token = token;
  ws.username = user.username;
  ws.name = user.displayName;
  send(ws, { t: 'session', token, username: user.username, name: user.displayName });
  const groups = await sendInbox(ws);
  const previous = new Set([...(ws.auth || [])]);
  applyMembership(ws, groups || []);
  const affected = new Set([...previous, ...ws.auth]);
  for (const room of affected) sendUsers(room);
}

function requireUser(ws) {
  if (ws.user) return true;
  sendError(ws, '', 'Logg inn');
  return false;
}

async function signup(ws, message) {
  const username = normUser(message.username);
  const displayName = normName(message.name);
  const password = normPassword(message.password);
  if (!validUser(username)) {
    sendError(ws, '', 'Brukernavnet må være 3–20 tegn (a–z, 0–9).');
    return;
  }
  if (!displayName) {
    sendError(ws, '', 'Skriv et navn.');
    return;
  }
  if (password.length < 4) {
    sendError(ws, '', 'Passordet må ha minst 4 tegn.');
    return;
  }
  const user = await store.createUser(username, displayName, password);
  const token = await store.createSession(user.id);
  await establish(ws, user, token);
}

async function login(ws, message) {
  const username = normUser(message.username);
  const password = normPassword(message.password);
  const user = await store.verifyLogin(username, password);
  if (!user) {
    sendError(ws, '', 'Feil brukernavn eller passord');
    return;
  }
  const token = await store.createSession(user.id);
  await establish(ws, user, token);
}

async function resume(ws, message) {
  const user = await store.userForToken(message.token);
  if (!user) {
    sendError(ws, '', 'Logg inn');
    return;
  }
  await establish(ws, user, String(message.token || ''));
}

async function logout(ws) {
  if (ws.token) await store.deleteSession(ws.token);
  const previous = new Set([...(ws.auth || []), ...(ws.rooms || [])]);
  ws.user = null;
  ws.token = '';
  ws.username = '';
  ws.name = '';
  ws.auth = new Set();
  ws.rooms = new Set();
  ws.talk = '';
  ws.room = '';
  for (const room of previous) sendUsers(room);
}

async function createGroup(ws, message) {
  if (!requireUser(ws)) return;
  const label = normName(message.name);
  const room = normRoom(label);
  if (!room) {
    sendError(ws, '', 'Skriv et gruppenavn.');
    return;
  }
  const password = normPassword(message.password);
  if (password && password.length < 4) {
    sendError(ws, '', 'Passordet må ha minst 4 tegn.');
    return;
  }
  await store.createGroup(label, room, ws.user.id, password);
  await syncAll([room]);
}

async function invite(ws, message) {
  if (!requireUser(ws)) return;
  const room = normRoom(message.room);
  const username = normUser(message.username);
  if (!room || !validUser(username)) {
    sendError(ws, room, 'Skriv et brukernavn.');
    return;
  }
  await store.invite(ws.user.id, room, username);
  await syncAll([room]);
}

async function inviteReply(ws, message) {
  if (!requireUser(ws)) return;
  const room = normRoom(message.room);
  await store.replyInvite(ws.user.id, room, !!message.accept);
  await syncAll([room]);
}

async function requestJoin(ws, message) {
  if (!requireUser(ws)) return;
  const room = normRoom(message.name || message.room);
  if (!room) {
    sendError(ws, '', 'Skriv et gruppenavn.');
    return;
  }
  await store.requestJoin(ws.user.id, room);
  await syncAll([room]);
}

async function joinWithPassword(ws, message) {
  if (!requireUser(ws)) return;
  const room = normRoom(message.name || message.room);
  const password = normPassword(message.password);
  if (!room) {
    sendError(ws, '', 'Skriv et gruppenavn.');
    return;
  }
  if (!password) {
    sendError(ws, room, 'Skriv passordet.');
    return;
  }
  await store.joinWithPassword(ws.user.id, room, password);
  await syncAll([room]);
}

async function setPassword(ws, message) {
  if (!requireUser(ws)) return;
  const room = normRoom(message.room);
  if (!room) {
    sendError(ws, '', 'Skriv et gruppenavn.');
    return;
  }
  await store.setGroupPassword(ws.user.id, room, normPassword(message.password));
  await syncAll([room]);
}

async function requestReply(ws, message) {
  if (!requireUser(ws)) return;
  const room = normRoom(message.room);
  const username = normUser(message.username);
  await store.replyRequest(ws.user.id, room, username, !!message.accept);
  await syncAll([room]);
}

async function removeMember(ws, message) {
  if (!requireUser(ws)) return;
  const room = normRoom(message.room);
  const username = normUser(message.username);
  await store.removeMember(ws.user.id, room, username);
  await syncAll([room]);
}

async function leave(ws, message) {
  if (!requireUser(ws)) return;
  const room = normRoom(message.room);
  await store.leave(ws.user.id, room);
  await syncAll([room]);
}

async function deleteGroup(ws, message) {
  if (!requireUser(ws)) return;
  const room = normRoom(message.room);
  await store.deleteGroup(ws.user.id, room);
  await syncAll([room]);
}

async function subscribe(ws, message) {
  if (!requireUser(ws)) return;
  ensureSets(ws);
  const muted = Array.isArray(message.muted) ? message.muted : [];
  if (Array.isArray(message.groups)) {
    ws.muted = new Set(message.groups.filter((entry) => entry && entry.listen === false).map((entry) => normRoom(entry.room)));
  } else {
    ws.muted = new Set(muted.map(normRoom).filter(Boolean));
  }
  const groups = await store.groupsFor(ws.user.id);
  const previous = new Set([...(ws.auth || []), ...(ws.rooms || [])]);
  applyMembership(ws, groups);
  const talk = normRoom(message.talk);
  if (talk && ws.auth.has(talk)) ws.talk = talk;
  else if (talk) sendError(ws, talk, 'Ikke medlem');
  ws.room = ws.talk || '';
  ws.rooms = new Set([...ws.auth].filter((id) => !ws.muted.has(id)));
  const affected = new Set([...previous, ...ws.auth]);
  for (const room of affected) sendUsers(room);
}

wss.on('connection', (ws) => {
  ws.isAlive = true;
  ws.peerId = crypto.randomBytes(8).toString('hex');
  ws.auth = new Set();
  ws.rooms = new Set();
  ws.muted = new Set();
  ws.talk = '';
  ws.room = '';
  ws.user = null;
  ws.token = '';
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
    handleMessage(ws, message).catch((error) => {
      const text = error instanceof StoreError ? error.message : 'Noe gikk galt';
      if (!(error instanceof StoreError)) console.error(error);
      sendError(ws, normRoom(message.room), text);
    });
  });
  ws.on('close', () => {
    const name = ws.name;
    const rooms = new Set([...(ws.auth || []), ...(ws.rooms || [])]);
    ws.auth = new Set();
    ws.rooms = new Set();
    for (const room of rooms) {
      if (name) bc(room, JSON.stringify({ t: 'stop', name, room, id: ws.peerId }), null, false);
      sendUsers(room);
    }
  });
});

async function handleMessage(ws, message) {
  if (message.t === 'signup') return signup(ws, message);
  if (message.t === 'login') return login(ws, message);
  if (message.t === 'resume') return resume(ws, message);
  if (message.t === 'logout') return logout(ws);
  if (message.t === 'createGroup') return createGroup(ws, message);
  if (message.t === 'invite') return invite(ws, message);
  if (message.t === 'inviteReply') return inviteReply(ws, message);
  if (message.t === 'requestJoin') return requestJoin(ws, message);
  if (message.t === 'joinWithPassword') return joinWithPassword(ws, message);
  if (message.t === 'setPassword') return setPassword(ws, message);
  if (message.t === 'requestReply') return requestReply(ws, message);
  if (message.t === 'removeMember') return removeMember(ws, message);
  if (message.t === 'leave') return leave(ws, message);
  if (message.t === 'deleteGroup') return deleteGroup(ws, message);
  if (message.t === 'subscribe' || message.t === 'groups' || message.t === 'listen') return subscribe(ws, message);
  if (message.t === 'join' || message.t === 'talk') {
    if (!requireUser(ws)) return;
    const room = normRoom(message.room);
    if (room && ws.auth && ws.auth.has(room)) {
      ws.talk = room;
      ws.room = room;
    } else if (room) {
      sendError(ws, room, 'Ikke medlem');
    }
    return;
  }
  if (message.t === 'start' || message.t === 'stop') {
    const room = normRoom(message.room) || ws.talk;
    if (!room || !ws.name) return;
    if (!authed(ws, room)) {
      if (message.t === 'start') sendError(ws, room, 'Ikke medlem');
      return;
    }
    if (ws.talk && ws.talk !== room) return;
    bc(room, JSON.stringify({ t: message.t, name: ws.name, room, id: ws.peerId }), ws, false);
  }
}

setInterval(() => {
  for (const client of wss.clients) {
    if (!client.isAlive) client.terminate();
    client.isAlive = false;
    client.ping();
  }
}, 20000);

const port = process.env.PORT || 8080;
openStore().then((opened) => {
  store = opened;
  srv.listen(port, () => console.log('listening ' + port + ' store=' + store.kind));
}).catch((error) => {
  console.error(error);
  process.exit(1);
});
