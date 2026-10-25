#!/usr/bin/env node
// Signup, invite, and audio: only members receive frames. Same display name
// on purpose. Restarts the JSON store and resumes the session token.
// Terms, block, report, and account deletion are checked too.
//
//   node scripts/relay-check.js --local

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const WebSocket = require('ws');

const storeFile = path.join(os.tmpdir(), 'walkie-account-' + process.pid + '.json');
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

function signup(client, username, name, password) {
  send(client, { t: 'signup', username, name, password, terms: true });
}

function getText(url) {
  return new Promise((resolve, reject) => {
    require('http').get(url, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, body }));
    }).on('error', reject);
  });
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
  activeChild = child;
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
  const personvern = await getText(server.http + '/personvern');
  if (personvern.status !== 200 || !personvern.body.includes('Lyden lagres ikke') || !personvern.body.includes('never stored')) {
    throw new Error('personvern ' + personvern.status);
  }
  const vilkar = await getText(server.http + '/vilkar');
  if (vilkar.status !== 200 || !vilkar.body.includes('nulltoleranse') || !vilkar.body.includes('zero tolerance')) {
    throw new Error('vilkar ' + vilkar.status);
  }

  const bare = await connect(server.url);
  send(bare, { t: 'signup', username: 'ada', name: 'Sku', password: 'secret1' });
  const needsTerms = jsonText(await waitFor(bare.inbox, (entry) => !entry.bin && entry.text.includes('vilkårene')));
  if (!String(needsTerms.error || '').includes('vilkårene')) throw new Error('signup without terms was accepted');
  bare.ws.close();

  const ada = await connect(server.url);
  signup(ada, 'ada', 'Sku', 'secret1');
  const adaSession = jsonText(await waitFor(ada.inbox, (entry) => !entry.bin && entry.text.includes('"session"')));
  if (!adaSession.token || adaSession.username !== 'ada') throw new Error('signup session ' + adaSession.token);

  const dup = await connect(server.url);
  signup(dup, 'ada', 'Annen', 'secret1');
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
  signup(bob, 'bob', 'Sku', 'secret2');
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
  signup(cara, 'cara', 'Cara', 'secret3');
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

  const blockAt = ada.inbox.length;
  send(ada, { t: 'block', username: 'bob' });
  await waitFor(ada.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && Array.isArray(message.blocked) && message.blocked.includes('bob');
    } catch { return false; }
  }, 4000, blockAt);
  const mutedAt = ada.inbox.length;
  const caraStill = cara.inbox.length;
  bob.ws.send(frame);
  const caraHeardBlock = await waitFor(cara.inbox, (entry) => entry.bin, 3000, caraStill);
  if (!caraHeardBlock.data.equals(frame)) throw new Error('block stopped audio for someone else');
  await new Promise((resolve) => setTimeout(resolve, 250));
  if (ada.inbox.slice(mutedAt).some((entry) => entry.bin)) throw new Error('blocked audio was played');
  const unblockAt = ada.inbox.length;
  send(ada, { t: 'unblock', username: 'bob' });
  await waitFor(ada.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && Array.isArray(message.blocked) && !message.blocked.includes('bob');
    } catch { return false; }
  }, 4000, unblockAt);
  const openAt = ada.inbox.length;
  bob.ws.send(frame);
  const unblocked = await waitFor(ada.inbox, (entry) => entry.bin, 3000, openAt);
  if (!unblocked.data.equals(frame)) throw new Error('unblock did not restore audio');
  const reportAt = ada.inbox.length;
  send(ada, { t: 'report', username: 'bob', room: 'familie', reason: 'Uakseptabel oppførsel' });
  const reported = jsonText(await waitFor(ada.inbox, (entry) => !entry.bin && entry.text.includes('"reported"'), 4000, reportAt));
  if (reported.t !== 'reported') throw new Error('report was not stored');

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

  const selfDirect = ada.inbox.length;
  send(ada, { t: 'direct', username: 'ada' });
  const selfDenied = jsonText(await waitFor(ada.inbox, (entry) => !entry.bin && entry.text.includes('deg selv'), 4000, selfDirect));
  if (!String(selfDenied.error || '').includes('deg selv')) throw new Error('self direct was accepted');

  const askBob = bob.inbox.length;
  send(ada, { t: 'direct', username: 'bob' });
  const bobAsked = jsonText(await waitFor(bob.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && (message.directs || []).some((item) => item.username === 'ada' && item.incoming === true);
    } catch { return false; }
  }, 4000, askBob));
  if (!bobAsked.directs.some((item) => item.username === 'ada' && item.incoming)) throw new Error('direct request missing');
  const declineAt = ada.inbox.length;
  send(bob, { t: 'directReply', username: 'ada', accept: false });
  await waitFor(ada.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && !(message.directs || []).some((item) => item.username === 'bob');
    } catch { return false; }
  }, 4000, declineAt);

  const askCara = cara.inbox.length;
  send(ada, { t: 'direct', username: 'cara' });
  await waitFor(cara.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && (message.directs || []).some((item) => item.username === 'ada' && item.incoming === true);
    } catch { return false; }
  }, 4000, askCara);
  const acceptAt = ada.inbox.length;
  send(cara, { t: 'directReply', username: 'ada', accept: true });
  const adaDirect = jsonText(await waitFor(ada.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && (message.groups || []).some((group) => group.direct === true && group.peer === 'cara' && group.name === 'Cara');
    } catch { return false; }
  }, 4000, acceptAt));
  const dm = adaDirect.groups.find((group) => group.direct && group.peer === 'cara');
  if (!dm) throw new Error('direct channel missing for ada');
  const caraDirect = jsonText(await waitFor(cara.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && (message.groups || []).some((group) => group.id === dm.id && group.direct === true && group.peer === 'ada' && group.name === 'Sku');
    } catch { return false; }
  }, 4000, askCara));
  if (!caraDirect.groups.some((group) => group.id === dm.id && group.peer === 'ada')) throw new Error('direct channel missing for cara');
  send(ada, { t: 'subscribe', talk: dm.id, muted: [] });
  send(cara, { t: 'subscribe', talk: dm.id, muted: [] });
  const dmHear = cara.inbox.length;
  ada.ws.send(frame);
  const dmAudio = await waitFor(cara.inbox, (entry) => entry.bin, 3000, dmHear);
  if (!dmAudio.data.equals(frame)) throw new Error('direct audio missed');
  const blockDm = ada.inbox.length;
  send(ada, { t: 'block', username: 'cara' });
  await waitFor(ada.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && Array.isArray(message.blocked) && message.blocked.includes('cara');
    } catch { return false; }
  }, 4000, blockDm);
  const adaSilent = ada.inbox.length;
  const caraSilent = cara.inbox.length;
  cara.ws.send(frame);
  ada.ws.send(frame);
  await new Promise((resolve) => setTimeout(resolve, 250));
  if (ada.inbox.slice(adaSilent).some((entry) => entry.bin)) throw new Error('blocked direct audio was played');
  if (cara.inbox.slice(caraSilent).some((entry) => entry.bin)) throw new Error('direct audio reached a blocked person');
  const openDm = ada.inbox.length;
  send(ada, { t: 'unblock', username: 'cara' });
  await waitFor(ada.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && Array.isArray(message.blocked) && !message.blocked.includes('cara');
    } catch { return false; }
  }, 4000, openDm);
  const againDm = cara.inbox.length;
  ada.ws.send(frame);
  const dmBack = await waitFor(cara.inbox, (entry) => entry.bin, 3000, againDm);
  if (!dmBack.data.equals(frame)) throw new Error('direct audio did not return after unblock');

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
  const kept = still.groups.find((group) => group.direct === true && group.peer === 'cara' && group.name === 'Cara');
  if (!kept) throw new Error('direct channel missing after restart');

  const bobAgain = await connect(server.url);
  send(bobAgain, { t: 'login', username: 'bob', password: 'secret2' });
  await waitFor(bobAgain.inbox, (entry) => !entry.bin && entry.text.includes('"session"'));
  const caraAgain = await connect(server.url);
  send(caraAgain, { t: 'login', username: 'cara', password: 'secret3' });
  await waitFor(caraAgain.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && (message.groups || []).some((group) => group.id === kept.id);
    } catch { return false; }
  });
  const beforeDelete = JSON.parse(fs.readFileSync(storeFile, 'utf8'));
  const adaId = (beforeDelete.users.find((user) => user.username === 'ada') || {}).id;
  const caraId = (beforeDelete.users.find((user) => user.username === 'cara') || {}).id;
  const familieMembers = beforeDelete.members.filter((member) => member.groupId === 'familie' && member.userId !== adaId);
  familieMembers.sort((a, b) => (a.joinedAt || 0) - (b.joinedAt || 0) || String(a.userId).localeCompare(String(b.userId)));
  if (!familieMembers.length || familieMembers[0].userId !== caraId) throw new Error('expected cara to be the oldest other member');
  const dmId = kept.id;
  const endAt = caraAgain.inbox.length;
  send(again, { t: 'removeDirect', room: dmId });
  const ended = jsonText(await waitFor(caraAgain.inbox, (entry) => !entry.bin && entry.text.includes('avsluttet'), 4000, endAt));
  if (!String(ended.error || '').includes('avsluttet')) throw new Error('direct end was not announced');
  await waitFor(caraAgain.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && !(message.groups || []).some((group) => group.id === dmId);
    } catch { return false; }
  }, 4000, endAt);
  const blockedAsk = again.inbox.length;
  send(caraAgain, { t: 'block', username: 'ada' });
  await waitFor(caraAgain.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && Array.isArray(message.blocked) && message.blocked.includes('ada');
    } catch { return false; }
  }, 4000, endAt);
  send(again, { t: 'direct', username: 'cara' });
  const blockedDirect = jsonText(await waitFor(again.inbox, (entry) => !entry.bin && entry.text.includes('kan ikke kontakte'), 4000, blockedAsk));
  if (!String(blockedDirect.error || '').includes('kan ikke kontakte')) throw new Error('blocked direct request was accepted');
  const clearBlock = caraAgain.inbox.length;
  send(caraAgain, { t: 'unblock', username: 'ada' });
  await waitFor(caraAgain.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && Array.isArray(message.blocked) && !message.blocked.includes('ada');
    } catch { return false; }
  }, 4000, clearBlock);
  const reask = caraAgain.inbox.length;
  send(again, { t: 'direct', username: 'cara' });
  await waitFor(caraAgain.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && (message.directs || []).some((item) => item.username === 'ada' && item.incoming === true);
    } catch { return false; }
  }, 4000, reask);
  send(caraAgain, { t: 'directReply', username: 'ada', accept: true });
  await waitFor(caraAgain.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      return message.t === 'inbox' && (message.groups || []).some((group) => group.direct === true && group.peer === 'ada');
    } catch { return false; }
  }, 4000, reask);
  const deleteAt = again.inbox.length;
  const caraDeleteAt = caraAgain.inbox.length;
  send(again, { t: 'deleteAccount' });
  const deleted = jsonText(await waitFor(again.inbox, (entry) => !entry.bin && entry.text.includes('"deleted"'), 4000, deleteAt));
  if (deleted.t !== 'deleted') throw new Error('account was not deleted');
  await waitFor(caraAgain.inbox, (entry) => {
    if (entry.bin) return false;
    try {
      const message = JSON.parse(entry.text);
      const familie = (message.groups || []).find((group) => group.id === 'familie');
      return message.t === 'inbox' && familie && familie.admin === true && !(message.groups || []).some((group) => group.id === 'jobb') && !(message.groups || []).some((group) => group.direct && group.peer === 'ada');
    } catch { return false; }
  }, 4000, caraDeleteAt);
  const saved = JSON.parse(fs.readFileSync(storeFile, 'utf8'));
  if (saved.users.some((user) => user.username === 'ada')) throw new Error('deleted user remains');
  if (saved.sessions.some((session) => session.userId === adaId)) throw new Error('deleted session remains');
  if (saved.members.some((member) => member.userId === adaId)) throw new Error('deleted membership remains');
  if (saved.groups.some((group) => group.id === 'jobb')) throw new Error('empty admin group survived');
  const familie = saved.groups.find((group) => group.id === 'familie');
  const caraMember = saved.members.find((member) => member.groupId === 'familie' && member.userId === caraId);
  if (!familie || familie.ownerId !== caraId || !caraMember || caraMember.role !== 'admin') throw new Error('admin was not transferred');
  if (!saved.reports.some((report) => report.reporter === 'ada' && report.targetUsername === 'bob')) throw new Error('report missing from store');
  const dead = await connect(server.url);
  send(dead, { t: 'resume', token });
  const gone = jsonText(await waitFor(dead.inbox, (entry) => !entry.bin && entry.text.includes('Logg inn')));
  if (!String(gone.error || '').includes('Logg inn')) throw new Error('deleted token still resumed');

  console.log('accounts ok', versionJson.store);
  bobAgain.ws.close();
  caraAgain.ws.close();
  dead.ws.close();
  again.ws.close();
  server.child.kill();
  try { fs.unlinkSync(storeFile); } catch {}
  process.exit(0);
})().catch((error) => {
  console.error(error);
  if (activeChild) activeChild.kill();
  try { fs.unlinkSync(storeFile); } catch {}
  process.exit(1);
});
