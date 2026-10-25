const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

class StoreError extends Error {}

function hashSecret(password) {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(password, salt, 32).toString('hex');
  return { salt, hash };
}

function secretMatches(password, record) {
  if (!record || !password || !record.salt || !record.hash) return false;
  const actual = crypto.scryptSync(password, record.salt, 32);
  const expected = Buffer.from(record.hash, 'hex');
  if (actual.length !== expected.length) return false;
  return crypto.timingSafeEqual(actual, expected);
}

function tokenHash(token) {
  return crypto.createHash('sha256').update(String(token)).digest('hex');
}

function newId() {
  return crypto.randomBytes(12).toString('hex');
}

function publicUser(user) {
  return { id: user.id, username: user.username, displayName: user.displayName };
}

function optionalSecret(password) {
  const value = password == null ? '' : String(password).slice(0, 80);
  if (!value) return null;
  if (value.length < 4) throw new StoreError('Passordet må ha minst 4 tegn.');
  return hashSecret(value);
}

function isLocked(group) {
  return !!(group && group.salt && group.hash);
}

function stampMember(groupId, userId, role) {
  return { groupId, userId, role, joinedAt: Date.now() };
}

function oldestOther(members, userId) {
  return members
    .filter((member) => member.userId !== userId)
    .sort((a, b) => (a.joinedAt || 0) - (b.joinedAt || 0) || String(a.userId).localeCompare(String(b.userId)))[0];
}

function directRoomId(idA, idB) {
  const pair = [idA, idB].sort().join(':');
  return 'dm' + crypto.createHash('sha256').update(pair).digest('hex').slice(0, 32);
}

class JsonStore {
  constructor(file) {
    this.kind = 'json';
    this.file = file;
    this.chain = Promise.resolve();
    this.data = { users: [], sessions: [], groups: [], members: [], invites: [], requests: [], blocks: [], reports: [], directRequests: [] };
  }

  async open() {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    try {
      const parsed = JSON.parse(fs.readFileSync(this.file, 'utf8'));
      if (parsed && typeof parsed === 'object') this.data = { ...this.data, ...parsed };
    } catch {}
    for (const key of Object.keys(this.data)) {
      if (!Array.isArray(this.data[key])) this.data[key] = [];
    }
  }

  enqueue(fn) {
    const run = this.chain.then(fn, fn);
    this.chain = run.then(() => {}, () => {});
    return run;
  }

  save() {
    const tmp = this.file + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(this.data));
    fs.renameSync(tmp, this.file);
  }

  createUser(username, displayName, password) {
    return this.enqueue(async () => {
      if (this.data.users.some((user) => user.username === username)) {
        throw new StoreError('Brukernavnet er opptatt');
      }
      const secret = hashSecret(password);
      const user = { id: newId(), username, displayName, salt: secret.salt, hash: secret.hash };
      this.data.users.push(user);
      this.save();
      return publicUser(user);
    });
  }

  verifyLogin(username, password) {
    return this.enqueue(async () => {
      const user = this.data.users.find((item) => item.username === username);
      if (!user || !secretMatches(password, user)) return null;
      return publicUser(user);
    });
  }

  createSession(userId) {
    return this.enqueue(async () => {
      const token = crypto.randomBytes(32).toString('hex');
      this.data.sessions.push({ tokenHash: tokenHash(token), userId });
      this.save();
      return token;
    });
  }

  userForToken(token) {
    return this.enqueue(async () => {
      const hash = tokenHash(token || '');
      const session = this.data.sessions.find((item) => item.tokenHash === hash);
      if (!session) return null;
      const user = this.data.users.find((item) => item.id === session.userId);
      return user ? publicUser(user) : null;
    });
  }

  deleteSession(token) {
    return this.enqueue(async () => {
      const hash = tokenHash(token || '');
      this.data.sessions = this.data.sessions.filter((item) => item.tokenHash !== hash);
      this.save();
    });
  }

  createGroup(name, roomId, ownerId, password) {
    return this.enqueue(async () => {
      if (/^dm[0-9a-f]{32}$/.test(roomId)) throw new StoreError('Skriv et gruppenavn.');
      if (this.data.groups.some((group) => group.id === roomId)) {
        throw new StoreError('Gruppen finnes allerede. Be om å bli med.');
      }
      const secret = optionalSecret(password);
      const group = { id: roomId, name, ownerId };
      if (secret) {
        group.salt = secret.salt;
        group.hash = secret.hash;
      }
      this.data.groups.push(group);
      this.data.members.push(stampMember(roomId, ownerId, 'admin'));
      this.save();
    });
  }

  groupsFor(userId) {
    return this.enqueue(async () => this.groupsForSync(userId));
  }

  groupsForSync(userId) {
    return this.data.members.filter((member) => member.userId === userId).map((member) => {
      const group = this.data.groups.find((item) => item.id === member.groupId);
      const direct = !!(group && group.direct);
      let name = group ? group.name : member.groupId;
      let peer = '';
      if (direct) {
        const other = this.data.members.find((item) => item.groupId === member.groupId && item.userId !== userId);
        const person = other && this.data.users.find((item) => item.id === other.userId);
        if (person) {
          name = person.displayName;
          peer = person.username;
        }
      }
      return {
        id: member.groupId,
        name,
        admin: member.role === 'admin',
        locked: isLocked(group),
        direct,
        peer,
        members: this.rosterSync(member.groupId)
      };
    });
  }

  rosterSync(groupId) {
    return this.data.members.filter((member) => member.groupId === groupId).map((member) => {
      const user = this.data.users.find((item) => item.id === member.userId);
      return {
        username: user ? user.username : '',
        name: user ? user.displayName : '',
        role: member.role
      };
    }).filter((member) => member.username);
  }

  invitesFor(userId) {
    return this.enqueue(async () => this.data.invites.filter((invite) => invite.userId === userId).map((invite) => {
      const group = this.data.groups.find((item) => item.id === invite.groupId);
      const from = this.data.users.find((item) => item.id === invite.fromId);
      return {
        room: invite.groupId,
        name: group ? group.name : invite.groupId,
        from: from ? from.username : '',
        fromName: from ? from.displayName : ''
      };
    }));
  }

  requestsForAdmin(userId) {
    return this.enqueue(async () => {
      const adminGroups = new Set(this.data.members.filter((member) => member.userId === userId && member.role === 'admin').map((member) => member.groupId));
      return this.data.requests.filter((request) => adminGroups.has(request.groupId)).map((request) => {
        const group = this.data.groups.find((item) => item.id === request.groupId);
        const user = this.data.users.find((item) => item.id === request.userId);
        return {
          room: request.groupId,
          name: group ? group.name : request.groupId,
          username: user ? user.username : '',
          displayName: user ? user.displayName : ''
        };
      }).filter((request) => request.username);
    });
  }

  invite(adminId, groupId, username) {
    return this.enqueue(async () => {
      this.requireAdminSync(adminId, groupId);
      const user = this.data.users.find((item) => item.username === username);
      if (!user) throw new StoreError('Fant ikke brukeren');
      if (user.id === adminId) throw new StoreError('Du kan ikke invitere deg selv');
      if (this.data.members.some((member) => member.groupId === groupId && member.userId === user.id)) {
        throw new StoreError('Allerede medlem');
      }
      this.data.invites = this.data.invites.filter((invite) => !(invite.groupId === groupId && invite.userId === user.id));
      this.data.requests = this.data.requests.filter((request) => !(request.groupId === groupId && request.userId === user.id));
      this.data.invites.push({ groupId, userId: user.id, fromId: adminId });
      this.save();
    });
  }

  replyInvite(userId, groupId, accept) {
    return this.enqueue(async () => {
      const invite = this.data.invites.find((item) => item.groupId === groupId && item.userId === userId);
      if (!invite) throw new StoreError('Fant ikke invitasjonen');
      this.data.invites = this.data.invites.filter((item) => item !== invite);
      if (accept && !this.data.members.some((member) => member.groupId === groupId && member.userId === userId)) {
        this.data.members.push(stampMember(groupId, userId, 'member'));
      }
      this.save();
    });
  }

  requestJoin(userId, groupId) {
    return this.enqueue(async () => {
      const group = this.data.groups.find((item) => item.id === groupId);
      if (!group) throw new StoreError('Fant ikke gruppen');
      if (this.data.members.some((member) => member.groupId === groupId && member.userId === userId)) {
        throw new StoreError('Allerede medlem');
      }
      if (this.data.invites.some((invite) => invite.groupId === groupId && invite.userId === userId)) {
        throw new StoreError('Du har en invitasjon. Godta den i stedet.');
      }
      if (!this.data.requests.some((request) => request.groupId === groupId && request.userId === userId)) {
        this.data.requests.push({ groupId, userId });
        this.save();
      }
    });
  }

  joinWithPassword(userId, groupId, password) {
    return this.enqueue(async () => {
      const group = this.data.groups.find((item) => item.id === groupId);
      if (!group) throw new StoreError('Fant ikke gruppen');
      if (this.data.members.some((member) => member.groupId === groupId && member.userId === userId)) {
        throw new StoreError('Allerede medlem');
      }
      if (!isLocked(group)) throw new StoreError('Gruppen har ikke passord. Be om å bli med.');
      if (!secretMatches(password, group)) throw new StoreError('Feil passord');
      this.data.invites = this.data.invites.filter((invite) => !(invite.groupId === groupId && invite.userId === userId));
      this.data.requests = this.data.requests.filter((request) => !(request.groupId === groupId && request.userId === userId));
      this.data.members.push(stampMember(groupId, userId, 'member'));
      this.save();
    });
  }

  setGroupPassword(adminId, groupId, password) {
    return this.enqueue(async () => {
      this.requireAdminSync(adminId, groupId);
      const group = this.data.groups.find((item) => item.id === groupId);
      if (!group) throw new StoreError('Fant ikke gruppen');
      const secret = optionalSecret(password);
      if (secret) {
        group.salt = secret.salt;
        group.hash = secret.hash;
      } else {
        delete group.salt;
        delete group.hash;
      }
      this.save();
    });
  }

  replyRequest(adminId, groupId, username, accept) {
    return this.enqueue(async () => {
      this.requireAdminSync(adminId, groupId);
      const user = this.data.users.find((item) => item.username === username);
      if (!user) throw new StoreError('Fant ikke brukeren');
      this.data.requests = this.data.requests.filter((request) => !(request.groupId === groupId && request.userId === user.id));
      if (accept && !this.data.members.some((member) => member.groupId === groupId && member.userId === user.id)) {
        this.data.members.push(stampMember(groupId, user.id, 'member'));
      }
      this.save();
    });
  }

  removeMember(adminId, groupId, username) {
    return this.enqueue(async () => {
      this.requireAdminSync(adminId, groupId);
      const user = this.data.users.find((item) => item.username === username);
      if (!user) throw new StoreError('Fant ikke brukeren');
      const member = this.data.members.find((item) => item.groupId === groupId && item.userId === user.id);
      if (!member) throw new StoreError('Ikke medlem');
      if (user.id === adminId) throw new StoreError('Du kan ikke fjerne deg selv.');
      if (member.role === 'admin') throw new StoreError('Admin kan ikke fjernes');
      this.data.members = this.data.members.filter((item) => item !== member);
      this.data.invites = this.data.invites.filter((item) => !(item.groupId === groupId && item.userId === user.id));
      this.data.requests = this.data.requests.filter((item) => !(item.groupId === groupId && item.userId === user.id));
      this.save();
    });
  }

  leave(userId, groupId) {
    return this.enqueue(async () => {
      const member = this.data.members.find((item) => item.groupId === groupId && item.userId === userId);
      if (!member) return;
      if (member.role === 'admin') throw new StoreError('Slett gruppen i stedet.');
      this.data.members = this.data.members.filter((item) => item !== member);
      this.save();
    });
  }

  deleteGroup(adminId, groupId) {
    return this.enqueue(async () => {
      this.requireAdminSync(adminId, groupId);
      this.data.groups = this.data.groups.filter((group) => group.id !== groupId);
      this.data.members = this.data.members.filter((member) => member.groupId !== groupId);
      this.data.invites = this.data.invites.filter((invite) => invite.groupId !== groupId);
      this.data.requests = this.data.requests.filter((request) => request.groupId !== groupId);
      this.save();
    });
  }

  requireAdminSync(userId, groupId) {
    const member = this.data.members.find((item) => item.groupId === groupId && item.userId === userId && item.role === 'admin');
    if (!member) throw new StoreError('Du er ikke admin');
  }

  block(userId, username) {
    return this.enqueue(async () => {
      const user = this.data.users.find((item) => item.username === username);
      if (!user) throw new StoreError('Fant ikke brukeren');
      if (user.id === userId) throw new StoreError('Du kan ikke blokkere deg selv.');
      if (!this.data.blocks.some((item) => item.userId === userId && item.blockedId === user.id)) {
        this.data.blocks.push({ userId, blockedId: user.id });
        this.save();
      }
    });
  }

  unblock(userId, username) {
    return this.enqueue(async () => {
      const user = this.data.users.find((item) => item.username === username);
      if (!user) throw new StoreError('Fant ikke brukeren');
      this.data.blocks = this.data.blocks.filter((item) => !(item.userId === userId && item.blockedId === user.id));
      this.save();
    });
  }

  blockedIds(userId) {
    return this.enqueue(async () => this.data.blocks.filter((item) => item.userId === userId).map((item) => item.blockedId));
  }

  blockedUsernames(userId) {
    return this.enqueue(async () => this.data.blocks.filter((item) => item.userId === userId).map((item) => {
      const user = this.data.users.find((entry) => entry.id === item.blockedId);
      return user ? user.username : '';
    }).filter(Boolean));
  }

  report(reporterId, username, room, reason) {
    return this.enqueue(async () => {
      const target = this.data.users.find((item) => item.username === username);
      if (!target) throw new StoreError('Fant ikke brukeren');
      if (target.id === reporterId) throw new StoreError('Du kan ikke rapportere deg selv.');
      const reporter = this.data.users.find((item) => item.id === reporterId);
      const entry = {
        id: newId(),
        reporterId,
        reporter: reporter ? reporter.username : '',
        targetId: target.id,
        targetUsername: target.username,
        room: room || '',
        reason: String(reason || 'Ingen begrunnelse').slice(0, 500),
        createdAt: Date.now()
      };
      this.data.reports.push(entry);
      this.save();
      console.log('report ' + JSON.stringify({ target: entry.targetUsername, room: entry.room, reason: entry.reason }));
    });
  }

  pairBlocked(userId, otherId) {
    return this.data.blocks.some((item) =>
      (item.userId === userId && item.blockedId === otherId) ||
      (item.userId === otherId && item.blockedId === userId)
    );
  }

  directBetween(userId, otherId) {
    const room = directRoomId(userId, otherId);
    const group = this.data.groups.find((item) => item.id === room && item.direct);
    if (!group) return false;
    const ids = this.data.members.filter((item) => item.groupId === room).map((item) => item.userId);
    return ids.includes(userId) && ids.includes(otherId);
  }

  directRequest(fromId, username) {
    return this.enqueue(async () => {
      const user = this.data.users.find((item) => item.username === username);
      if (!user) throw new StoreError('Fant ikke brukeren');
      if (user.id === fromId) throw new StoreError('Du kan ikke kontakte deg selv.');
      if (this.pairBlocked(fromId, user.id)) throw new StoreError('Du kan ikke kontakte denne brukeren.');
      if (this.directBetween(fromId, user.id)) throw new StoreError('Dere snakker allerede direkte.');
      const pending = this.data.directRequests.find((item) =>
        (item.fromId === fromId && item.toId === user.id) ||
        (item.fromId === user.id && item.toId === fromId)
      );
      if (pending && pending.fromId === fromId) throw new StoreError('Forespørselen er sendt.');
      if (pending) throw new StoreError('Du har en forespørsel. Godta den.');
      this.data.directRequests.push({ fromId, toId: user.id, createdAt: Date.now() });
      this.save();
    });
  }

  directReply(userId, username, accept) {
    return this.enqueue(async () => {
      const user = this.data.users.find((item) => item.username === username);
      if (!user) throw new StoreError('Fant ikke brukeren');
      const incoming = this.data.directRequests.find((item) => item.toId === userId && item.fromId === user.id);
      const outgoing = this.data.directRequests.find((item) => item.fromId === userId && item.toId === user.id);
      const request = incoming || (!accept ? outgoing : null);
      if (!request) throw new StoreError('Fant ikke forespørselen');
      if (accept && this.pairBlocked(userId, user.id)) throw new StoreError('Du kan ikke kontakte denne brukeren.');
      this.data.directRequests = this.data.directRequests.filter((item) => item !== request);
      const room = directRoomId(request.fromId, request.toId);
      if (accept && !this.directBetween(request.fromId, request.toId)) {
        if (!this.data.groups.some((item) => item.id === room)) {
          this.data.groups.push({ id: room, name: '', ownerId: request.fromId, direct: true });
        }
        for (const memberId of [request.fromId, request.toId]) {
          if (!this.data.members.some((item) => item.groupId === room && item.userId === memberId)) {
            this.data.members.push(stampMember(room, memberId, 'member'));
          }
        }
      }
      this.save();
      return accept ? room : '';
    });
  }

  directRequestsFor(userId) {
    return this.enqueue(async () => this.data.directRequests.filter((item) => item.fromId === userId || item.toId === userId).map((item) => {
      const incoming = item.toId === userId;
      const otherId = incoming ? item.fromId : item.toId;
      const person = this.data.users.find((entry) => entry.id === otherId);
      return {
        username: person ? person.username : '',
        name: person ? person.displayName : '',
        incoming
      };
    }).filter((item) => item.username));
  }

  removeDirect(userId, roomId) {
    return this.enqueue(async () => {
      const group = this.data.groups.find((item) => item.id === roomId && item.direct);
      if (!group) throw new StoreError('Fant ikke kanalen');
      const mine = this.data.members.find((item) => item.groupId === roomId && item.userId === userId);
      if (!mine) throw new StoreError('Ikke medlem');
      const memberIds = this.data.members.filter((item) => item.groupId === roomId).map((item) => item.userId);
      this.data.groups = this.data.groups.filter((item) => item.id !== roomId);
      this.data.members = this.data.members.filter((item) => item.groupId !== roomId);
      this.data.invites = this.data.invites.filter((item) => item.groupId !== roomId);
      this.data.requests = this.data.requests.filter((item) => item.groupId !== roomId);
      this.data.directRequests = this.data.directRequests.filter((item) => !(memberIds.includes(item.fromId) && memberIds.includes(item.toId)));
      this.save();
      return roomId;
    });
  }

  deleteAccount(userId) {
    return this.enqueue(async () => {
      const rooms = new Set();
      const directIds = this.data.members.filter((member) => member.userId === userId).map((member) => member.groupId).filter((groupId) => {
        const group = this.data.groups.find((item) => item.id === groupId);
        return group && group.direct;
      });
      for (const groupId of directIds) {
        rooms.add(groupId);
        this.data.groups = this.data.groups.filter((group) => group.id !== groupId);
        this.data.members = this.data.members.filter((member) => member.groupId !== groupId);
        this.data.invites = this.data.invites.filter((invite) => invite.groupId !== groupId);
        this.data.requests = this.data.requests.filter((request) => request.groupId !== groupId);
      }
      this.data.directRequests = this.data.directRequests.filter((item) => item.fromId !== userId && item.toId !== userId);
      const adminGroups = this.data.members.filter((member) => member.userId === userId && member.role === 'admin').map((member) => member.groupId);
      for (const groupId of adminGroups) {
        rooms.add(groupId);
        const others = this.data.members.filter((member) => member.groupId === groupId);
        const next = oldestOther(others, userId);
        if (!next) {
          this.data.groups = this.data.groups.filter((group) => group.id !== groupId);
          this.data.members = this.data.members.filter((member) => member.groupId !== groupId);
          this.data.invites = this.data.invites.filter((invite) => invite.groupId !== groupId);
          this.data.requests = this.data.requests.filter((request) => request.groupId !== groupId);
        } else {
          next.role = 'admin';
          const group = this.data.groups.find((item) => item.id === groupId);
          if (group) group.ownerId = next.userId;
        }
      }
      this.data.members.filter((member) => member.userId === userId).forEach((member) => rooms.add(member.groupId));
      this.data.members = this.data.members.filter((member) => member.userId !== userId);
      this.data.invites = this.data.invites.filter((invite) => invite.userId !== userId && invite.fromId !== userId);
      this.data.requests = this.data.requests.filter((request) => request.userId !== userId);
      this.data.sessions = this.data.sessions.filter((session) => session.userId !== userId);
      this.data.blocks = this.data.blocks.filter((item) => item.userId !== userId && item.blockedId !== userId);
      this.data.users = this.data.users.filter((user) => user.id !== userId);
      this.save();
      return [...rooms];
    });
  }
}

class PgStore {
  constructor(pool) {
    this.kind = 'postgres';
    this.pool = pool;
  }

  async open() {
    await this.pool.query(`
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
        username TEXT UNIQUE NOT NULL,
        display_name TEXT NOT NULL,
        salt TEXT NOT NULL,
        hash TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS sessions (
        token_hash TEXT PRIMARY KEY,
        user_id TEXT NOT NULL REFERENCES users(id)
      );
      CREATE TABLE IF NOT EXISTS groups (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        owner_id TEXT NOT NULL REFERENCES users(id),
        salt TEXT,
        hash TEXT
      );
      ALTER TABLE groups ADD COLUMN IF NOT EXISTS salt TEXT;
      ALTER TABLE groups ADD COLUMN IF NOT EXISTS hash TEXT;
      ALTER TABLE groups ADD COLUMN IF NOT EXISTS direct BOOLEAN NOT NULL DEFAULT FALSE;
      CREATE TABLE IF NOT EXISTS direct_requests (
        from_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        to_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        created_at BIGINT NOT NULL,
        PRIMARY KEY (from_id, to_id)
      );
      CREATE TABLE IF NOT EXISTS members (
        group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
        user_id TEXT NOT NULL REFERENCES users(id),
        role TEXT NOT NULL,
        joined_at BIGINT NOT NULL DEFAULT 0,
        PRIMARY KEY (group_id, user_id)
      );
      ALTER TABLE members ADD COLUMN IF NOT EXISTS joined_at BIGINT NOT NULL DEFAULT 0;
      CREATE TABLE IF NOT EXISTS blocks (
        user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        blocked_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        PRIMARY KEY (user_id, blocked_id)
      );
      CREATE TABLE IF NOT EXISTS reports (
        id TEXT PRIMARY KEY,
        reporter_id TEXT,
        reporter TEXT,
        target_id TEXT,
        target_username TEXT NOT NULL,
        room TEXT,
        reason TEXT,
        created_at BIGINT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS invites (
        group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
        user_id TEXT NOT NULL REFERENCES users(id),
        from_id TEXT NOT NULL REFERENCES users(id),
        PRIMARY KEY (group_id, user_id)
      );
      CREATE TABLE IF NOT EXISTS requests (
        group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
        user_id TEXT NOT NULL REFERENCES users(id),
        PRIMARY KEY (group_id, user_id)
      );
    `);
  }

  async createUser(username, displayName, password) {
    const secret = hashSecret(password);
    const id = newId();
    try {
      await this.pool.query(
        'INSERT INTO users (id, username, display_name, salt, hash) VALUES ($1, $2, $3, $4, $5)',
        [id, username, displayName, secret.salt, secret.hash]
      );
    } catch (error) {
      if (error.code === '23505') throw new StoreError('Brukernavnet er opptatt');
      throw error;
    }
    return { id, username, displayName };
  }

  async verifyLogin(username, password) {
    const result = await this.pool.query('SELECT id, username, display_name, salt, hash FROM users WHERE username = $1', [username]);
    const row = result.rows[0];
    if (!row || !secretMatches(password, { salt: row.salt, hash: row.hash })) return null;
    return { id: row.id, username: row.username, displayName: row.display_name };
  }

  async createSession(userId) {
    const token = crypto.randomBytes(32).toString('hex');
    await this.pool.query('INSERT INTO sessions (token_hash, user_id) VALUES ($1, $2)', [tokenHash(token), userId]);
    return token;
  }

  async userForToken(token) {
    const result = await this.pool.query(
      `SELECT u.id, u.username, u.display_name
       FROM sessions s JOIN users u ON u.id = s.user_id
       WHERE s.token_hash = $1`,
      [tokenHash(token || '')]
    );
    const row = result.rows[0];
    if (!row) return null;
    return { id: row.id, username: row.username, displayName: row.display_name };
  }

  async deleteSession(token) {
    await this.pool.query('DELETE FROM sessions WHERE token_hash = $1', [tokenHash(token || '')]);
  }

  async createGroup(name, roomId, ownerId, password) {
    if (/^dm[0-9a-f]{32}$/.test(roomId)) throw new StoreError('Skriv et gruppenavn.');
    const secret = optionalSecret(password);
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      await client.query(
        'INSERT INTO groups (id, name, owner_id, salt, hash) VALUES ($1, $2, $3, $4, $5)',
        [roomId, name, ownerId, secret ? secret.salt : null, secret ? secret.hash : null]
      );
      await client.query(
        'INSERT INTO members (group_id, user_id, role, joined_at) VALUES ($1, $2, $3, $4)',
        [roomId, ownerId, 'admin', Date.now()]
      );
      await client.query('COMMIT');
    } catch (error) {
      await client.query('ROLLBACK');
      if (error.code === '23505') throw new StoreError('Gruppen finnes allerede. Be om å bli med.');
      throw error;
    } finally {
      client.release();
    }
  }

  async groupsFor(userId) {
    const result = await this.pool.query(
      `SELECT g.id, g.name, g.salt, g.hash, g.direct, m.role
       FROM members m JOIN groups g ON g.id = m.group_id
       WHERE m.user_id = $1`,
      [userId]
    );
    const groups = [];
    for (const row of result.rows) {
      const direct = !!row.direct;
      let name = row.name;
      let peer = '';
      if (direct) {
        const other = await this.pool.query(
          `SELECT u.username, u.display_name
           FROM members m JOIN users u ON u.id = m.user_id
           WHERE m.group_id = $1 AND m.user_id <> $2
           LIMIT 1`,
          [row.id, userId]
        );
        if (other.rows[0]) {
          name = other.rows[0].display_name;
          peer = other.rows[0].username;
        }
      }
      groups.push({
        id: row.id,
        name,
        admin: row.role === 'admin',
        locked: !!(row.salt && row.hash),
        direct,
        peer,
        members: await this.roster(row.id)
      });
    }
    return groups;
  }

  async roster(groupId) {
    const result = await this.pool.query(
      `SELECT u.username, u.display_name, m.role
       FROM members m JOIN users u ON u.id = m.user_id
       WHERE m.group_id = $1`,
      [groupId]
    );
    return result.rows.map((row) => ({ username: row.username, name: row.display_name, role: row.role }));
  }

  async invitesFor(userId) {
    const result = await this.pool.query(
      `SELECT i.group_id, g.name, u.username, u.display_name
       FROM invites i
       JOIN groups g ON g.id = i.group_id
       JOIN users u ON u.id = i.from_id
       WHERE i.user_id = $1`,
      [userId]
    );
    return result.rows.map((row) => ({
      room: row.group_id,
      name: row.name,
      from: row.username,
      fromName: row.display_name
    }));
  }

  async requestsForAdmin(userId) {
    const result = await this.pool.query(
      `SELECT r.group_id, g.name, u.username, u.display_name
       FROM requests r
       JOIN groups g ON g.id = r.group_id
       JOIN members admin ON admin.group_id = g.id AND admin.user_id = $1 AND admin.role = 'admin'
       JOIN users u ON u.id = r.user_id`,
      [userId]
    );
    return result.rows.map((row) => ({
      room: row.group_id,
      name: row.name,
      username: row.username,
      displayName: row.display_name
    }));
  }

  async invite(adminId, groupId, username) {
    await this.requireAdmin(adminId, groupId);
    const user = await this.userByUsername(username);
    if (!user) throw new StoreError('Fant ikke brukeren');
    if (user.id === adminId) throw new StoreError('Du kan ikke invitere deg selv');
    const member = await this.pool.query('SELECT 1 FROM members WHERE group_id = $1 AND user_id = $2', [groupId, user.id]);
    if (member.rowCount) throw new StoreError('Allerede medlem');
    await this.pool.query('DELETE FROM requests WHERE group_id = $1 AND user_id = $2', [groupId, user.id]);
    await this.pool.query(
      `INSERT INTO invites (group_id, user_id, from_id) VALUES ($1, $2, $3)
       ON CONFLICT (group_id, user_id) DO UPDATE SET from_id = EXCLUDED.from_id`,
      [groupId, user.id, adminId]
    );
  }

  async replyInvite(userId, groupId, accept) {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const invite = await client.query('DELETE FROM invites WHERE group_id = $1 AND user_id = $2 RETURNING group_id', [groupId, userId]);
      if (!invite.rowCount) throw new StoreError('Fant ikke invitasjonen');
      if (accept) {
        await client.query(
          `INSERT INTO members (group_id, user_id, role, joined_at) VALUES ($1, $2, 'member', $3)
           ON CONFLICT DO NOTHING`,
          [groupId, userId, Date.now()]
        );
      }
      await client.query('COMMIT');
    } catch (error) {
      try { await client.query('ROLLBACK'); } catch {}
      throw error;
    } finally {
      client.release();
    }
  }

  async requestJoin(userId, groupId) {
    const group = await this.pool.query('SELECT id FROM groups WHERE id = $1', [groupId]);
    if (!group.rowCount) throw new StoreError('Fant ikke gruppen');
    const member = await this.pool.query('SELECT 1 FROM members WHERE group_id = $1 AND user_id = $2', [groupId, userId]);
    if (member.rowCount) throw new StoreError('Allerede medlem');
    const invite = await this.pool.query('SELECT 1 FROM invites WHERE group_id = $1 AND user_id = $2', [groupId, userId]);
    if (invite.rowCount) throw new StoreError('Du har en invitasjon. Godta den i stedet.');
    await this.pool.query(
      'INSERT INTO requests (group_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING',
      [groupId, userId]
    );
  }

  async joinWithPassword(userId, groupId, password) {
    const group = await this.pool.query('SELECT salt, hash FROM groups WHERE id = $1', [groupId]);
    if (!group.rowCount) throw new StoreError('Fant ikke gruppen');
    const member = await this.pool.query('SELECT 1 FROM members WHERE group_id = $1 AND user_id = $2', [groupId, userId]);
    if (member.rowCount) throw new StoreError('Allerede medlem');
    const row = group.rows[0];
    if (!row.salt || !row.hash) throw new StoreError('Gruppen har ikke passord. Be om å bli med.');
    if (!secretMatches(password, { salt: row.salt, hash: row.hash })) throw new StoreError('Feil passord');
    await this.pool.query('DELETE FROM invites WHERE group_id = $1 AND user_id = $2', [groupId, userId]);
    await this.pool.query('DELETE FROM requests WHERE group_id = $1 AND user_id = $2', [groupId, userId]);
    await this.pool.query(
      `INSERT INTO members (group_id, user_id, role, joined_at) VALUES ($1, $2, 'member', $3) ON CONFLICT DO NOTHING`,
      [groupId, userId, Date.now()]
    );
  }

  async setGroupPassword(adminId, groupId, password) {
    await this.requireAdmin(adminId, groupId);
    const secret = optionalSecret(password);
    if (!secret) {
      await this.pool.query('UPDATE groups SET salt = NULL, hash = NULL WHERE id = $1', [groupId]);
      return;
    }
    await this.pool.query('UPDATE groups SET salt = $2, hash = $3 WHERE id = $1', [groupId, secret.salt, secret.hash]);
  }

  async replyRequest(adminId, groupId, username, accept) {
    await this.requireAdmin(adminId, groupId);
    const user = await this.userByUsername(username);
    if (!user) throw new StoreError('Fant ikke brukeren');
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      await client.query('DELETE FROM requests WHERE group_id = $1 AND user_id = $2', [groupId, user.id]);
      if (accept) {
        await client.query(
          `INSERT INTO members (group_id, user_id, role, joined_at) VALUES ($1, $2, 'member', $3) ON CONFLICT DO NOTHING`,
          [groupId, user.id, Date.now()]
        );
      }
      await client.query('COMMIT');
    } catch (error) {
      try { await client.query('ROLLBACK'); } catch {}
      throw error;
    } finally {
      client.release();
    }
  }

  async removeMember(adminId, groupId, username) {
    await this.requireAdmin(adminId, groupId);
    const user = await this.userByUsername(username);
    if (!user) throw new StoreError('Fant ikke brukeren');
    const member = await this.pool.query('SELECT role FROM members WHERE group_id = $1 AND user_id = $2', [groupId, user.id]);
    if (!member.rowCount) throw new StoreError('Ikke medlem');
    if (user.id === adminId) throw new StoreError('Du kan ikke fjerne deg selv.');
    if (member.rows[0].role === 'admin') throw new StoreError('Admin kan ikke fjernes');
    await this.pool.query('DELETE FROM members WHERE group_id = $1 AND user_id = $2', [groupId, user.id]);
    await this.pool.query('DELETE FROM invites WHERE group_id = $1 AND user_id = $2', [groupId, user.id]);
    await this.pool.query('DELETE FROM requests WHERE group_id = $1 AND user_id = $2', [groupId, user.id]);
  }

  async leave(userId, groupId) {
    const member = await this.pool.query('SELECT role FROM members WHERE group_id = $1 AND user_id = $2', [groupId, userId]);
    if (!member.rowCount) return;
    if (member.rows[0].role === 'admin') throw new StoreError('Slett gruppen i stedet.');
    await this.pool.query('DELETE FROM members WHERE group_id = $1 AND user_id = $2', [groupId, userId]);
  }

  async deleteGroup(adminId, groupId) {
    await this.requireAdmin(adminId, groupId);
    await this.pool.query('DELETE FROM groups WHERE id = $1', [groupId]);
  }

  async requireAdmin(userId, groupId) {
    const result = await this.pool.query(
      `SELECT 1 FROM members WHERE group_id = $1 AND user_id = $2 AND role = 'admin'`,
      [groupId, userId]
    );
    if (!result.rowCount) throw new StoreError('Du er ikke admin');
  }

  async userByUsername(username) {
    const result = await this.pool.query('SELECT id, username, display_name FROM users WHERE username = $1', [username]);
    const row = result.rows[0];
    if (!row) return null;
    return { id: row.id, username: row.username, displayName: row.display_name };
  }

  async block(userId, username) {
    const user = await this.userByUsername(username);
    if (!user) throw new StoreError('Fant ikke brukeren');
    if (user.id === userId) throw new StoreError('Du kan ikke blokkere deg selv.');
    await this.pool.query(
      'INSERT INTO blocks (user_id, blocked_id) VALUES ($1, $2) ON CONFLICT DO NOTHING',
      [userId, user.id]
    );
  }

  async unblock(userId, username) {
    const user = await this.userByUsername(username);
    if (!user) throw new StoreError('Fant ikke brukeren');
    await this.pool.query('DELETE FROM blocks WHERE user_id = $1 AND blocked_id = $2', [userId, user.id]);
  }

  async blockedIds(userId) {
    const result = await this.pool.query('SELECT blocked_id FROM blocks WHERE user_id = $1', [userId]);
    return result.rows.map((row) => row.blocked_id);
  }

  async blockedUsernames(userId) {
    const result = await this.pool.query(
      `SELECT u.username FROM blocks b JOIN users u ON u.id = b.blocked_id WHERE b.user_id = $1`,
      [userId]
    );
    return result.rows.map((row) => row.username);
  }

  async report(reporterId, username, room, reason) {
    const target = await this.userByUsername(username);
    if (!target) throw new StoreError('Fant ikke brukeren');
    if (target.id === reporterId) throw new StoreError('Du kan ikke rapportere deg selv.');
    const reporter = await this.pool.query('SELECT username FROM users WHERE id = $1', [reporterId]);
    const text = String(reason || 'Ingen begrunnelse').slice(0, 500);
    await this.pool.query(
      `INSERT INTO reports (id, reporter_id, reporter, target_id, target_username, room, reason, created_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
      [newId(), reporterId, reporter.rows[0] ? reporter.rows[0].username : '', target.id, target.username, room || '', text, Date.now()]
    );
    console.log('report ' + JSON.stringify({ target: target.username, room: room || '', reason: text }));
  }

  async pairBlocked(userId, otherId) {
    const result = await this.pool.query(
      `SELECT 1 FROM blocks
       WHERE (user_id = $1 AND blocked_id = $2) OR (user_id = $2 AND blocked_id = $1)`,
      [userId, otherId]
    );
    return !!result.rowCount;
  }

  async directBetween(userId, otherId) {
    const room = directRoomId(userId, otherId);
    const result = await this.pool.query(
      `SELECT 1 FROM groups g
       WHERE g.id = $1 AND g.direct = TRUE
         AND EXISTS (SELECT 1 FROM members WHERE group_id = g.id AND user_id = $2)
         AND EXISTS (SELECT 1 FROM members WHERE group_id = g.id AND user_id = $3)`,
      [room, userId, otherId]
    );
    return !!result.rowCount;
  }

  async directRequest(fromId, username) {
    const user = await this.userByUsername(username);
    if (!user) throw new StoreError('Fant ikke brukeren');
    if (user.id === fromId) throw new StoreError('Du kan ikke kontakte deg selv.');
    if (await this.pairBlocked(fromId, user.id)) throw new StoreError('Du kan ikke kontakte denne brukeren.');
    if (await this.directBetween(fromId, user.id)) throw new StoreError('Dere snakker allerede direkte.');
    const pending = await this.pool.query(
      `SELECT from_id FROM direct_requests
       WHERE (from_id = $1 AND to_id = $2) OR (from_id = $2 AND to_id = $1)`,
      [fromId, user.id]
    );
    if (pending.rows[0] && pending.rows[0].from_id === fromId) throw new StoreError('Forespørselen er sendt.');
    if (pending.rowCount) throw new StoreError('Du har en forespørsel. Godta den.');
    await this.pool.query(
      'INSERT INTO direct_requests (from_id, to_id, created_at) VALUES ($1, $2, $3)',
      [fromId, user.id, Date.now()]
    );
  }

  async directReply(userId, username, accept) {
    const user = await this.userByUsername(username);
    if (!user) throw new StoreError('Fant ikke brukeren');
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const incoming = await client.query(
        'SELECT from_id, to_id FROM direct_requests WHERE to_id = $1 AND from_id = $2',
        [userId, user.id]
      );
      const outgoing = await client.query(
        'SELECT from_id, to_id FROM direct_requests WHERE from_id = $1 AND to_id = $2',
        [userId, user.id]
      );
      const request = incoming.rows[0] || (!accept ? outgoing.rows[0] : null);
      if (!request) throw new StoreError('Fant ikke forespørselen');
      if (accept && await this.pairBlocked(userId, user.id)) throw new StoreError('Du kan ikke kontakte denne brukeren.');
      await client.query('DELETE FROM direct_requests WHERE from_id = $1 AND to_id = $2', [request.from_id, request.to_id]);
      const room = directRoomId(request.from_id, request.to_id);
      if (accept) {
        await client.query(
          `INSERT INTO groups (id, name, owner_id, direct) VALUES ($1, '', $2, TRUE)
           ON CONFLICT (id) DO UPDATE SET direct = TRUE`,
          [room, request.from_id]
        );
        for (const memberId of [request.from_id, request.to_id]) {
          await client.query(
            `INSERT INTO members (group_id, user_id, role, joined_at) VALUES ($1, $2, 'member', $3)
             ON CONFLICT DO NOTHING`,
            [room, memberId, Date.now()]
          );
        }
      }
      await client.query('COMMIT');
      return accept ? room : '';
    } catch (error) {
      try { await client.query('ROLLBACK'); } catch {}
      throw error;
    } finally {
      client.release();
    }
  }

  async directRequestsFor(userId) {
    const result = await this.pool.query(
      `SELECT r.from_id, r.to_id, u.username, u.display_name
       FROM direct_requests r
       JOIN users u ON u.id = CASE WHEN r.to_id = $1 THEN r.from_id ELSE r.to_id END
       WHERE r.from_id = $1 OR r.to_id = $1`,
      [userId]
    );
    return result.rows.map((row) => ({
      username: row.username,
      name: row.display_name,
      incoming: row.to_id === userId
    }));
  }

  async removeDirect(userId, roomId) {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const group = await client.query('SELECT direct FROM groups WHERE id = $1', [roomId]);
      if (!group.rowCount || !group.rows[0].direct) throw new StoreError('Fant ikke kanalen');
      const mine = await client.query(
        'SELECT 1 FROM members WHERE group_id = $1 AND user_id = $2',
        [roomId, userId]
      );
      if (!mine.rowCount) throw new StoreError('Ikke medlem');
      const members = await client.query('SELECT user_id FROM members WHERE group_id = $1', [roomId]);
      const ids = members.rows.map((row) => row.user_id);
      await client.query('DELETE FROM groups WHERE id = $1', [roomId]);
      if (ids.length >= 2) {
        await client.query(
          `DELETE FROM direct_requests
           WHERE (from_id = $1 AND to_id = $2) OR (from_id = $2 AND to_id = $1)`,
          [ids[0], ids[1]]
        );
      }
      await client.query('COMMIT');
      return roomId;
    } catch (error) {
      try { await client.query('ROLLBACK'); } catch {}
      throw error;
    } finally {
      client.release();
    }
  }

  async deleteAccount(userId) {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const directs = await client.query(
        `SELECT g.id FROM groups g
         JOIN members m ON m.group_id = g.id
         WHERE m.user_id = $1 AND g.direct = TRUE`,
        [userId]
      );
      for (const row of directs.rows) {
        await client.query('DELETE FROM groups WHERE id = $1', [row.id]);
      }
      await client.query('DELETE FROM direct_requests WHERE from_id = $1 OR to_id = $1', [userId]);
      const adminGroups = await client.query(
        `SELECT group_id FROM members WHERE user_id = $1 AND role = 'admin'`,
        [userId]
      );
      const rooms = new Set(adminGroups.rows.map((row) => row.group_id));
      directs.rows.forEach((row) => rooms.add(row.id));
      for (const row of adminGroups.rows) {
        const next = await client.query(
          `SELECT user_id FROM members WHERE group_id = $1 AND user_id <> $2
           ORDER BY joined_at ASC, user_id ASC LIMIT 1`,
          [row.group_id, userId]
        );
        if (!next.rowCount) {
          await client.query('DELETE FROM groups WHERE id = $1', [row.group_id]);
        } else {
          const heir = next.rows[0].user_id;
          await client.query(
            `UPDATE members SET role = 'admin' WHERE group_id = $1 AND user_id = $2`,
            [row.group_id, heir]
          );
          await client.query('UPDATE groups SET owner_id = $2 WHERE id = $1', [row.group_id, heir]);
        }
      }
      const memberships = await client.query('SELECT group_id FROM members WHERE user_id = $1', [userId]);
      memberships.rows.forEach((row) => rooms.add(row.group_id));
      await client.query('DELETE FROM members WHERE user_id = $1', [userId]);
      await client.query('DELETE FROM invites WHERE user_id = $1 OR from_id = $1', [userId]);
      await client.query('DELETE FROM requests WHERE user_id = $1', [userId]);
      await client.query('DELETE FROM sessions WHERE user_id = $1', [userId]);
      await client.query('DELETE FROM blocks WHERE user_id = $1 OR blocked_id = $1', [userId]);
      await client.query('DELETE FROM users WHERE id = $1', [userId]);
      await client.query('COMMIT');
      return [...rooms];
    } catch (error) {
      try { await client.query('ROLLBACK'); } catch {}
      throw error;
    } finally {
      client.release();
    }
  }
}

async function openStore() {
  if (process.env.DATABASE_URL) {
    const { Pool } = require('pg');
    const connectionString = process.env.DATABASE_URL;
    const local = /localhost|127\.0\.0\.1/.test(connectionString);
    const pool = new Pool({
      connectionString,
      ssl: local ? false : { rejectUnauthorized: false }
    });
    const store = new PgStore(pool);
    await store.open();
    return store;
  }
  const file = process.env.STORE_PATH || path.join(__dirname, 'data', 'walkie.json');
  const store = new JsonStore(file);
  await store.open();
  return store;
}

module.exports = { openStore, StoreError };
