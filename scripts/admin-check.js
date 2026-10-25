#!/usr/bin/env node
// Admin panel: default admin is skuyng, bans block login, talk days count.
//   node scripts/admin-check.js

const { spawn } = require('child_process');
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const WebSocket = require('ws');

let activeChild = null;

function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const inbox = [];
    const timer = setTimeout(() => reject(new Error('connect timeout')), 8000);
    ws.on('open', () => {
      clearTimeout(timer);
      resolve({ ws, inbox });
    });
    ws.on('message', (data, isBinary) => {
      if (isBinary) inbox.push({ bin: true });
      else inbox.push({ bin: false, text: data.toString() });
    });
    ws.on('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

function waitFor(inbox, pred, ms = 4000, from = 0) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const timer = setInterval(() => {
      const hit = inbox.slice(from).find(pred);
      if (hit) {
        clearInterval(timer);
        resolve(hit);
      } else if (Date.now() - start > ms) {
        clearInterval(timer);
        reject(new Error('timeout: ' + JSON.stringify(inbox.slice(from))));
      }
    }, 20);
  });
}

function send(client, payload) {
  client.ws.send(JSON.stringify(payload));
}

function signup(client, username, name, password) {
  send(client, { t: 'signup', username, name, password, terms: true });
}

function jsonText(entry) {
  return JSON.parse(entry.text);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function request(base, method, pathname, { body, cookie, headers } = {}) {
  const url = new URL(pathname, base);
  const payload = body == null ? null : JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const req = http.request({
      method,
      hostname: url.hostname,
      port: url.port,
      path: url.pathname + url.search,
      headers: Object.assign(
        {},
        payload ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } : {},
        cookie ? { Cookie: cookie } : {},
        headers || {}
      )
    }, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        let json = {};
        if ((res.headers['content-type'] || '').includes('json') && data) json = JSON.parse(data);
        resolve({ status: res.statusCode, headers: res.headers, body: data, json });
      });
    });
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

function cookieFrom(res) {
  const raw = res.headers['set-cookie'];
  const line = Array.isArray(raw) ? raw[0] : raw;
  if (!line || !line.includes('tn_admin=')) return '';
  return line.split(';')[0];
}

function startServer(storeFile, extraEnv) {
  const port = 18000 + Math.floor(Math.random() * 2000);
  const env = Object.assign({}, process.env, {
    PORT: String(port),
    STORE_PATH: storeFile,
    DATABASE_URL: '',
    RENDER_GIT_COMMIT: 'admin-test'
  }, extraEnv || {});
  if (!extraEnv || !Object.prototype.hasOwnProperty.call(extraEnv, 'ADMIN_USERNAMES')) delete env.ADMIN_USERNAMES;
  const child = spawn(process.execPath, ['server.js'], {
    cwd: path.join(__dirname, '..'),
    env,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  activeChild = child;
  let log = '';
  child.stdout.on('data', (chunk) => { log += chunk; });
  child.stderr.on('data', (chunk) => { log += chunk; });
  const started = Date.now();
  return (async () => {
    while (!log.includes('listening')) {
      if (Date.now() - started > 4000) throw new Error('server did not listen: ' + log);
      await sleep(30);
    }
    return { child, http: 'http://127.0.0.1:' + port, ws: 'ws://127.0.0.1:' + port, log: () => log };
  })();
}

(async () => {
  const storeFile = path.join(os.tmpdir(), 'walkie-admin-' + process.pid + '.json');
  try { fs.unlinkSync(storeFile); } catch {}
  let server = await startServer(storeFile);
  const page = await request(server.http, 'GET', '/admin');
  if (page.status !== 200 || !page.body.includes('TalkNet') || !page.body.includes('#3ee6d0')) {
    throw new Error('admin page ' + page.status);
  }
  if (page.headers['x-frame-options'] !== 'DENY') throw new Error('admin page can be framed');

  const yngve = await connect(server.ws);
  const bob = await connect(server.ws);
  signup(yngve, 'skuyng', 'Yngve', 'secret1');
  signup(bob, 'bob', 'Bob', 'secret2');
  const yngveSession = jsonText(await waitFor(yngve.inbox, (entry) => !entry.bin && entry.text.includes('"session"')));
  if (yngveSession.username !== 'skuyng') throw new Error('yngve session');
  const bobSession = jsonText(await waitFor(bob.inbox, (entry) => !entry.bin && entry.text.includes('"session"')));

  const stranger = await request(server.http, 'POST', '/admin/api/login', {
    body: { username: 'bob', password: 'secret2' }
  });
  if (stranger.status !== 401 || cookieFrom(stranger)) throw new Error('non-admin login ' + stranger.status);

  const badCookie = await request(server.http, 'GET', '/admin/api/me', { cookie: 'tn_admin=' + bobSession.token });
  if (badCookie.status !== 401) throw new Error('non-admin session was accepted ' + badCookie.status);

  const signed = await request(server.http, 'POST', '/admin/api/login', {
    body: { username: 'skuyng', password: 'secret1' },
    headers: { 'x-forwarded-proto': 'https' }
  });
  if (signed.status !== 200 || signed.json.username !== 'skuyng') throw new Error('admin login ' + signed.status + ' ' + signed.body);
  const setCookie = (Array.isArray(signed.headers['set-cookie']) ? signed.headers['set-cookie'][0] : signed.headers['set-cookie']) || '';
  if (!/HttpOnly/i.test(setCookie) || !/Secure/i.test(setCookie) || !/Path=\/admin/i.test(setCookie)) {
    throw new Error('cookie flags ' + setCookie);
  }
  const cookie = cookieFrom(signed);
  const me = await request(server.http, 'GET', '/admin/api/me', { cookie });
  if (me.json.displayName !== 'Yngve') throw new Error('me ' + me.body);

  send(yngve, { t: 'createGroup', name: 'Familie' });
  await waitFor(yngve.inbox, (entry) => !entry.bin && entry.text.includes('"familie"'));
  send(yngve, { t: 'subscribe', talk: 'familie', muted: [] });
  send(yngve, { t: 'start', room: 'familie' });
  send(yngve, { t: 'start', room: 'familie' });
  await sleep(80);
  send(yngve, { t: 'stop', room: 'familie' });
  await sleep(40);

  const overview = await request(server.http, 'GET', '/admin/api/overview', { cookie });
  const today = (overview.json.days || [])[(overview.json.days || []).length - 1];
  if (!today || today.transmissions !== 1 || !(today.talkMs > 0)) {
    throw new Error('talk day ' + JSON.stringify(today));
  }
  if (overview.json.users < 2 || overview.json.groups < 1 || overview.json.online < 1) {
    throw new Error('overview ' + overview.body);
  }
  if ((overview.json.days || []).length !== 30) throw new Error('expected 30 days');

  const cara = await connect(server.ws);
  signup(cara, 'cara', 'Cara', 'secret3');
  await waitFor(cara.inbox, (entry) => !entry.bin && entry.text.includes('"session"'));
  let reportFrom = cara.inbox.length;
  for (const reason of ['Uakseptabel oppførsel', 'Andre rapport', 'Tredje rapport']) {
    send(cara, { t: 'report', username: 'bob', room: 'familie', reason });
    await waitFor(cara.inbox, (entry) => !entry.bin && entry.text.includes('"reported"'), 4000, reportFrom);
    reportFrom = cara.inbox.length;
  }

  const openReports = await request(server.http, 'GET', '/admin/api/reports', { cookie });
  const reports = openReports.json.reports || [];
  if (reports.length < 3) throw new Error('reports ' + openReports.body);
  const first = reports.find((item) => item.reason === 'Uakseptabel oppførsel');
  const viewed = await request(server.http, 'GET', '/admin/api/reports/' + first.id, { cookie });
  if (viewed.json.reason !== 'Uakseptabel oppførsel' || viewed.json.targetUsername !== 'bob') {
    throw new Error('view report ' + viewed.body);
  }
  const resolved = await request(server.http, 'POST', '/admin/api/reports/' + first.id + '/resolve', {
    cookie,
    body: { note: 'Ingen tiltak' }
  });
  if (resolved.status !== 200) throw new Error('resolve ' + resolved.body);

  const warnAt = bob.inbox.length;
  const warning = reports.find((item) => item.reason === 'Andre rapport');
  const warned = await request(server.http, 'POST', '/admin/api/reports/' + warning.id + '/warn', { cookie, body: {} });
  if (warned.status !== 200) throw new Error('warn ' + warned.body);
  const bobWarn = jsonText(await waitFor(bob.inbox, (entry) => !entry.bin && entry.text.includes('Advarsel'), 4000, warnAt));
  if (!String(bobWarn.error || '').includes('Advarsel')) throw new Error('warning was not delivered');

  const banReport = (await request(server.http, 'GET', '/admin/api/reports', { cookie })).json.reports.find((item) => item.reason === 'Tredje rapport');
  const closed = new Promise((resolve) => bob.ws.once('close', resolve));
  const banned = await request(server.http, 'POST', '/admin/api/reports/' + banReport.id + '/ban', {
    cookie,
    body: { note: 'Stengt fra rapport' }
  });
  if (banned.status !== 200) throw new Error('ban ' + banned.body);
  await closed;

  const bobLogin = await connect(server.ws);
  send(bobLogin, { t: 'login', username: 'bob', password: 'secret2' });
  const denied = jsonText(await waitFor(bobLogin.inbox, (entry) => !entry.bin && entry.text.includes('stengt')));
  if (!String(denied.error || '').includes('Kontoen er stengt')) throw new Error('banned login ' + denied.error);
  bobLogin.ws.close();

  const resume = await connect(server.ws);
  send(resume, { t: 'resume', token: 'nope' });
  await waitFor(resume.inbox, (entry) => !entry.bin && entry.text.includes('Logg inn'));
  resume.ws.close();

  const unbanned = await request(server.http, 'POST', '/admin/api/users/bob/unban', { cookie, body: {} });
  if (unbanned.status !== 200) throw new Error('unban ' + unbanned.body);
  const bobBack = await connect(server.ws);
  send(bobBack, { t: 'login', username: 'bob', password: 'secret2' });
  const back = jsonText(await waitFor(bobBack.inbox, (entry) => !entry.bin && entry.text.includes('"session"')));
  if (back.username !== 'bob') throw new Error('unban did not restore login');

  const selfBan = await request(server.http, 'POST', '/admin/api/users/skuyng/ban', { cookie, body: { reason: 'meg' } });
  if (selfBan.status !== 400) throw new Error('self ban ' + selfBan.status);
  const bannedAgain = await request(server.http, 'POST', '/admin/api/users/bob/ban', { cookie, body: { reason: 'Igjen' } });
  if (bannedAgain.status !== 200) throw new Error('user ban ' + bannedAgain.body);
  bobBack.ws.close();

  send(yngve, { t: 'createGroup', name: 'Midlertidig' });
  await waitFor(yngve.inbox, (entry) => !entry.bin && entry.text.includes('midlertidig'));
  const removedGroup = await request(server.http, 'DELETE', '/admin/api/groups/midlertidig', { cookie });
  if (removedGroup.status !== 200) throw new Error('delete group ' + removedGroup.body);
  const groups = await request(server.http, 'GET', '/admin/api/groups', { cookie });
  if ((groups.json.groups || []).some((group) => group.id === 'midlertidig')) throw new Error('group remained');
  if (!(groups.json.groups || []).some((group) => group.id === 'familie')) throw new Error('familie was removed');

  const removedUser = await request(server.http, 'DELETE', '/admin/api/users/bob', { cookie });
  if (removedUser.status !== 200) throw new Error('delete user ' + removedUser.body);
  const users = await request(server.http, 'GET', '/admin/api/users?q=bob', { cookie });
  if ((users.json.users || []).some((user) => user.username === 'bob')) throw new Error('bob remained');
  const selfDelete = await request(server.http, 'DELETE', '/admin/api/users/skuyng', { cookie });
  if (selfDelete.status !== 400) throw new Error('self delete ' + selfDelete.status);

  const status = await request(server.http, 'GET', '/admin/api/status', { cookie });
  if (status.json.store !== 'json' || status.json.version !== '1.0.0' || status.json.sha !== 'admin-test' || !(status.json.uptime >= 0)) {
    throw new Error('status ' + status.body);
  }
  if (!Array.isArray(status.json.errors)) throw new Error('errors missing');

  const loggedOut = await request(server.http, 'POST', '/admin/api/logout', { cookie, body: {} });
  if (loggedOut.status !== 200 || !/Max-Age=0/i.test(String(loggedOut.headers['set-cookie']))) throw new Error('logout cookie');
  const after = await request(server.http, 'GET', '/admin/api/overview', { cookie });
  if (after.status !== 401) throw new Error('cookie still valid');

  let blocked = false;
  for (let i = 0; i < 12; i++) {
    const attempt = await request(server.http, 'POST', '/admin/api/login', {
      body: { username: 'skuyng', password: 'wrong-password' }
    });
    if (attempt.status === 429) {
      blocked = true;
      if (!String(attempt.json.error || '').includes('mange')) throw new Error('rate text ' + attempt.body);
      break;
    }
  }
  if (!blocked) throw new Error('login was not rate limited');

  yngve.ws.close();
  cara.ws.close();
  server.child.kill();
  activeChild = null;
  await sleep(100);

  const otherFile = path.join(os.tmpdir(), 'walkie-admin-ada-' + process.pid + '.json');
  try { fs.unlinkSync(otherFile); } catch {}
  server = await startServer(otherFile, { ADMIN_USERNAMES: 'ada' });
  const ada = await connect(server.ws);
  const other = await connect(server.ws);
  signup(ada, 'ada', 'Ada', 'secret1');
  signup(other, 'skuyng', 'Yngve', 'secret1');
  await waitFor(ada.inbox, (entry) => !entry.bin && entry.text.includes('"session"'));
  await waitFor(other.inbox, (entry) => !entry.bin && entry.text.includes('"session"'));
  const notDefault = await request(server.http, 'POST', '/admin/api/login', {
    body: { username: 'skuyng', password: 'secret1' }
  });
  if (notDefault.status !== 401) throw new Error('default admin ignored override');
  const adaLogin = await request(server.http, 'POST', '/admin/api/login', {
    body: { username: 'ada', password: 'secret1' }
  });
  if (adaLogin.status !== 200) throw new Error('configured admin ' + adaLogin.body);
  ada.ws.close();
  other.ws.close();
  server.child.kill();
  try { fs.unlinkSync(storeFile); } catch {}
  try { fs.unlinkSync(otherFile); } catch {}
  console.log('admin ok');
  process.exit(0);
})().catch((error) => {
  console.error(error);
  if (activeChild) activeChild.kill();
  process.exit(1);
});
