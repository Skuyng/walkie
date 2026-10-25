const fs = require('fs');
const path = require('path');
const { StoreError } = require('./store');

const PAGE = path.join(__dirname, 'public', 'admin.html');
const COOKIE = 'tn_admin';
const WINDOW_MS = 15 * 60 * 1000;
const MAX_FAILURES = 8;
const failures = new Map();

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

function normRoom(value) {
  return String(value || '').trim().toLowerCase().slice(0, 40);
}

function adminNames() {
  const raw = process.env.ADMIN_USERNAMES;
  const source = raw == null || String(raw).trim() === '' ? 'skuyng' : String(raw);
  return new Set(source.split(',').map((item) => normUser(item)).filter((item) => validUser(item) || item === 'skuyng'));
}

function isAdminUsername(username) {
  return adminNames().has(username);
}

function clientIp(req) {
  const forwarded = req.headers['x-forwarded-for'];
  if (typeof forwarded === 'string' && forwarded.trim()) return forwarded.split(',')[0].trim().slice(0, 80);
  return (req.socket && req.socket.remoteAddress) || 'unknown';
}

function limited(ip) {
  const now = Date.now();
  const slot = failures.get(ip);
  if (!slot || slot.resetAt <= now) return false;
  return slot.count >= MAX_FAILURES;
}

function noteFailure(ip) {
  const now = Date.now();
  const slot = failures.get(ip);
  if (!slot || slot.resetAt <= now) failures.set(ip, { count: 1, resetAt: now + WINDOW_MS });
  else slot.count += 1;
  if (failures.size > 4000) {
    for (const [key, value] of failures) {
      if (value.resetAt <= now) failures.delete(key);
    }
  }
}

function noteSuccess(ip) {
  failures.delete(ip);
}

function readCookie(req, name) {
  const raw = req.headers.cookie || '';
  for (const part of raw.split(';')) {
    const text = part.trim();
    const eq = text.indexOf('=');
    if (eq <= 0) continue;
    if (text.slice(0, eq) === name) return decodeURIComponent(text.slice(eq + 1));
  }
  return '';
}

function cookieValue(token, req, clear) {
  const secure = req.headers['x-forwarded-proto'] === 'https' || (req.socket && req.socket.encrypted);
  const parts = [
    COOKIE + '=' + (clear ? '' : token),
    'HttpOnly',
    'SameSite=Lax',
    'Path=/admin',
    'Max-Age=' + (clear ? '0' : String(30 * 24 * 60 * 60))
  ];
  if (secure) parts.push('Secure');
  return parts.join('; ');
}

function sameOrigin(req) {
  const origin = req.headers.origin;
  if (!origin) return true;
  let host = '';
  try {
    host = new URL(origin).host;
  } catch {
    return false;
  }
  const expected = String(req.headers['x-forwarded-host'] || req.headers.host || '');
  return host === expected;
}

function sendJson(res, status, payload, extra) {
  const headers = Object.assign({
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer'
  }, extra || {});
  res.writeHead(status, headers);
  res.end(JSON.stringify(payload));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 8000) {
        reject(Object.assign(new Error('too large'), { status: 413 }));
        req.destroy();
      } else {
        chunks.push(chunk);
      }
    });
    req.on('end', () => {
      if (!chunks.length) return resolve({});
      try {
        const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        resolve(parsed && typeof parsed === 'object' ? parsed : {});
      } catch {
        reject(Object.assign(new Error('bad json'), { status: 400 }));
      }
    });
    req.on('error', reject);
  });
}

function createAdminHandler(ctx) {
  async function actor(req) {
    const store = ctx.getStore();
    if (!store) return null;
    const token = readCookie(req, COOKIE);
    if (!token) return null;
    let user;
    try {
      user = await store.userForToken(token);
    } catch (error) {
      if (error instanceof StoreError) return null;
      throw error;
    }
    if (!user || !isAdminUsername(user.username)) return null;
    return { user, token };
  }

  async function requireAdmin(req, res) {
    const session = await actor(req);
    if (!session) {
      sendJson(res, 401, { error: 'Logg inn' });
      return null;
    }
    return session;
  }

  function guardMutation(req, res) {
    if (sameOrigin(req)) return true;
    sendJson(res, 403, { error: 'Noe gikk galt' });
    return false;
  }

  async function login(req, res) {
    if (!guardMutation(req, res)) return;
    const ip = clientIp(req);
    if (limited(ip)) {
      sendJson(res, 429, { error: 'For mange forsøk. Prøv igjen senere.' }, { 'Retry-After': '900' });
      return;
    }
    const body = await readBody(req);
    const username = normUser(body.username);
    const password = normPassword(body.password);
    const store = ctx.getStore();
    if (!store) {
      sendJson(res, 503, { error: 'Noe gikk galt' });
      return;
    }
    let user = null;
    try {
      user = validUser(username) ? await store.verifyLogin(username, password) : null;
    } catch (error) {
      if (error instanceof StoreError && error.message === 'Kontoen er stengt.') {
        noteFailure(ip);
        sendJson(res, 403, { error: error.message });
        return;
      }
      throw error;
    }
    if (!user || !isAdminUsername(user.username)) {
      noteFailure(ip);
      sendJson(res, 401, { error: 'Feil brukernavn eller passord' });
      return;
    }
    const token = await store.createSession(user.id);
    noteSuccess(ip);
    sendJson(res, 200, { username: user.username, displayName: user.displayName }, {
      'Set-Cookie': cookieValue(token, req, false)
    });
  }

  async function logout(req, res) {
    if (!guardMutation(req, res)) return;
    const store = ctx.getStore();
    const token = readCookie(req, COOKIE);
    if (store && token) {
      try { await store.deleteSession(token); } catch (error) { ctx.noteError(error); }
    }
    sendJson(res, 200, { ok: true }, { 'Set-Cookie': cookieValue('', req, true) });
  }

  return async function handleAdmin(req, res) {
    const url = new URL(req.url, 'http://localhost');
    const pathname = url.pathname;
    try {
      if (req.method === 'GET' && (pathname === '/admin' || pathname === '/admin/')) {
        fs.readFile(PAGE, (error, data) => {
          if (error) {
            res.writeHead(404);
            res.end();
            return;
          }
          res.writeHead(200, {
            'Content-Type': 'text/html; charset=utf-8',
            'Cache-Control': 'no-store',
            'X-Content-Type-Options': 'nosniff',
            'X-Frame-Options': 'DENY',
            'Referrer-Policy': 'no-referrer'
          });
          res.end(data);
        });
        return;
      }

      if (req.method === 'POST' && pathname === '/admin/api/login') return login(req, res);
      if (req.method === 'POST' && pathname === '/admin/api/logout') return logout(req, res);

      const session = await requireAdmin(req, res);
      if (!session) return;
      const store = ctx.getStore();
      const me = session.user.username;

      if (req.method === 'GET' && pathname === '/admin/api/me') {
        return sendJson(res, 200, { username: session.user.username, displayName: session.user.displayName });
      }
      if (req.method === 'GET' && pathname === '/admin/api/overview') {
        const counts = await store.counts();
        const days = await store.talkHistory();
        const today = days[days.length - 1] || { transmissions: 0, talkMinutes: 0, talkMs: 0 };
        return sendJson(res, 200, {
          users: counts.users,
          groups: counts.groups,
          online: ctx.onlineCount(),
          today,
          days
        });
      }
      if (req.method === 'GET' && pathname === '/admin/api/status') {
        return sendJson(res, 200, ctx.status());
      }
      if (req.method === 'GET' && pathname === '/admin/api/reports') {
        return sendJson(res, 200, { reports: await store.listReports() });
      }
      if (req.method === 'GET' && pathname === '/admin/api/users') {
        return sendJson(res, 200, { users: await store.listUsers(url.searchParams.get('q') || '') });
      }
      if (req.method === 'GET' && pathname === '/admin/api/groups') {
        return sendJson(res, 200, { groups: await store.listGroups() });
      }

      const reportMatch = pathname.match(/^\/admin\/api\/reports\/([0-9a-f]{24})(?:\/(resolve|warn|ban))?$/);
      if (reportMatch) {
        const id = reportMatch[1];
        const action = reportMatch[2] || '';
        if (req.method === 'GET' && !action) {
          return sendJson(res, 200, await store.getReport(id));
        }
        if (req.method !== 'POST' || !action) return sendJson(res, 404, { error: 'Fant ikke siden' });
        if (!guardMutation(req, res)) return;
        const body = await readBody(req);
        const note = String(body.note || body.reason || '').slice(0, 300);
        if (action === 'resolve') {
          const report = await store.closeReport(id, 'resolved', me, note);
          return sendJson(res, 200, report);
        }
        if (action === 'warn') {
          const report = await store.closeReport(id, 'warned', me, note);
          await ctx.onWarned(report.targetId, report.note);
          return sendJson(res, 200, report);
        }
        const current = await store.getReport(id);
        if (current.status !== 'open') {
          return sendJson(res, 400, { error: 'Rapporten er allerede behandlet.' });
        }
        if (current.targetUsername === me) {
          return sendJson(res, 400, { error: 'Du kan ikke stenge din egen konto.' });
        }
        const banned = await store.banUser(current.targetUsername, note || current.reason, me);
        await ctx.onBanned(banned.id);
        return sendJson(res, 200, { ok: true, username: banned.username });
      }

      const userMatch = pathname.match(/^\/admin\/api\/users\/([a-z0-9._-]{1,20})(?:\/(ban|unban))?$/);
      if (userMatch) {
        const username = normUser(decodeURIComponent(userMatch[1]));
        const action = userMatch[2] || '';
        if (!validUser(username)) return sendJson(res, 400, { error: 'Skriv et brukernavn.' });
        if (!guardMutation(req, res)) return;
        if (req.method === 'POST' && action === 'ban') {
          if (username === me) return sendJson(res, 400, { error: 'Du kan ikke stenge din egen konto.' });
          const body = await readBody(req);
          const banned = await store.banUser(username, body.reason || '', me);
          await ctx.onBanned(banned.id);
          return sendJson(res, 200, { ok: true, username: banned.username });
        }
        if (req.method === 'POST' && action === 'unban') {
          const restored = await store.unbanUser(username);
          return sendJson(res, 200, { ok: true, username: restored.username });
        }
        if (req.method === 'DELETE' && !action) {
          if (username === me) return sendJson(res, 400, { error: 'Du kan ikke slette din egen konto her.' });
          const removed = await store.deleteUser(username);
          await ctx.onDeleted(removed.id, removed.rooms);
          return sendJson(res, 200, { ok: true, username: removed.username });
        }
        return sendJson(res, 404, { error: 'Fant ikke siden' });
      }

      const groupMatch = pathname.match(/^\/admin\/api\/groups\/([^/]+)$/);
      if (groupMatch && req.method === 'DELETE') {
        if (!guardMutation(req, res)) return;
        let room = '';
        try { room = normRoom(decodeURIComponent(groupMatch[1])); } catch { room = ''; }
        if (!room) return sendJson(res, 400, { error: 'Fant ikke gruppen' });
        await store.adminDeleteGroup(room);
        await ctx.onGroupDeleted(room);
        return sendJson(res, 200, { ok: true, id: room });
      }

      sendJson(res, 404, { error: 'Fant ikke siden' });
    } catch (error) {
      if (error instanceof StoreError) return sendJson(res, 400, { error: error.message });
      if (error && error.status === 400) return sendJson(res, 400, { error: 'Noe gikk galt' });
      if (error && error.status === 413) return sendJson(res, 413, { error: 'Noe gikk galt' });
      ctx.noteError(error);
      if (!res.headersSent) sendJson(res, 500, { error: 'Noe gikk galt' });
    }
  };
}

module.exports = { createAdminHandler, isAdminUsername };
