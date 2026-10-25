#!/usr/bin/env node
// Signup, invite, and audio: only members receive frames. Same display name
// on purpose. Restarts the JSON store and resumes the session token.
//
//   node scripts/relay-check.js --local

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const WebSocket = require('ws');

const storeFile = path.join(os.tmpdir(), 'walkie-account-' + process.pid + '.json');

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
    }, 20);
  });
}

function send(client, payload) {
  client.ws.send(JSON.stringify(payload));
}

function jsonText(entry) {
  return JSON.parse(entry.text);
}

async function startServer() {
  const port = 18000 + Math.floor(Math.random() * 2000);
  const child = spawn(process.execPath, ['server.js'], {
    cwd: path.join(__dirname, '..'),
    env: { ...process.env, PORT: String(port), STORE_PATH: storeFile, DATABASE_URL: '', RENDER_GIT_COMMIT: 'account-test' },
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
  return { child, url: 'ws://127.0.0.1:' + port, http: 'http://127.0.0.1:' + port };
}

(async () => {
  try { fs.unlinkSync(storeFile); } catch {}
  let server = await startServer();
  const version = await new Promise((resolve) => {
    require('http').get(server.http + '/version', (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => resolve(body));
    });
  });
  const versionJson = JSON.parse(version);
  if (versionJson.store !== 'json') throw new Error('expected json store ' + version);

  const ada = await connect(server.url);
  send(ada, { t: 'signup', username: 'ada', name: 'Sku', password: 'secret1' });
  const adaSession = jsonText(await waitFor(ada.inbox, (entry) => !entry.bin && entry.text.includes('"session"')));
  if (!adaSession.token || adaSession.username !== 'ada') throw new Error('signup session ' + adaSession.token);

  const dup = await connect(server.url);
  send(dup, { t: 'signup', username: 'ada', name: 'Annen', password: 'secret1' });
  const taken = jsonText(await waitFor(dup.inbox, (entry) => !entry.bin && entry.text.includes('opptatt')));
  if (!taken.error.includes('opptatt')) throw new Error(taken.error);
  dup.ws.close();

  const bad = await connect(server.url);
  send(bad, { t: 'login', username: 'ada', password: 'feil' });
  await waitFor(bad.inbox, (entry) => !entry.bin && entry.text.includes('Feil brukernavn'));
  bad.ws.close();

  send(ada, { t: 'createGroup', name: 'Familie' });
  const adaInbox = jsonText(await waitFor(ada.inbox, (entry) => !entry.bin && entry.text.includes('"inbox"') && entry.text.includes('familie')));
  if (!adaInbox.groups.some((group) => group.id === 'familie' && group.admin)) throw new Error('admin group missing');

  const bob = await connect(server.url);
  send(bob, { t: 'signup', username: 'bob', name: 'Sku', password: 'secret2' });
  const bobSession = jsonText(await waitFor(bob.inbox, (entry) => !entry.bin && entry.text.includes('"session"')));
  send(bob, { t: 'requestJoin', name: 'Familie' });
  const adaRequest = jsonText(await waitFor(ada.inbox, (entry) => !entry.bin && entry.text.includes('"requests"') && entry.text.includes('bob')));
  if (!adaRequest.requests.some((request) => request.username === 'bob')) throw new Error('request missing');
  send(ada, { t: 'requestReply', room: 'familie', username: 'bob', accept: true });
  const bobJoined = jsonText(await waitFor(bob.inbox, (entry) => !entry.bin && entry.text.includes('"familie"') && entry.text.includes('"groups"')));
  if (!bobJoined.groups.some((group) => group.id === 'familie')) throw new Error('bob not a member');

  send(ada, { t: 'subscribe', talk: 'familie', muted: [] });
  send(bob, { t: 'subscribe', talk: 'familie', muted: [] });
  const users = jsonText(await waitFor(ada.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'users' && Array.isArray(message.members) && message.members.length >= 2;
    } catch { return false; }
  }));
  const ids = (users.members || []).map((member) => member.id);
  if (new Set(ids).size < 2) throw new Error('duplicate display names collapsed ' + JSON.stringify(users));

  const frame = Buffer.from([9, 0, 8, 0, 7, 0]);
  const bobMark = bob.inbox.length;
  ada.ws.send(frame);
  const heard = await waitFor(bob.inbox, (entry) => entry.bin, 3000, bobMark);
  if (!heard.data.equals(frame)) throw new Error('member audio mismatch');

  const cara = await connect(server.url);
  send(cara, { t: 'signup', username: 'cara', name: 'Cara', password: 'secret3' });
  await waitFor(cara.inbox, (entry) => !entry.bin && entry.text.includes('"session"'));
  const caraMark = cara.inbox.length;
  ada.ws.send(frame);
  await new Promise((resolve) => setTimeout(resolve, 250));
  if (cara.inbox.slice(caraMark).some((entry) => entry.bin)) throw new Error('non-member received audio');

  send(ada, { t: 'invite', room: 'familie', username: 'cara' });
  const invite = jsonText(await waitFor(cara.inbox, (entry) => !entry.bin && entry.text.includes('"invites"') && entry.text.includes('familie')));
  if (!invite.invites.some((item) => item.room === 'familie' && item.from === 'ada')) throw new Error('invite missing');
  send(cara, { t: 'inviteReply', room: 'familie', accept: true });
  await waitFor(cara.inbox, (entry) => !entry.bin && entry.text.includes('"groups"') && entry.text.includes('familie'));
  send(cara, { t: 'subscribe', talk: 'familie', muted: [] });
  const caraHear = cara.inbox.length;
  bob.ws.send(frame);
  const caraAudio = await waitFor(cara.inbox, (entry) => entry.bin, 3000, caraHear);
  if (!caraAudio.data.equals(frame)) throw new Error('invitee missed audio');

  const selfAt = ada.inbox.length;
  send(ada, { t: 'removeMember', room: 'familie', username: 'ada' });
  const selfKick = jsonText(await waitFor(ada.inbox, (entry) => !entry.bin && entry.text.includes('fjerne deg selv'), 4000, selfAt));
  if (!String(selfKick.error || '').includes('fjerne deg selv')) throw new Error('admin removed self');

  const removedAt = bob.inbox.length;
  send(ada, { t: 'removeMember', room: 'familie', username: 'bob' });
  const kicked = jsonText(await waitFor(bob.inbox, (entry) => !entry.bin && entry.text.includes('fjernet'), 4000, removedAt));
  if (!String(kicked.error || '').includes('fjernet')) throw new Error('kicked user was not notified');
  await waitFor(bob.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && !(message.groups || []).some((group) => group.id === 'familie');
    } catch { return false; }
  }, 4000, removedAt);
  const after = bob.inbox.length;
  ada.ws.send(frame);
  await new Promise((resolve) => setTimeout(resolve, 250));
  if (bob.inbox.slice(after).some((entry) => entry.bin)) throw new Error('removed member still received audio');
  const adaAfter = ada.inbox.length;
  bob.ws.send(frame);
  await new Promise((resolve) => setTimeout(resolve, 250));
  if (ada.inbox.slice(adaAfter).some((entry) => entry.bin)) throw new Error('kicked user still transmitted');

  const passAt = ada.inbox.length;
  send(ada, { t: 'setPassword', room: 'familie', password: 'hemmelig' });
  await waitFor(ada.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && (message.groups || []).some((group) => group.id === 'familie' && group.locked === true);
    } catch { return false; }
  }, 4000, passAt);
  const askAt = ada.inbox.length;
  send(bob, { t: 'requestJoin', name: 'Familie' });
  const asked = jsonText(await waitFor(ada.inbox, (entry) => !entry.bin && entry.text.includes('"requests"') && entry.text.includes('bob'), 4000, askAt));
  if (!asked.requests.some((request) => request.username === 'bob' && request.room === 'familie')) throw new Error('locked group rejected a request');
  send(ada, { t: 'requestReply', room: 'familie', username: 'bob', accept: false });
  const wrongAt = bob.inbox.length;
  send(bob, { t: 'joinWithPassword', name: 'Familie', password: 'feil' });
  const wrong = jsonText(await waitFor(bob.inbox, (entry) => !entry.bin && entry.text.includes('Feil passord'), 4000, wrongAt));
  if (!String(wrong.error || '').includes('Feil passord')) throw new Error('wrong password was accepted');
  const joinAt = bob.inbox.length;
  send(bob, { t: 'joinWithPassword', name: 'Familie', password: 'hemmelig' });
  await waitFor(bob.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && (message.groups || []).some((group) => group.id === 'familie' && group.locked === true);
    } catch { return false; }
  }, 4000, joinAt);
  send(bob, { t: 'subscribe', talk: 'familie', muted: [] });
  const hearAt = bob.inbox.length;
  ada.ws.send(frame);
  const rejoined = await waitFor(bob.inbox, (entry) => entry.bin, 3000, hearAt);
  if (!rejoined.data.equals(frame)) throw new Error('password member missed audio');
  const clearAt = ada.inbox.length;
  send(ada, { t: 'setPassword', room: 'familie', password: '' });
  await waitFor(ada.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && (message.groups || []).some((group) => group.id === 'familie' && group.locked === false);
    } catch { return false; }
  }, 4000, clearAt);
  const jobAt = ada.inbox.length;
  send(ada, { t: 'createGroup', name: 'Jobb', password: 'jobbpass' });
  await waitFor(ada.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && (message.groups || []).some((group) => group.id === 'jobb' && group.locked === true && group.admin);
    } catch { return false; }
  }, 4000, jobAt);

  const token = adaSession.token;
  ada.ws.close();
  bob.ws.close();
  cara.ws.close();
  server.child.kill();
  await new Promise((resolve) => setTimeout(resolve, 200));
  server = await startServer();
  const again = await connect(server.url);
  send(again, { t: 'resume', token });
  const resumed = jsonText(await waitFor(again.inbox, (entry) => !entry.bin && entry.text.includes('"session"')));
  if (resumed.username !== 'ada') throw new Error('resume failed');
  const still = jsonText(await waitFor(again.inbox, (entry) => !entry.bin && entry.text.includes('"inbox"')));
  if (!still.groups.some((group) => group.id === 'familie' && group.admin)) throw new Error('group missing after restart');
  if (!still.groups.some((group) => group.id === 'jobb' && group.locked === true)) throw new Error('password missing after restart');

  console.log('accounts ok', versionJson.store);
  again.ws.close();
  server.child.kill();
  try { fs.unlinkSync(storeFile); } catch {}
  process.exit(0);
})().catch((error) => {
  console.error(error);
  try { fs.unlinkSync(storeFile); } catch {}
  process.exit(1);
});
