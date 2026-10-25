#!/usr/bin/env node
// Two clients join one password-protected group and must hear each other's
// binary frames. Same display name on purpose: presence is per connection.
//
//   node scripts/relay-check.js wss://walkie-bc0z.onrender.com
//   node scripts/relay-check.js --local

const { spawn } = require('child_process');
const fs = require('fs');
const http = require('http');
const path = require('path');
const WebSocket = require('ws');

const local = process.argv.includes('--local');
const argURL = process.argv.find((arg) => arg.startsWith('ws'));
const liveURL = argURL || 'wss://walkie-bc0z.onrender.com';

function httpGet(url) {
  return new Promise((resolve) => {
    const lib = url.startsWith('https') ? require('https') : http;
    const req = lib.get(url, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });
    req.on('error', (error) => resolve({ status: 0, body: error.message }));
    req.setTimeout(20000, () => {
      req.destroy();
      resolve({ status: 0, body: 'timeout' });
    });
  });
}

function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const inbox = [];
    const timer = setTimeout(() => reject(new Error('connect timeout ' + url)), 20000);
    ws.on('open', () => {
      clearTimeout(timer);
      resolve({ ws, inbox });
    });
    ws.on('message', (data, isBinary) => {
      if (isBinary) inbox.push({ bin: true, data: Buffer.from(data) });
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
    }, 25);
  });
}

function joinLikeApp(client, name, room, password, create) {
  client.ws.send(JSON.stringify({
    t: 'groups',
    name,
    talk: room,
    groups: [{ room, password, create, listen: true }]
  }));
  client.ws.send(JSON.stringify({ t: 'join', name, room, password }));
}

function usersMessage(entry) {
  return JSON.parse(entry.text);
}

(async () => {
  let child = null;
  let url = liveURL;
  const secrets = path.join(__dirname, '..', 'room-secrets.json');
  if (local) {
    try { fs.unlinkSync(secrets); } catch {}
    const port = 18081;
    url = 'ws://127.0.0.1:' + port;
    child = spawn(process.execPath, ['server.js'], {
      cwd: path.join(__dirname, '..'),
      env: { ...process.env, PORT: String(port), RENDER_GIT_COMMIT: 'local-test' },
      stdio: ['ignore', 'pipe', 'pipe']
    });
    let log = '';
    child.stdout.on('data', (chunk) => { log += chunk; });
    child.stderr.on('data', (chunk) => { log += chunk; });
    const started = Date.now();
    while (!log.includes('listening')) {
      if (Date.now() - started > 4000) throw new Error('server did not listen: ' + log);
      await new Promise((resolve) => setTimeout(resolve, 30));
    }
  }

  const httpURL = url.replace(/^ws/, 'http').replace(/^wss:/, 'https:').replace(/\/$/, '');
  const version = await httpGet(httpURL + '/version');
  console.log('GET /version', version.status, version.body.slice(0, 300));

  const room = 'relay' + Date.now().toString(36);
  const password = 'hemmelig';
  const frame = Buffer.from([8, 0, 16, 0, 24, 0, 32, 0]);

  const ada = await connect(url);
  joinLikeApp(ada, 'Sku', room, password, true);
  const adaUsers = usersMessage(await waitFor(ada.inbox, (entry) => !entry.bin && entry.text.includes('"users"')));
  const adaNames = adaUsers.users || [];
  if (!adaNames.includes('Sku')) throw new Error('creator missing from list ' + JSON.stringify(adaUsers));

  const bob = await connect(url);
  joinLikeApp(bob, 'Sku', room, password, false);
  const bobUsers = usersMessage(await waitFor(bob.inbox, (entry) => !entry.bin && entry.text.includes('"users"')));
  const bobNames = bobUsers.users || [];
  if (bobNames.filter((name) => name === 'Sku').length < 2) {
    throw new Error('duplicate names collapsed or second client not joined: ' + JSON.stringify(bobUsers));
  }
  if (Array.isArray(bobUsers.members)) {
    const ids = bobUsers.members.map((member) => member.id);
    if (new Set(ids).size < 2) throw new Error('member ids are not unique ' + JSON.stringify(ids));
    if (!bobUsers.self || !ids.includes(bobUsers.self)) throw new Error('self id missing ' + JSON.stringify(bobUsers));
  } else {
    console.log('server has no per-connection members (old protocol)');
  }

  const bobMark = bob.inbox.length;
  ada.ws.send(frame);
  const heard = await waitFor(bob.inbox, (entry) => entry.bin, 4000, bobMark);
  if (!heard.data.equals(frame)) throw new Error('bob audio mismatch');

  const adaMark = ada.inbox.length;
  const reply = Buffer.from([4, 1, 5, 1]);
  bob.ws.send(reply);
  const heardBack = await waitFor(ada.inbox, (entry) => entry.bin, 4000, adaMark);
  if (!heardBack.data.equals(reply)) throw new Error('ada audio mismatch');

  const outsider = await connect(url);
  outsider.ws.send(JSON.stringify({
    t: 'groups',
    name: 'Nei',
    talk: room,
    groups: [{ room, password: 'feil', create: false, listen: true }]
  }));
  const error = await waitFor(
    outsider.inbox,
    (entry) => !entry.bin && entry.text.includes('Feil passord'),
    2500
  ).catch(() => null);
  ada.ws.send(frame);
  await new Promise((resolve) => setTimeout(resolve, 300));
  const leaked = outsider.inbox.some((entry) => entry.bin);
  if (leaked) throw new Error('unauthenticated socket received audio');
  if (!error) console.log('password was not rejected (old server ignores it)');
  else console.log('wrong password rejected and received no audio');

  console.log('relay ok', room, 'names', bobNames.join(','));
  ada.ws.close();
  bob.ws.close();
  outsider.ws.close();
  if (child) {
    child.kill();
    try { fs.unlinkSync(secrets); } catch {}
  }
  process.exit(0);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
