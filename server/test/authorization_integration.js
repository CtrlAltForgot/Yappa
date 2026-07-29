const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const Database = require('better-sqlite3');
const nacl = require('tweetnacl');
const WebSocket = require('ws');

const port = 4197;
const baseUrl = `http://127.0.0.1:${port}`;
const testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'yappa-authz-test-'));
const dbPath = path.join(testDir, 'test.db');

const server = spawn(process.execPath, ['src/server.js'], {
  cwd: path.resolve(__dirname, '..'),
  env: {
    ...process.env,
    PORT: String(port),
    DB_PATH: dbPath,
    BCRYPT_COST: '10',
    NEW_ACCOUNT_PASSWORD_MIN_LENGTH: '10',
    AUTH_RATE_LIMIT_MAX: '100',
    CHALLENGE_RATE_LIMIT_MAX: '100',
    CORS_ORIGIN: '',
    LIVEKIT_URL: 'ws://127.0.0.1:7880',
    LIVEKIT_API_KEY: 'authorization-test-key',
    LIVEKIT_API_SECRET: 'authorization-test-secret-that-is-long-enough',
  },
  stdio: ['ignore', 'ignore', 'pipe'],
});

let serverErrors = '';
server.stderr.on('data', (chunk) => {
  serverErrors += chunk.toString();
});

async function waitForServer() {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    try {
      const response = await fetch(`${baseUrl}/health`);
      if (response.ok) return;
    } catch (_) {
      // The disposable server is still starting.
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Disposable server did not start.\n${serverErrors}`);
}

async function request(
  route,
  { token, method = 'GET', body } = {},
) {
  const headers = { Accept: 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  return fetch(`${baseUrl}${route}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function createAccount(username) {
  const keyPair = nacl.sign.keyPair();
  const mediaKeyPair = crypto.generateKeyPairSync('x25519');
  const mediaPublicKey = mediaKeyPair.publicKey.export({ format: 'jwk' }).x;
  const mediaDeviceId = `device_${crypto
    .randomBytes(18)
    .toString('base64url')}`;
  const challengeResponse = await request('/api/auth/yuid/challenge');
  assert.equal(challengeResponse.status, 200);
  const challenge = (await challengeResponse.json()).challenge;
  const message = Buffer.from(
    `yappa-auth-v1|${challenge.serverId}|${username}|${challenge.nonce}`,
    'utf8',
  );
  const signature = nacl.sign.detached(
    new Uint8Array(message),
    keyPair.secretKey,
  );
  const mediaSignature = nacl.sign.detached(
    new Uint8Array(
      Buffer.from(
        `yappa-media-device-v1|${challenge.serverId}|${username}|` +
          `${challenge.nonce}|${mediaPublicKey}|${mediaDeviceId}`,
        'utf8',
      ),
    ),
    keyPair.secretKey,
  );
  const response = await request('/api/auth/session', {
    method: 'POST',
    body: {
      username,
      password: 'authorization-test-password',
      yuidPublicKey: Buffer.from(keyPair.publicKey).toString('base64url'),
      yuidSignature: Buffer.from(signature).toString('base64url'),
      yuidNonce: challenge.nonce,
      mediaDeviceId,
      mediaPublicKey,
      mediaDeviceSignature: Buffer.from(mediaSignature).toString('base64url'),
      deviceName: 'Authorization integration test',
    },
  });
  assert.equal(response.status, 201);
  const body = await response.json();
  return {
    ...body,
    mediaDeviceId,
    mediaPublicKey,
    yuidKeyPair: keyPair,
  };
}

async function createAdditionalDevice(account) {
  const username = account.user.username;
  const mediaKeyPair = crypto.generateKeyPairSync('x25519');
  const mediaPublicKey = mediaKeyPair.publicKey.export({ format: 'jwk' }).x;
  const mediaDeviceId = `device_${crypto
    .randomBytes(18)
    .toString('base64url')}`;
  const challenge = (
    await (await request('/api/auth/yuid/challenge')).json()
  ).challenge;
  const authSignature = nacl.sign.detached(
    new Uint8Array(
      Buffer.from(
        `yappa-auth-v1|${challenge.serverId}|${username}|${challenge.nonce}`,
        'utf8',
      ),
    ),
    account.yuidKeyPair.secretKey,
  );
  const mediaSignature = nacl.sign.detached(
    new Uint8Array(
      Buffer.from(
        `yappa-media-device-v1|${challenge.serverId}|${username}|` +
          `${challenge.nonce}|${mediaPublicKey}|${mediaDeviceId}`,
        'utf8',
      ),
    ),
    account.yuidKeyPair.secretKey,
  );
  const response = await request('/api/auth/session', {
    method: 'POST',
    body: {
      username,
      password: 'authorization-test-password',
      yuidPublicKey: Buffer.from(account.yuidKeyPair.publicKey).toString(
        'base64url',
      ),
      yuidSignature: Buffer.from(authSignature).toString('base64url'),
      yuidNonce: challenge.nonce,
      mediaDeviceId,
      mediaPublicKey,
      mediaDeviceSignature: Buffer.from(mediaSignature).toString('base64url'),
      deviceName: 'Additional authorization test device',
    },
  });
  assert.equal(response.status, 201);
  return {
    ...(await response.json()),
    mediaDeviceId,
    mediaPublicKey,
    yuidKeyPair: account.yuidKeyPair,
  };
}

async function requestBytes(route, {token, bytes, digest}) {
  return fetch(`${baseUrl}${route}`, {
    method: 'PUT',
    headers: {
      Accept: 'application/json',
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/octet-stream',
      'X-Yappa-Content-SHA256': digest,
    },
    body: bytes,
  });
}

async function expectStatus(route, status, options) {
  const response = await request(route, options);
  assert.equal(response.status, status, `${options?.method || 'GET'} ${route}`);
  return response;
}

async function expectSocketRejected(token) {
  await new Promise((resolve, reject) => {
    const socket = new WebSocket(
      `ws://127.0.0.1:${port}/socket.io/?EIO=4&transport=websocket`,
    );
    const timer = setTimeout(() => {
      socket.close();
      reject(new Error('Unauthenticated socket was not rejected.'));
    }, 2500);
    socket.on('message', (data) => {
      const packet = data.toString();
      if (packet.startsWith('0')) {
        socket.send(`40${JSON.stringify(token ? { token } : {})}`);
      } else if (packet.startsWith('44')) {
        clearTimeout(timer);
        socket.close();
        resolve();
      } else if (packet.startsWith('40')) {
        clearTimeout(timer);
        socket.close();
        reject(new Error('Unauthenticated socket connected.'));
      }
    });
    socket.on('error', reject);
  });
}

async function expectInvalidVoiceJoin(token, channelId) {
  await new Promise((resolve, reject) => {
    const socket = new WebSocket(
      `ws://127.0.0.1:${port}/socket.io/?EIO=4&transport=websocket`,
    );
    const timer = setTimeout(() => {
      socket.close();
      reject(new Error('Authenticated socket test timed out.'));
    }, 2500);
    socket.on('message', (data) => {
      const packet = data.toString();
      if (packet.startsWith('0')) {
        socket.send(`40${JSON.stringify({ token })}`);
      } else if (packet.startsWith('40')) {
        socket.send(
          `421${JSON.stringify(['voice:join', { channelId }])}`,
        );
      } else if (packet.startsWith('431')) {
        clearTimeout(timer);
        socket.close();
        try {
          const [result] = JSON.parse(packet.slice(3));
          assert.equal(result.ok, false);
          assert.equal(result.error?.code, 'voice_channel_not_found');
          resolve();
        } catch (error) {
          reject(error);
        }
      }
    });
    socket.on('error', reject);
  });
}

async function connectRealtime(token) {
  const socket = new WebSocket(
    `ws://127.0.0.1:${port}/socket.io/?EIO=4&transport=websocket`,
  );
  const queuedEvents = new Map();
  const eventWaiters = new Map();
  const ackWaiters = new Map();
  let nextAckId = 1;
  let resolveConnected;
  let rejectConnected;
  const connected = new Promise((resolve, reject) => {
    resolveConnected = resolve;
    rejectConnected = reject;
  });

  function receiveEvent(name, payload) {
    const waiters = eventWaiters.get(name);
    if (waiters?.length) {
      waiters.shift()(payload);
      return;
    }
    const queued = queuedEvents.get(name) || [];
    queued.push(payload);
    queuedEvents.set(name, queued);
  }

  socket.on('message', (data) => {
    const packet = data.toString();
    if (packet === '2') {
      socket.send('3');
      return;
    }
    if (packet.startsWith('0')) {
      socket.send(`40${JSON.stringify({ token })}`);
      return;
    }
    if (packet.startsWith('40')) {
      resolveConnected();
      return;
    }
    if (packet.startsWith('44')) {
      rejectConnected(new Error(`Realtime authentication failed: ${packet}`));
      return;
    }
    const ackMatch = /^43(\d+)(.*)$/.exec(packet);
    if (ackMatch) {
      const waiter = ackWaiters.get(Number(ackMatch[1]));
      if (waiter) {
        ackWaiters.delete(Number(ackMatch[1]));
        const values = JSON.parse(ackMatch[2]);
        waiter(values[0]);
      }
      return;
    }
    if (packet.startsWith('42')) {
      const values = JSON.parse(packet.slice(2));
      receiveEvent(values[0], values[1]);
    }
  });
  socket.on('error', rejectConnected);
  await Promise.race([
    connected,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error('Realtime connection timed out.')), 2500),
    ),
  ]);

  return {
    socket,
    emitWithAck(event, payload) {
      const ackId = nextAckId;
      nextAckId += 1;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          ackWaiters.delete(ackId);
          reject(new Error(`Realtime ${event} acknowledgement timed out.`));
        }, 2500);
        ackWaiters.set(ackId, (value) => {
          clearTimeout(timer);
          resolve(value);
        });
        socket.send(`42${ackId}${JSON.stringify([event, payload])}`);
      });
    },
    nextEvent(event) {
      const queued = queuedEvents.get(event);
      if (queued?.length) {
        return Promise.resolve(queued.shift());
      }
      return new Promise((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error(`Realtime ${event} event timed out.`)),
          2500,
        );
        const waiters = eventWaiters.get(event) || [];
        waiters.push((payload) => {
          clearTimeout(timer);
          resolve(payload);
        });
        eventWaiters.set(event, waiters);
      });
    },
    close() {
      socket.close();
    },
  };
}

function encodeEnvelopeFields(values) {
  const result = [];
  for (const value of values) {
    const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value, 'utf8');
    const length = Buffer.allocUnsafe(4);
    length.writeUInt32BE(bytes.length);
    result.push(length, bytes);
  }
  return Buffer.concat(result);
}

function signEnvelope(envelope, secretKey) {
  const associatedData = encodeEnvelopeFields([
    envelope.protocol,
    envelope.serverId,
    envelope.channelId,
    String(envelope.epoch),
    envelope.senderDeviceId,
    envelope.recipientDeviceId,
    Buffer.from(envelope.ephemeralPublicKey, 'base64url'),
  ]);
  const signedPayload = encodeEnvelopeFields([
    associatedData,
    Buffer.from(envelope.nonce, 'base64url'),
    Buffer.from(envelope.ciphertext, 'base64url'),
    Buffer.from(envelope.authenticationTag, 'base64url'),
    String(envelope.messageSequence),
  ]);
  return Buffer.from(
    nacl.sign.detached(new Uint8Array(signedPayload), secretKey),
  ).toString('base64url');
}

async function run() {
  await waitForServer();

  const health = await (await request('/health')).json();
  assert.deepEqual(Object.keys(health).sort(), ['ok', 'time']);
  const publicServer = await (await request('/api/server')).json();
  assert.deepEqual(Object.keys(publicServer).sort(), ['ok', 'server']);
  const identityNonce = crypto.randomBytes(32).toString('base64url');
  const identityResponse = await request(
    `/api/server/identity?nonce=${identityNonce}`,
  );
  assert.equal(identityResponse.status, 200);
  const identity = (await identityResponse.json()).identity;
  assert.equal(identity.serverId, publicServer.server.id);
  assert.equal(identity.nonce, identityNonce);
  assert.equal(identity.algorithm, 'Ed25519');
  const identityPublicKey = crypto.createPublicKey({
    key: {
      kty: 'OKP',
      crv: 'Ed25519',
      x: identity.publicKey,
    },
    format: 'jwk',
  });
  assert.equal(
    crypto.verify(
      null,
      Buffer.from(
        `yappa-server-proof-v1|${identity.serverId}|${identityNonce}`,
        'utf8',
      ),
      identityPublicKey,
      Buffer.from(identity.signature, 'base64url'),
    ),
    true,
  );
  await expectStatus('/api/server/identity?nonce=too-short', 400);

  const owner = await createAccount('ownerauth');
  const member = await createAccount('memberauth');
  const revocationTarget = await createAccount('deviceauth');
  const textChannel = owner.channels.find((channel) => channel.type === 'text');
  const voiceChannel = owner.channels.find((channel) => channel.type === 'voice');
  const secondVoiceChannel = owner.channels.find(
    (channel) => channel.type === 'voice' && channel.id !== voiceChannel?.id,
  );
  assert.ok(textChannel);
  assert.ok(voiceChannel);
  assert.ok(secondVoiceChannel);

  function buildHistoryRecoveryKey(account, publicKeyBytes = crypto.randomBytes(32)) {
    const publicKey = publicKeyBytes.toString('base64url');
    const binding = Buffer.from(
      `yappa-history-recovery-device-v1|${owner.server.id}|` +
        `${account.user.yuid}|${account.mediaDeviceId}|${publicKey}`,
      'utf8',
    );
    return {
      publicKey,
      yuidAuthorizationSignature: Buffer.from(
        nacl.sign.detached(
          new Uint8Array(binding),
          account.yuidKeyPair.secretKey,
        ),
      ).toString('base64url'),
    };
  }

  const ownerRecoveryKey = buildHistoryRecoveryKey(owner);
  const invalidRecoveryKeyResponse = await request(
    '/api/mls/history-recovery/keys',
    {
      method: 'POST',
      token: owner.token,
      body: {
        ...ownerRecoveryKey,
        yuidAuthorizationSignature: Buffer.alloc(64, 0x33).toString(
          'base64url',
        ),
      },
    },
  );
  assert.equal(invalidRecoveryKeyResponse.status, 401);
  const recoveryKeyResponse = await request(
    '/api/mls/history-recovery/keys',
    {
      method: 'POST',
      token: owner.token,
      body: ownerRecoveryKey,
    },
  );
  assert.equal(recoveryKeyResponse.status, 201);
  const recoveryKey = await recoveryKeyResponse.json();
  assert.equal(recoveryKey.created, true);
  assert.equal(recoveryKey.key.deviceId, owner.mediaDeviceId);
  assert.equal(recoveryKey.key.publicKey, ownerRecoveryKey.publicKey);
  const recoveryKeyRetry = await request(
    '/api/mls/history-recovery/keys',
    {
      method: 'POST',
      token: owner.token,
      body: ownerRecoveryKey,
    },
  );
  assert.equal(recoveryKeyRetry.status, 200);
  assert.equal((await recoveryKeyRetry.json()).created, false);
  const recoveryKeyConflict = await request(
    '/api/mls/history-recovery/keys',
    {
      method: 'POST',
      token: owner.token,
      body: buildHistoryRecoveryKey(owner),
    },
  );
  assert.equal(recoveryKeyConflict.status, 409);
  const ownerRecoveryDirectory = await (
    await request('/api/mls/history-recovery/keys', {token: owner.token})
  ).json();
  assert.equal(ownerRecoveryDirectory.accountYuid, owner.user.yuid);
  assert.deepEqual(
    ownerRecoveryDirectory.keys.map((key) => key.deviceId),
    [owner.mediaDeviceId],
  );
  const memberRecoveryDirectory = await (
    await request('/api/mls/history-recovery/keys', {token: member.token})
  ).json();
  assert.equal(memberRecoveryDirectory.accountYuid, member.user.yuid);
  assert.deepEqual(memberRecoveryDirectory.keys, []);

  for (const privateTarget of [
    `http://127.0.0.1:${port}/health`,
    `http://localhost:${port}/health`,
    'http://[::1]/health',
    'http://169.254.169.254/latest/meta-data/',
  ]) {
    await expectStatus(
      `/api/link-preview?channelId=${textChannel.id}&url=${encodeURIComponent(privateTarget)}`,
      502,
      { token: owner.token },
    );
  }

  function buildKeyPackage(account, fillByte) {
    const signaturePublicKey = crypto.randomBytes(32).toString('base64url');
    const bindingMessage = Buffer.from(
      `yappa-mls-credential-v1|${owner.server.id}|${account.user.yuid}|` +
        `${account.mediaDeviceId}|${signaturePublicKey}`,
      'utf8',
    );
    return {
      ciphersuite: 1,
      signaturePublicKey,
      identityBindingSignature: Buffer.from(
        nacl.sign.detached(
          new Uint8Array(bindingMessage),
          account.yuidKeyPair.secretKey,
        ),
      ).toString('base64url'),
      keyPackage: Buffer.alloc(128, fillByte).toString('base64url'),
      expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
    };
  }

  const memberKeyPackage = buildKeyPackage(member, 0x41);
  const tamperedPackageResponse = await request('/api/mls/key-packages', {
    method: 'POST',
    token: member.token,
    body: {
      packages: [
        {
          ...memberKeyPackage,
          identityBindingSignature: Buffer.alloc(64, 0x7f).toString(
            'base64url',
          ),
        },
      ],
    },
  });
  assert.equal(tamperedPackageResponse.status, 401);
  const packageRegistration = await request('/api/mls/key-packages', {
    method: 'POST',
    token: member.token,
    body: { packages: [memberKeyPackage] },
  });
  assert.equal(packageRegistration.status, 201);
  const duplicateRegistration = await request('/api/mls/key-packages', {
    method: 'POST',
    token: member.token,
    body: { packages: [memberKeyPackage] },
  });
  assert.equal(duplicateRegistration.status, 409);
  assert.equal(
    (await duplicateRegistration.json()).error?.code,
    'duplicate_mls_key_package',
  );
  const inventory = await (
    await request('/api/mls/key-packages', { token: member.token })
  ).json();
  assert.equal(inventory.available, 1);
  const claimedPackageResponse = await request(
    '/api/mls/key-packages/claim',
    {
      method: 'POST',
      token: owner.token,
      body: { deviceId: member.mediaDeviceId },
    },
  );
  assert.equal(claimedPackageResponse.status, 200);
  const claimedPackage = (await claimedPackageResponse.json()).keyPackage;
  assert.equal(claimedPackage.deviceId, member.mediaDeviceId);
  assert.equal(claimedPackage.keyPackage, memberKeyPackage.keyPackage);
  assert.equal(
    claimedPackage.signaturePublicKey,
    memberKeyPackage.signaturePublicKey,
  );
  assert.equal(claimedPackage.yuid, member.user.yuid);
  const claimedPackageDb = new Database(dbPath);
  const compactedClaim = claimedPackageDb
    .prepare(`
      SELECT length(key_package) AS stored_bytes, key_package_hash
      FROM mls_key_packages
      WHERE id = ?
    `)
    .get(claimedPackage.id);
  claimedPackageDb.close();
  assert.equal(compactedClaim.stored_bytes, 0);
  assert.equal(compactedClaim.key_package_hash, claimedPackage.keyPackageHash);
  assert.equal(
    (
      await request('/api/mls/key-packages/claim', {
        method: 'POST',
        token: owner.token,
        body: { deviceId: member.mediaDeviceId },
      })
    ).status,
    404,
  );
  const ownerKeyPackage = buildKeyPackage(owner, 0x42);
  assert.equal(
    (
      await request('/api/mls/key-packages', {
        method: 'POST',
        token: owner.token,
        body: { packages: [ownerKeyPackage] },
      })
    ).status,
    201,
  );
  const credentialDirectory = await (
    await request('/api/mls/device-credentials', { token: owner.token })
  ).json();
  const memberCredential = credentialDirectory.credentials.find(
    (credential) => credential.deviceId === member.mediaDeviceId,
  );
  assert.ok(memberCredential);
  assert.equal(
    memberCredential.signaturePublicKey,
    memberKeyPackage.signaturePublicKey,
  );
  assert.equal(
    memberCredential.identityBindingSignature,
    memberKeyPackage.identityBindingSignature,
  );
  assert.equal(memberCredential.yuid, member.user.yuid);
  assert.equal(memberCredential.userId, member.user.id);
  assert.equal(memberCredential.isServerOwner, false);
  assert.equal(memberCredential.isActive, true);
  const ownerCredential = credentialDirectory.credentials.find(
    (credential) => credential.deviceId === owner.mediaDeviceId,
  );
  assert.ok(ownerCredential);
  assert.equal(ownerCredential.isServerOwner, true);
  assert.equal(ownerCredential.isActive, true);

  const revocationPackage = buildKeyPackage(revocationTarget, 0x43);
  assert.equal(
    (
      await request('/api/mls/key-packages', {
        method: 'POST',
        token: revocationTarget.token,
        body: { packages: [revocationPackage] },
      })
    ).status,
    201,
  );

  for (const route of [
    '/api/channels',
    '/api/members',
    '/api/presence',
    '/api/server/settings',
    '/api/media/devices',
    '/api/mls/device-credentials',
    `/api/channels/${textChannel.id}/messages`,
  ]) {
    await expectStatus(route, 401);
  }
  await expectStatus('/api/voice/token', 401, {
    method: 'POST',
    body: { channelId: voiceChannel.id },
  });

  for (const [route, options] of [
    ['/api/server/settings'],
    ['/api/server/storage'],
    ['/api/admin/bans'],
    ['/api/admin/server', { method: 'PATCH', body: {} }],
    ['/api/admin/channels', {
      method: 'POST',
      body: { name: 'forbidden', type: 'text' },
    }],
    ['/api/admin/bans', {
      method: 'POST',
      body: { userId: owner.user.id },
    }],
  ]) {
    await expectStatus(route, 403, { token: member.token, ...options });
  }

  const settingsResponse = await request('/api/server/settings', {
    token: owner.token,
  });
  assert.equal(settingsResponse.status, 200);
  assert.equal(
    (await settingsResponse.json()).settings.attachmentRetentionDays,
    0,
  );
  const expiringRetentionResponse = await request('/api/server/settings', {
    method: 'PATCH',
    token: owner.token,
    body: { attachmentRetentionDays: 30 },
  });
  assert.equal(expiringRetentionResponse.status, 400);
  assert.equal(
    (await expiringRetentionResponse.json()).error?.code,
    'invalid_attachment_retention_days',
  );
  const storageResponse = await request('/api/server/storage', {
    token: owner.token,
  });
  assert.equal(storageResponse.status, 200);
  const storage = (await storageResponse.json()).storage;
  assert.equal(storage.available, true);
  assert.equal(storage.acceptsDurableWrites, true);
  assert.equal(
    storage.thresholds.warningFreeBytes >
      storage.thresholds.criticalFreeBytes,
    true,
  );
  assert.equal(Number.isSafeInteger(storage.filesystem.availableBytes), true);
  assert.equal(Number.isSafeInteger(storage.usage.databaseBytes), true);
  assert.equal(
    Number.isSafeInteger(storage.usage.ordinaryAttachmentBytes),
    true,
  );
  assert.equal(
    Number.isSafeInteger(storage.usage.encryptedAttachmentBytes),
    true,
  );

  const encryptedChannelCreateResponse = await request(
    '/api/admin/channels',
    {
      method: 'POST',
      token: owner.token,
      body: { name: 'encrypted-default', type: 'text' },
    },
  );
  assert.equal(encryptedChannelCreateResponse.status, 201);
  const encryptedChannelCreateBody =
    await encryptedChannelCreateResponse.json();
  assert.equal(encryptedChannelCreateBody.channel.encryptionMode, 'e2ee');
  assert.equal(encryptedChannelCreateBody.channel.encryptionVersion, 1);
  const encryptedChannelId = encryptedChannelCreateBody.channel.id;
  const plaintextIntoEncryptedChannel = await request(
    `/api/channels/${encryptedChannelId}/messages`,
    {
      method: 'POST',
      token: owner.token,
      body: { content: 'plaintext must never enter an encrypted feed' },
    },
  );
  assert.equal(plaintextIntoEncryptedChannel.status, 409);
  assert.equal(
    (await plaintextIntoEncryptedChannel.json()).error?.code,
    'encrypted_channel_requires_e2ee',
  );
  const downgradeEncryptedChannel = await request(
    `/api/admin/channels/${encryptedChannelId}`,
    {
      method: 'PATCH',
      token: owner.token,
      body: {
        encryptionMode: 'legacy',
        encryptionVersion: 0,
      },
    },
  );
  assert.equal(downgradeEncryptedChannel.status, 409);
  assert.equal(
    (await downgradeEncryptedChannel.json()).error?.code,
    'channel_encryption_immutable',
  );

  const ownerSessions = await (
    await request('/api/auth/sessions', { token: owner.token })
  ).json();
  await expectStatus(
    `/api/auth/sessions/${ownerSessions.sessions[0].id}`,
    404,
    { method: 'DELETE', token: member.token },
  );
  await expectStatus('/api/auth/me', 200, { token: owner.token });

  const voiceTokenResponse = await request('/api/voice/token', {
    method: 'POST',
    token: owner.token,
    body: { channelId: voiceChannel.id },
  });
  assert.equal(voiceTokenResponse.status, 200);
  const voiceTokenBody = await voiceTokenResponse.json();
  const voiceJwtPayload = JSON.parse(
    Buffer.from(
      voiceTokenBody.token.split('.')[1],
      'base64url',
    ).toString('utf8'),
  );
  assert.equal(voiceJwtPayload.sub, owner.mediaDeviceId);
  const participantMetadata = JSON.parse(voiceJwtPayload.metadata);
  assert.equal(participantMetadata.userId, owner.user.id);
  assert.equal(participantMetadata.deviceId, owner.mediaDeviceId);
  assert.equal(participantMetadata.channelId, voiceChannel.id);

  const ownerRealtime = await connectRealtime(owner.token);
  const memberRealtime = await connectRealtime(member.token);
  const targetRealtime = await connectRealtime(revocationTarget.token);
  const ownerJoin = await ownerRealtime.emitWithAck('voice:join', {
    channelId: voiceChannel.id,
  });
  assert.equal(ownerJoin.ok, true);
  const firstRoomState = await ownerRealtime.nextEvent('media:e2ee:state');
  assert.equal(firstRoomState.epoch, 1);
  assert.deepEqual(
    firstRoomState.devices.map((device) => device.id),
    [owner.mediaDeviceId],
  );

  const memberJoin = await memberRealtime.emitWithAck('voice:join', {
    channelId: voiceChannel.id,
  });
  assert.equal(memberJoin.ok, true);
  const ownerSharedState = await ownerRealtime.nextEvent('media:e2ee:state');
  const memberSharedState = await memberRealtime.nextEvent('media:e2ee:state');
  const sortedRoomDevices = [
    owner.mediaDeviceId,
    member.mediaDeviceId,
  ].sort();
  const sharedEpoch =
    sortedRoomDevices[0] === owner.mediaDeviceId ? 1 : 2;
  assert.equal(ownerSharedState.epoch, sharedEpoch);
  assert.deepEqual(
    ownerSharedState.devices.map((device) => device.id),
    sortedRoomDevices,
  );
  assert.equal(ownerSharedState.leaderDeviceId, sortedRoomDevices[0]);
  assert.deepEqual(memberSharedState, ownerSharedState);
  const leaderAccount =
    ownerSharedState.leaderDeviceId === owner.mediaDeviceId ? owner : member;
  const recipientAccount = leaderAccount === owner ? member : owner;
  const leaderRealtime =
    leaderAccount === owner ? ownerRealtime : memberRealtime;
  const recipientRealtime =
    recipientAccount === owner ? ownerRealtime : memberRealtime;

  const targetJoin = await targetRealtime.emitWithAck('voice:join', {
    channelId: secondVoiceChannel.id,
  });
  assert.equal(targetJoin.ok, true);
  await targetRealtime.nextEvent('media:e2ee:state');

  const envelope = {
    protocol: 'yappa-media-envelope-v1',
    serverId: publicServer.server.id,
    channelId: voiceChannel.id,
    epoch: ownerSharedState.epoch,
    messageSequence: 1,
    senderDeviceId: leaderAccount.mediaDeviceId,
    recipientDeviceId: recipientAccount.mediaDeviceId,
    ephemeralPublicKey: crypto.randomBytes(32).toString('base64url'),
    nonce: crypto.randomBytes(12).toString('base64url'),
    ciphertext: crypto.randomBytes(44).toString('base64url'),
    authenticationTag: crypto.randomBytes(16).toString('base64url'),
    signature: '',
  };
  envelope.signature = signEnvelope(envelope, leaderAccount.yuidKeyPair.secretKey);
  const envelopeAck = await leaderRealtime.emitWithAck(
    'media:e2ee:envelope',
    { envelope },
  );
  assert.equal(envelopeAck.ok, true);
  assert.deepEqual(
    (await recipientRealtime.nextEvent('media:e2ee:envelope')).envelope,
    envelope,
  );
  const replayAck = await leaderRealtime.emitWithAck(
    'media:e2ee:envelope',
    { envelope },
  );
  assert.equal(replayAck.ok, false);
  assert.equal(replayAck.error.code, 'replayed_media_envelope');

  const tamperedEnvelope = {
    ...envelope,
    messageSequence: 2,
    ciphertext:
      `${envelope.ciphertext.slice(0, -1)}` +
      `${envelope.ciphertext.endsWith('A') ? 'B' : 'A'}`,
  };
  const tamperedEnvelopeAck = await leaderRealtime.emitWithAck(
    'media:e2ee:envelope',
    { envelope: tamperedEnvelope },
  );
  assert.equal(tamperedEnvelopeAck.ok, false);
  assert.equal(
    tamperedEnvelopeAck.error.code,
    'invalid_media_envelope_signature',
  );

  const crossRoomEnvelope = {
    ...envelope,
    messageSequence: 2,
    recipientDeviceId: revocationTarget.mediaDeviceId,
    signature: '',
  };
  crossRoomEnvelope.signature = signEnvelope(
    crossRoomEnvelope,
    leaderAccount.yuidKeyPair.secretKey,
  );
  const crossRoomAck = await leaderRealtime.emitWithAck(
    'media:e2ee:envelope',
    {
      envelope: crossRoomEnvelope,
    },
  );
  assert.equal(crossRoomAck.ok, false);
  assert.equal(
    crossRoomAck.error.code,
    'media_envelope_recipient_forbidden',
  );

  const mediaDevicesResponse = await request('/api/media/devices', {
    token: owner.token,
  });
  assert.equal(mediaDevicesResponse.status, 200);
  const mediaDevices = (await mediaDevicesResponse.json()).devices;
  assert.equal(mediaDevices.length, 3);
  const ownerMediaDevice = mediaDevices.find(
    (device) => device.id === owner.mediaDeviceId,
  );
  assert.ok(ownerMediaDevice);
  assert.equal(ownerMediaDevice.userId, owner.user.id);
  assert.equal(ownerMediaDevice.publicKey, owner.mediaPublicKey);
  assert.equal(ownerMediaDevice.username, owner.user.username);
  assert.equal(typeof ownerMediaDevice.yuidAuthorizationSignature, 'string');
  assert.equal(typeof ownerMediaDevice.authorizationNonce, 'string');
  assert.equal('privateKey' in ownerMediaDevice, false);
  assert.equal('passwordHash' in ownerMediaDevice, false);

  const ownerRecoveryDestination = await createAdditionalDevice(owner);
  const destinationRecoveryKey = buildHistoryRecoveryKey(
    ownerRecoveryDestination,
  );
  assert.equal(
    (
      await request('/api/mls/history-recovery/keys', {
        method: 'POST',
        token: ownerRecoveryDestination.token,
        body: destinationRecoveryKey,
      })
    ).status,
    201,
  );
  const recoveryTransferId = `recovery_${crypto
    .randomBytes(16)
    .toString('base64url')}`;
  const transferChunks = [
    Buffer.from('opaque encrypted history chunk zero'),
    Buffer.from('opaque encrypted history chunk one'),
  ];
  const transferManifest = Buffer.from(
    JSON.stringify({
      protocol: 'yappa-history-recovery-v1',
      transferId: recoveryTransferId,
      serverId: owner.server.id,
      channelId: encryptedChannelId,
      accountYuid: owner.user.yuid,
      sourceDeviceId: owner.mediaDeviceId,
      destinationDeviceId: ownerRecoveryDestination.mediaDeviceId,
      firstServerSequence: 1,
      lastServerSequence: 2,
      eventCount: 1,
      chunkCount: transferChunks.length,
      totalBytes: transferChunks.reduce(
        (total, chunk) => total + chunk.length,
        0,
      ),
    }),
  );
  const transferManifestHash = crypto
    .createHash('sha256')
    .update(transferManifest)
    .digest('hex');
  const transferSignature = Buffer.from(
    nacl.sign.detached(
      new Uint8Array(Buffer.from(transferManifestHash, 'hex')),
      owner.yuidKeyPair.secretKey,
    ),
  ).toString('base64url');
  const transferCreateBody = {
    id: recoveryTransferId,
    destinationDeviceId: ownerRecoveryDestination.mediaDeviceId,
    firstServerSequence: 1,
    lastServerSequence: 2,
    eventCount: 1,
    chunkCount: transferChunks.length,
    totalBytes: transferChunks.reduce(
      (total, chunk) => total + chunk.length,
      0,
    ),
    manifest: transferManifest.toString('base64url'),
    manifestSha256: transferManifestHash,
    yuidSignature: transferSignature,
  };
  const transferCreateResponse = await request(
    `/api/channels/${encryptedChannelId}/mls/history-recovery/transfers`,
    {
      method: 'POST',
      token: owner.token,
      body: transferCreateBody,
    },
  );
  assert.equal(transferCreateResponse.status, 201);
  const createdTransfer = await transferCreateResponse.json();
  assert.equal(createdTransfer.created, true);
  assert.equal(createdTransfer.transfer.state, 'uploading');
  assert.equal(createdTransfer.transfer.uploadedChunks, 0);
  const transferRetry = await request(
    `/api/channels/${encryptedChannelId}/mls/history-recovery/transfers`,
    {
      method: 'POST',
      token: owner.token,
      body: transferCreateBody,
    },
  );
  assert.equal(transferRetry.status, 200);
  assert.equal((await transferRetry.json()).created, false);
  const conflictingTransfer = await request(
    `/api/channels/${encryptedChannelId}/mls/history-recovery/transfers`,
    {
      method: 'POST',
      token: owner.token,
      body: {...transferCreateBody, totalBytes: transferCreateBody.totalBytes + 1},
    },
  );
  assert.equal(conflictingTransfer.status, 409);
  await expectStatus(
    `/api/mls/history-recovery/transfers/${recoveryTransferId}/finalize`,
    409,
    {method: 'POST', token: owner.token},
  );
  await expectStatus(
    `/api/mls/history-recovery/transfers/${recoveryTransferId}/chunks/0`,
    404,
    {token: ownerRecoveryDestination.token},
  );
  for (let index = 0; index < transferChunks.length; index += 1) {
    const chunk = transferChunks[index];
    const chunkHash = crypto.createHash('sha256').update(chunk).digest('hex');
    const uploaded = await requestBytes(
      `/api/mls/history-recovery/transfers/${recoveryTransferId}/chunks/${index}`,
      {token: owner.token, bytes: chunk, digest: chunkHash},
    );
    assert.equal(uploaded.status, 201);
    const retried = await requestBytes(
      `/api/mls/history-recovery/transfers/${recoveryTransferId}/chunks/${index}`,
      {token: owner.token, bytes: chunk, digest: chunkHash},
    );
    assert.equal(retried.status, 200);
  }
  const conflictingChunk = Buffer.from('different encrypted chunk');
  assert.equal(
    (
      await requestBytes(
        `/api/mls/history-recovery/transfers/${recoveryTransferId}/chunks/0`,
        {
          token: owner.token,
          bytes: conflictingChunk,
          digest: crypto
            .createHash('sha256')
            .update(conflictingChunk)
            .digest('hex'),
        },
      )
    ).status,
    409,
  );
  const finalizedTransferResponse = await request(
    `/api/mls/history-recovery/transfers/${recoveryTransferId}/finalize`,
    {method: 'POST', token: owner.token},
  );
  assert.equal(finalizedTransferResponse.status, 200);
  assert.equal((await finalizedTransferResponse.json()).finalized, true);
  await expectStatus(
    `/api/mls/history-recovery/transfers/${recoveryTransferId}/chunks/0`,
    404,
    {token: member.token},
  );
  const destinationTransfers = await (
    await request(
      `/api/channels/${encryptedChannelId}/mls/history-recovery/transfers`,
      {token: ownerRecoveryDestination.token},
    )
  ).json();
  assert.equal(destinationTransfers.transfers.length, 1);
  assert.equal(destinationTransfers.transfers[0].id, recoveryTransferId);
  for (let index = 0; index < transferChunks.length; index += 1) {
    const response = await request(
      `/api/mls/history-recovery/transfers/${recoveryTransferId}/chunks/${index}`,
      {token: ownerRecoveryDestination.token},
    );
    assert.equal(response.status, 200);
    const downloaded = await response.json();
    assert.deepEqual(
      Buffer.from(downloaded.ciphertext, 'base64url'),
      transferChunks[index],
    );
  }
  const consumedTransferResponse = await request(
    `/api/mls/history-recovery/transfers/${recoveryTransferId}/consume`,
    {method: 'POST', token: ownerRecoveryDestination.token},
  );
  assert.equal(consumedTransferResponse.status, 200);
  assert.equal((await consumedTransferResponse.json()).consumed, true);
  await expectStatus(
    `/api/mls/history-recovery/transfers/${recoveryTransferId}/chunks/0`,
    404,
    {token: ownerRecoveryDestination.token},
  );

  const legacyToken = crypto.randomBytes(32).toString('hex');
  const legacyNow = new Date();
  const legacyDb = new Database(dbPath);
  legacyDb.prepare(`
    INSERT INTO sessions (
      token, user_id, created_at, last_seen_at, expires_at, idle_expires_at,
      device_name, media_device_id
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
  `).run(
    legacyToken,
    owner.user.id,
    legacyNow.toISOString(),
    legacyNow.toISOString(),
    new Date(legacyNow.getTime() + 86400000).toISOString(),
    new Date(legacyNow.getTime() + 3600000).toISOString(),
    'Legacy client migration test',
  );
  legacyDb.close();
  await expectStatus('/api/auth/me', 200, { token: legacyToken });

  const migrationChallengeResponse = await request(
    '/api/auth/yuid/challenge',
  );
  assert.equal(migrationChallengeResponse.status, 200);
  const migrationChallenge = (await migrationChallengeResponse.json())
    .challenge;
  const migrationMediaKeyPair = crypto.generateKeyPairSync('x25519');
  const migrationMediaPublicKey = migrationMediaKeyPair.publicKey.export({
    format: 'jwk',
  }).x;
  const migrationMediaDeviceId = `device_${crypto
    .randomBytes(18)
    .toString('base64url')}`;
  const migrationYuidSignature = nacl.sign.detached(
    new Uint8Array(
      Buffer.from(
        `yappa-auth-v1|${migrationChallenge.serverId}|ownerauth|` +
          migrationChallenge.nonce,
        'utf8',
      ),
    ),
    owner.yuidKeyPair.secretKey,
  );
  const migrationMediaSignature = nacl.sign.detached(
    new Uint8Array(
      Buffer.from(
        `yappa-media-device-v1|${migrationChallenge.serverId}|ownerauth|` +
          `${migrationChallenge.nonce}|${migrationMediaPublicKey}|` +
          migrationMediaDeviceId,
        'utf8',
      ),
    ),
    owner.yuidKeyPair.secretKey,
  );
  const migrationResponse = await request('/api/media/devices/register', {
    method: 'POST',
    token: legacyToken,
    body: {
      yuidPublicKey: Buffer.from(
        owner.yuidKeyPair.publicKey,
      ).toString('base64url'),
      yuidSignature: Buffer.from(
        migrationYuidSignature,
      ).toString('base64url'),
      yuidNonce: migrationChallenge.nonce,
      mediaDeviceId: migrationMediaDeviceId,
      mediaPublicKey: migrationMediaPublicKey,
      mediaDeviceSignature: Buffer.from(
        migrationMediaSignature,
      ).toString('base64url'),
    },
  });
  assert.equal(migrationResponse.status, 200);
  const migratedSession = await (
    await request('/api/auth/me', { token: legacyToken })
  ).json();
  assert.equal(migratedSession.mediaDevice.id, migrationMediaDeviceId);

  await expectStatus(
    `/api/media/devices/${owner.mediaDeviceId}`,
    403,
    { method: 'DELETE', token: member.token },
  );

  const tamperedChallengeResponse = await request('/api/auth/yuid/challenge');
  assert.equal(tamperedChallengeResponse.status, 200);
  const tamperedChallenge = (await tamperedChallengeResponse.json()).challenge;
  const tamperedYuidMessage = Buffer.from(
    `yappa-auth-v1|${tamperedChallenge.serverId}|ownerauth|` +
      tamperedChallenge.nonce,
    'utf8',
  );
  const tamperedYuidSignature = nacl.sign.detached(
    new Uint8Array(tamperedYuidMessage),
    owner.yuidKeyPair.secretKey,
  );
  const replacementMediaKeyPair = crypto.generateKeyPairSync('x25519');
  const replacementMediaPublicKey = replacementMediaKeyPair.publicKey.export({
    format: 'jwk',
  }).x;
  const replacementMediaDeviceId = `device_${crypto
    .randomBytes(18)
    .toString('base64url')}`;
  const validMediaAuthorization = nacl.sign.detached(
    new Uint8Array(
      Buffer.from(
        `yappa-media-device-v1|${tamperedChallenge.serverId}|ownerauth|` +
          `${tamperedChallenge.nonce}|${replacementMediaPublicKey}|` +
          replacementMediaDeviceId,
        'utf8',
      ),
    ),
    owner.yuidKeyPair.secretKey,
  );
  validMediaAuthorization[0] ^= 1;
  await expectStatus('/api/auth/session', 401, {
    method: 'POST',
    body: {
      username: 'ownerauth',
      password: 'authorization-test-password',
      yuidPublicKey: Buffer.from(
        owner.yuidKeyPair.publicKey,
      ).toString('base64url'),
      yuidSignature: Buffer.from(tamperedYuidSignature).toString('base64url'),
      yuidNonce: tamperedChallenge.nonce,
      mediaDeviceId: replacementMediaDeviceId,
      mediaPublicKey: replacementMediaPublicKey,
      mediaDeviceSignature: Buffer.from(
        validMediaAuthorization,
      ).toString('base64url'),
    },
  });

  const targetDisconnected = new Promise((resolve) => {
    targetRealtime.socket.once('close', resolve);
  });
  const revokeMediaResponse = await request(
    `/api/media/devices/${revocationTarget.mediaDeviceId}`,
    { method: 'DELETE', token: owner.token },
  );
  assert.equal(revokeMediaResponse.status, 200);
  await Promise.race([
    targetDisconnected,
    new Promise((_, reject) =>
      setTimeout(
        () => reject(new Error('Revoked media device socket stayed connected.')),
        2500,
      ),
    ),
  ]);
  await expectStatus('/api/auth/me', 401, {
    token: revocationTarget.token,
  });
  const afterRevocation = await (
    await request('/api/media/devices', { token: owner.token })
  ).json();
  assert.equal(
    afterRevocation.devices.some(
      (device) => device.id === revocationTarget.mediaDeviceId,
    ),
    false,
  );
  const afterCredentialRevocation = await (
    await request('/api/mls/device-credentials', { token: owner.token })
  ).json();
  const historicalRevokedCredential =
    afterCredentialRevocation.credentials.find(
      (credential) =>
        credential.deviceId === revocationTarget.mediaDeviceId,
    );
  assert.ok(historicalRevokedCredential);
  assert.equal(historicalRevokedCredential.isActive, false);
  const revokedPackageClaim = await request(
    '/api/mls/key-packages/claim',
    {
      method: 'POST',
      token: owner.token,
      body: { deviceId: revocationTarget.mediaDeviceId },
    },
  );
  assert.equal(revokedPackageClaim.status, 404);

  const messageResponse = await request(
    `/api/channels/${textChannel.id}/messages`,
    {
      method: 'POST',
      token: owner.token,
      body: { content: 'authorization boundary test' },
    },
  );
  assert.equal(messageResponse.status, 201);
  const message = (await messageResponse.json()).message;
  await expectStatus(
    `/api/channels/${textChannel.id}/messages/${message.id}`,
    403,
    {
      method: 'PATCH',
      token: member.token,
      body: { content: 'forbidden edit' },
    },
  );
  await expectStatus(
    `/api/channels/${textChannel.id}/messages/${message.id}`,
    403,
    { method: 'DELETE', token: member.token },
  );
  await expectStatus(`/api/channels/${textChannel.id}/messages`, 200, {
    token: member.token,
  });

  const historyMessageIds = [message.id];
  for (let index = 1; index <= 4; index += 1) {
    const response = await request(
      `/api/channels/${textChannel.id}/messages`,
      {
        method: 'POST',
        token: owner.token,
        body: { content: `durable history page ${index}` },
      },
    );
    assert.equal(response.status, 201);
    historyMessageIds.push((await response.json()).message.id);
  }

  const newestHistoryResponse = await request(
    `/api/channels/${textChannel.id}/messages?limit=2`,
    { token: owner.token },
  );
  assert.equal(newestHistoryResponse.status, 200);
  const newestHistory = await newestHistoryResponse.json();
  assert.deepEqual(
    newestHistory.messages.map((item) => item.id),
    historyMessageIds.slice(-2),
  );
  assert.equal(newestHistory.page.hasMore, true);
  assert.equal(newestHistory.page.direction, 'before');
  assert.match(newestHistory.page.nextCursor, /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
  assert.match(
    newestHistory.page.forwardCursor,
    /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/,
  );
  assert.match(
    newestHistory.page.backwardCursor,
    /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/,
  );

  const olderHistoryResponse = await request(
    `/api/channels/${textChannel.id}/messages?limit=2&cursor=${encodeURIComponent(
      newestHistory.page.nextCursor,
    )}`,
    { token: owner.token },
  );
  assert.equal(olderHistoryResponse.status, 200);
  const olderHistory = await olderHistoryResponse.json();
  assert.deepEqual(
    olderHistory.messages.map((item) => item.id),
    historyMessageIds.slice(1, 3),
  );
  assert.equal(olderHistory.page.hasMore, true);
  assert.equal(
    olderHistory.messages.some((item) =>
      newestHistory.messages.some((newest) => newest.id === item.id)),
    false,
  );

  const anchoredCursorResponse = await request(
    `/api/channels/${textChannel.id}/messages/cursor?messageId=${
      olderHistory.messages.at(-1).id
    }&direction=after`,
    { token: owner.token },
  );
  assert.equal(anchoredCursorResponse.status, 200);
  const anchoredCursor = await anchoredCursorResponse.json();
  assert.equal(anchoredCursor.direction, 'after');
  assert.equal(anchoredCursor.messageId, olderHistory.messages.at(-1).id);
  assert.match(anchoredCursor.cursor, /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
  const anchoredHistoryResponse = await request(
    `/api/channels/${textChannel.id}/messages?limit=2&cursor=${encodeURIComponent(
      anchoredCursor.cursor,
    )}`,
    { token: owner.token },
  );
  assert.equal(anchoredHistoryResponse.status, 200);
  assert.deepEqual(
    (await anchoredHistoryResponse.json()).messages.map((item) => item.id),
    historyMessageIds.slice(3, 5),
  );
  await expectStatus(
    `/api/channels/${textChannel.id}/messages/cursor?messageId=999999999&direction=before`,
    404,
    { token: owner.token },
  );
  await expectStatus(
    `/api/channels/${textChannel.id}/messages/cursor?messageId=${
      olderHistory.messages.at(-1).id
    }&direction=sideways`,
    400,
    { token: owner.token },
  );

  const substitutedCursorResponse = await request(
    `/api/channels/${textChannel.id}/messages?cursor=${encodeURIComponent(
      newestHistory.page.nextCursor,
    )}`,
    { token: member.token },
  );
  assert.equal(substitutedCursorResponse.status, 400);
  assert.equal(
    (await substitutedCursorResponse.json()).error?.code,
    'invalid_history_cursor',
  );
  const tamperedCursor =
    `${newestHistory.page.nextCursor.slice(0, -1)}` +
    `${newestHistory.page.nextCursor.endsWith('A') ? 'B' : 'A'}`;
  const tamperedCursorResponse = await request(
    `/api/channels/${textChannel.id}/messages?cursor=${encodeURIComponent(
      tamperedCursor,
    )}`,
    { token: owner.token },
  );
  assert.equal(tamperedCursorResponse.status, 400);
  assert.equal(
    (await tamperedCursorResponse.json()).error?.code,
    'invalid_history_cursor',
  );
  await expectStatus(
    `/api/channels/${textChannel.id}/messages?limit=101`,
    400,
    { token: owner.token },
  );

  const missedMessageIds = [];
  for (let index = 1; index <= 3; index += 1) {
    const response = await request(
      `/api/channels/${textChannel.id}/messages`,
      {
        method: 'POST',
        token: owner.token,
        body: { content: `offline catch-up ${index}` },
      },
    );
    assert.equal(response.status, 201);
    missedMessageIds.push((await response.json()).message.id);
  }
  const firstCatchUpResponse = await request(
    `/api/channels/${textChannel.id}/messages?limit=2&cursor=${encodeURIComponent(
      newestHistory.page.forwardCursor,
    )}`,
    { token: owner.token },
  );
  assert.equal(firstCatchUpResponse.status, 200);
  const firstCatchUp = await firstCatchUpResponse.json();
  assert.equal(firstCatchUp.page.direction, 'after');
  assert.equal(firstCatchUp.page.hasMore, true);
  assert.deepEqual(
    firstCatchUp.messages.map((item) => item.id),
    missedMessageIds.slice(0, 2),
  );
  const secondCatchUpResponse = await request(
    `/api/channels/${textChannel.id}/messages?limit=2&cursor=${encodeURIComponent(
      firstCatchUp.page.nextCursor,
    )}`,
    { token: owner.token },
  );
  assert.equal(secondCatchUpResponse.status, 200);
  const secondCatchUp = await secondCatchUpResponse.json();
  assert.equal(secondCatchUp.page.direction, 'after');
  assert.equal(secondCatchUp.page.hasMore, false);
  assert.equal(secondCatchUp.page.nextCursor, null);
  assert.deepEqual(
    secondCatchUp.messages.map((item) => item.id),
    missedMessageIds.slice(2),
  );
  assert.equal(
    firstCatchUp.messages.some((item) =>
      secondCatchUp.messages.some((next) => next.id === item.id)),
    false,
  );
  const emptyCatchUpResponse = await request(
    `/api/channels/${textChannel.id}/messages?cursor=${encodeURIComponent(
      secondCatchUp.page.forwardCursor,
    )}`,
    { token: owner.token },
  );
  const emptyCatchUp = await emptyCatchUpResponse.json();
  assert.equal(emptyCatchUpResponse.status, 200);
  assert.deepEqual(emptyCatchUp.messages, []);
  assert.equal(emptyCatchUp.page.direction, 'after');
  assert.equal(
    emptyCatchUp.page.forwardCursor,
    secondCatchUp.page.forwardCursor,
  );

  const encryptionDb = new Database(dbPath);
  encryptionDb
    .prepare(`
      UPDATE channels
      SET encryption_mode = 'e2ee', encryption_version = 1
      WHERE id = ?
    `)
    .run(textChannel.id);
  encryptionDb.close();
  const encryptedChannels = await (
    await request('/api/channels', { token: owner.token })
  ).json();
  const encryptedChannel = encryptedChannels.channels.find(
    (channel) => channel.id === textChannel.id,
  );
  assert.equal(encryptedChannel.encryptionMode, 'e2ee');
  assert.equal(encryptedChannel.encryptionVersion, 1);
  const plaintextHistoryRejected = await request(
    `/api/channels/${textChannel.id}/messages`,
    { token: owner.token },
  );
  assert.equal(plaintextHistoryRejected.status, 409);
  assert.equal(
    (await plaintextHistoryRejected.json()).error?.code,
    'encrypted_channel_requires_e2ee',
  );
  const plaintextRejected = await request(
    `/api/channels/${textChannel.id}/messages`,
    {
      method: 'POST',
      token: owner.token,
      body: { content: 'must never enter an encrypted channel as plaintext' },
    },
  );
  assert.equal(plaintextRejected.status, 409);
  assert.equal(
    (await plaintextRejected.json()).error?.code,
    'encrypted_channel_requires_e2ee',
  );
  const plaintextEditRejected = await request(
    `/api/channels/${textChannel.id}/messages/${message.id}`,
    {
      method: 'PATCH',
      token: owner.token,
      body: { content: 'must not edit legacy plaintext after cutover' },
    },
  );
  assert.equal(plaintextEditRejected.status, 409);
  const encryptedPreviewRejected = await request(
    `/api/link-preview?channelId=${textChannel.id}&url=${encodeURIComponent('https://example.com/')}`,
    { token: owner.token },
  );
  assert.equal(encryptedPreviewRejected.status, 409);
  assert.equal(
    (await encryptedPreviewRejected.json()).error?.code,
    'encrypted_channel_requires_e2ee',
  );

  const memberInitializeFirst = await request(
    `/api/channels/${textChannel.id}/mls/initialize`,
    { method: 'POST', token: member.token, body: {} },
  );
  assert.equal(memberInitializeFirst.status, 403);
  assert.equal(
    (await memberInitializeFirst.json()).error?.code,
    'owner_required',
  );
  const initializeGroup = await request(
    `/api/channels/${textChannel.id}/mls/initialize`,
    { method: 'POST', token: owner.token, body: {} },
  );
  assert.equal(initializeGroup.status, 201);
  const initializedResponse = await initializeGroup.json();
  assert.equal(initializedResponse.created, true);
  const initialized = initializedResponse.group;
  assert.equal(
    initialized.groupId,
    `yappa-text-v1|${owner.server.id}|${textChannel.id}`,
  );
  assert.equal(initialized.currentEpoch, 0);
  const existingInitialization = await request(
    `/api/channels/${textChannel.id}/mls/initialize`,
    { method: 'POST', token: member.token, body: {} },
  );
  assert.equal(existingInitialization.status, 200);
  assert.equal((await existingInitialization.json()).created, false);

  const encryptedAttachmentBytes = crypto.randomBytes(256);
  const encryptedAttachmentDigest = crypto
    .createHash('sha256')
    .update(encryptedAttachmentBytes)
    .digest('hex');
  const encryptedAttachmentForm = new FormData();
  const encryptedAttachmentId = `eatt_${crypto
    .randomBytes(16)
    .toString('base64url')}`;
  const encryptedAttachmentHeader = crypto
    .randomBytes(24)
    .toString('base64url');
  encryptedAttachmentForm.append('attachmentId', encryptedAttachmentId);
  encryptedAttachmentForm.append(
    'secretstreamHeader',
    encryptedAttachmentHeader,
  );
  encryptedAttachmentForm.append('ciphertextSha256', encryptedAttachmentDigest);
  encryptedAttachmentForm.append('chunkCount', '3');
  encryptedAttachmentForm.append(
    'ciphertext',
    new Blob([encryptedAttachmentBytes], {
      type: 'application/octet-stream',
    }),
    'ciphertext.bin',
  );
  const encryptedAttachmentUpload = await fetch(
    `${baseUrl}/api/channels/${textChannel.id}/encrypted-attachments`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${owner.token}` },
      body: encryptedAttachmentForm,
    },
  );
  assert.equal(encryptedAttachmentUpload.status, 201);
  const encryptedAttachment = (
    await encryptedAttachmentUpload.json()
  ).attachment;
  assert.equal(
    encryptedAttachment.ciphertextSha256,
    encryptedAttachmentDigest,
  );
  assert.equal(encryptedAttachment.id, encryptedAttachmentId);
  assert.equal(encryptedAttachment.ciphertextSizeBytes, 256);
  assert.equal(encryptedAttachment.expiresAt, null);

  const retryAttachmentForm = new FormData();
  retryAttachmentForm.append('attachmentId', encryptedAttachmentId);
  retryAttachmentForm.append(
    'secretstreamHeader',
    encryptedAttachmentHeader,
  );
  retryAttachmentForm.append('ciphertextSha256', encryptedAttachmentDigest);
  retryAttachmentForm.append('chunkCount', '3');
  retryAttachmentForm.append(
    'ciphertext',
    new Blob([encryptedAttachmentBytes], {
      type: 'application/octet-stream',
    }),
    'ciphertext.bin',
  );
  const retryAttachmentUpload = await fetch(
    `${baseUrl}/api/channels/${textChannel.id}/encrypted-attachments`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${owner.token}` },
      body: retryAttachmentForm,
    },
  );
  assert.equal(retryAttachmentUpload.status, 200);
  assert.equal((await retryAttachmentUpload.json()).replayed, true);

  const conflictingAttachmentForm = new FormData();
  conflictingAttachmentForm.append('attachmentId', encryptedAttachmentId);
  conflictingAttachmentForm.append(
    'secretstreamHeader',
    crypto.randomBytes(24).toString('base64url'),
  );
  conflictingAttachmentForm.append(
    'ciphertextSha256',
    encryptedAttachmentDigest,
  );
  conflictingAttachmentForm.append('chunkCount', '3');
  conflictingAttachmentForm.append(
    'ciphertext',
    new Blob([encryptedAttachmentBytes], {
      type: 'application/octet-stream',
    }),
    'ciphertext.bin',
  );
  const conflictingAttachmentUpload = await fetch(
    `${baseUrl}/api/channels/${textChannel.id}/encrypted-attachments`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${owner.token}` },
      body: conflictingAttachmentForm,
    },
  );
  assert.equal(conflictingAttachmentUpload.status, 409);
  assert.equal(
    (await conflictingAttachmentUpload.json()).error?.code,
    'encrypted_attachment_operation_conflict',
  );

  const crossUploaderAttachment = await request(
    `/api/channels/${textChannel.id}/mls/messages`,
    {
      method: 'POST',
      token: member.token,
      body: {
        clientOperationId: `mlsop_${crypto.randomBytes(16).toString('base64url')}`,
        messageClass: 'application',
        acceptedEpoch: 0,
        wireMessage: crypto.randomBytes(96).toString('base64url'),
        event: {
          eventId: crypto.randomBytes(16).toString('base64url'),
          kind: 'attachment',
          encryptedAttachmentIds: [encryptedAttachment.id],
        },
      },
    },
  );
  assert.equal(crossUploaderAttachment.status, 409);
  assert.equal(
    (await crossUploaderAttachment.json()).error?.code,
    'invalid_encrypted_attachment_reference',
  );

  const eventId = crypto.randomBytes(16).toString('base64url');
  const applicationResponse = await request(
    `/api/channels/${textChannel.id}/mls/messages`,
    {
      method: 'POST',
      token: owner.token,
      body: {
        clientOperationId: `mlsop_${crypto.randomBytes(16).toString('base64url')}`,
        messageClass: 'application',
        acceptedEpoch: 0,
        wireMessage: crypto.randomBytes(96).toString('base64url'),
        event: {
          eventId,
          kind: 'attachment',
          encryptedAttachmentIds: [encryptedAttachment.id],
        },
      },
    },
  );
  assert.equal(applicationResponse.status, 201);
  const applicationDelivery = (await applicationResponse.json()).message;
  assert.equal(applicationDelivery.serverSequence, 1);
  assert.deepEqual(applicationDelivery.event.encryptedAttachmentIds, [
    encryptedAttachment.id,
  ]);
  const encryptedAttachmentDownload = await request(
    `/api/channels/${textChannel.id}/encrypted-attachments/${encryptedAttachment.id}`,
    { token: member.token },
  );
  assert.equal(encryptedAttachmentDownload.status, 200);
  assert.equal(
    encryptedAttachmentDownload.headers.get('x-yappa-ciphertext-sha256'),
    encryptedAttachmentDigest,
  );
  assert.deepEqual(
    Buffer.from(await encryptedAttachmentDownload.arrayBuffer()),
    encryptedAttachmentBytes,
  );
  await expectStatus(
    `/api/channels/${textChannel.id}/encrypted-attachments/${encryptedAttachment.id}`,
    401,
  );
  const limitDb = new Database(dbPath);
  limitDb
    .prepare('UPDATE server_settings SET attachment_max_bytes = 1024 WHERE id = 1')
    .run();
  limitDb.close();
  const oversizedLegacyForm = new FormData();
  oversizedLegacyForm.append('channelId', textChannel.id);
  oversizedLegacyForm.append(
    'file',
    new Blob([Buffer.alloc(1025)], { type: 'application/octet-stream' }),
    'oversized.bin',
  );
  const oversizedLegacyUpload = await fetch(
    `${baseUrl}/api/uploads/attachments`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${owner.token}` },
      body: oversizedLegacyForm,
    },
  );
  assert.equal(oversizedLegacyUpload.status, 413);
  assert.equal(
    (await oversizedLegacyUpload.json()).error?.code,
    'file_too_large',
  );
  const oversizedEncryptedForm = new FormData();
  oversizedEncryptedForm.append(
    'attachmentId',
    `eatt_${crypto.randomBytes(16).toString('base64url')}`,
  );
  oversizedEncryptedForm.append(
    'secretstreamHeader',
    crypto.randomBytes(24).toString('base64url'),
  );
  oversizedEncryptedForm.append(
    'ciphertextSha256',
    crypto.createHash('sha256').update('unused').digest('hex'),
  );
  oversizedEncryptedForm.append('chunkCount', '1');
  oversizedEncryptedForm.append(
    'ciphertext',
    new Blob([Buffer.alloc(1024 * 1024 + 1025)], {
      type: 'application/octet-stream',
    }),
    'ciphertext.bin',
  );
  const oversizedEncryptedUpload = await fetch(
    `${baseUrl}/api/channels/${textChannel.id}/encrypted-attachments`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${owner.token}` },
      body: oversizedEncryptedForm,
    },
  );
  assert.equal(oversizedEncryptedUpload.status, 413);
  assert.equal(
    (await oversizedEncryptedUpload.json()).error?.code,
    'file_too_large',
  );
  const postLimitDb = new Database(dbPath);
  assert.equal(
    postLimitDb
      .prepare('SELECT COUNT(*) AS count FROM attachments')
      .get().count,
    0,
  );
  assert.equal(
    postLimitDb
      .prepare('SELECT COUNT(*) AS count FROM encrypted_attachments')
      .get().count,
    1,
  );
  postLimitDb.close();
  assert.equal(
    fs.readdirSync(
      path.join(
        testDir,
        'servers',
        owner.server.id,
        'attachments',
      ),
      { recursive: true, withFileTypes: true },
    ).filter((entry) => entry.isFile()).length,
    0,
  );
  const unauthorizedEncryptedDelete = await request(
    `/api/channels/${textChannel.id}/mls/messages`,
    {
      method: 'POST',
      token: member.token,
      body: {
        clientOperationId: `mlsop_${crypto.randomBytes(16).toString('base64url')}`,
        messageClass: 'application',
        acceptedEpoch: 0,
        wireMessage: crypto.randomBytes(96).toString('base64url'),
        event: {
          eventId: crypto.randomBytes(16).toString('base64url'),
          kind: 'delete',
          targetEventId: eventId,
        },
      },
    },
  );
  assert.equal(unauthorizedEncryptedDelete.status, 403);
  assert.equal(
    (await unauthorizedEncryptedDelete.json()).error?.code,
    'encrypted_event_mutation_forbidden',
  );
  const proposalResponse = await request(
    `/api/channels/${textChannel.id}/mls/messages`,
    {
      method: 'POST',
      token: member.token,
      body: {
        clientOperationId: `mlsop_${crypto.randomBytes(16).toString('base64url')}`,
        messageClass: 'proposal',
        acceptedEpoch: 0,
        parentEpoch: 0,
        wireMessage: crypto.randomBytes(80).toString('base64url'),
      },
    },
  );
  assert.equal(proposalResponse.status, 201);
  assert.equal((await proposalResponse.json()).message.serverSequence, 2);
  const commitOperationId = `mlsop_${crypto
    .randomBytes(16)
    .toString('base64url')}`;
  const commitWireMessage = crypto.randomBytes(112).toString('base64url');
  const commitBody = {
    clientOperationId: commitOperationId,
    messageClass: 'commit',
    acceptedEpoch: 1,
    parentEpoch: 0,
    wireMessage: commitWireMessage,
  };
  const commitResponse = await request(
    `/api/channels/${textChannel.id}/mls/messages`,
    {
      method: 'POST',
      token: owner.token,
      body: commitBody,
    },
  );
  assert.equal(commitResponse.status, 201);
  const committedDelivery = (await commitResponse.json()).message;
  assert.equal(committedDelivery.serverSequence, 3);
  assert.equal(committedDelivery.clientOperationId, commitOperationId);
  const replayedCommit = await request(
    `/api/channels/${textChannel.id}/mls/messages`,
    {
      method: 'POST',
      token: owner.token,
      body: commitBody,
    },
  );
  assert.equal(replayedCommit.status, 200);
  const replayedCommitBody = await replayedCommit.json();
  assert.equal(replayedCommitBody.replayed, true);
  assert.equal(replayedCommitBody.message.id, committedDelivery.id);
  assert.equal(replayedCommitBody.message.serverSequence, 3);
  const conflictingOperation = await request(
    `/api/channels/${textChannel.id}/mls/messages`,
    {
      method: 'POST',
      token: owner.token,
      body: {
        ...commitBody,
        wireMessage: crypto.randomBytes(112).toString('base64url'),
      },
    },
  );
  assert.equal(conflictingOperation.status, 409);
  assert.equal(
    (await conflictingOperation.json()).error?.code,
    'mls_operation_conflict',
  );
  const staleCommit = await request(
    `/api/channels/${textChannel.id}/mls/messages`,
    {
      method: 'POST',
      token: member.token,
      body: {
        clientOperationId: `mlsop_${crypto.randomBytes(16).toString('base64url')}`,
        messageClass: 'commit',
        acceptedEpoch: 1,
        parentEpoch: 0,
        wireMessage: crypto.randomBytes(112).toString('base64url'),
      },
    },
  );
  assert.equal(staleCommit.status, 409);
  assert.equal((await staleCommit.json()).error?.code, 'mls_epoch_conflict');
  const messageRootEventId = crypto.randomBytes(16).toString('base64url');
  const messageRoot = await request(
    `/api/channels/${textChannel.id}/mls/messages`,
    {
      method: 'POST',
      token: owner.token,
      body: {
        clientOperationId: `mlsop_${crypto.randomBytes(16).toString('base64url')}`,
        messageClass: 'application',
        acceptedEpoch: 1,
        wireMessage: crypto.randomBytes(96).toString('base64url'),
        event: { eventId: messageRootEventId, kind: 'message' },
      },
    },
  );
  assert.equal(messageRoot.status, 201);
  const authorizedEditEventId = crypto.randomBytes(16).toString('base64url');
  const authorizedEncryptedEdit = await request(
    `/api/channels/${textChannel.id}/mls/messages`,
    {
      method: 'POST',
      token: owner.token,
      body: {
        clientOperationId: `mlsop_${crypto.randomBytes(16).toString('base64url')}`,
        messageClass: 'application',
        acceptedEpoch: 1,
        wireMessage: crypto.randomBytes(96).toString('base64url'),
        event: {
          eventId: authorizedEditEventId,
          kind: 'edit',
          targetEventId: messageRootEventId,
        },
      },
    },
  );
  assert.equal(authorizedEncryptedEdit.status, 201);
  const nestedMutation = await request(
    `/api/channels/${textChannel.id}/mls/messages`,
    {
      method: 'POST',
      token: owner.token,
      body: {
        clientOperationId: `mlsop_${crypto.randomBytes(16).toString('base64url')}`,
        messageClass: 'application',
        acceptedEpoch: 1,
        wireMessage: crypto.randomBytes(96).toString('base64url'),
        event: {
          eventId: crypto.randomBytes(16).toString('base64url'),
          kind: 'reaction',
          targetEventId: authorizedEditEventId,
        },
      },
    },
  );
  assert.equal(nestedMutation.status, 409);
  assert.equal(
    (await nestedMutation.json()).error?.code,
    'invalid_encrypted_event_reference',
  );
  const duplicateEvent = await request(
    `/api/channels/${textChannel.id}/mls/messages`,
    {
      method: 'POST',
      token: owner.token,
      body: {
        clientOperationId: `mlsop_${crypto.randomBytes(16).toString('base64url')}`,
        messageClass: 'application',
        acceptedEpoch: 1,
        wireMessage: crypto.randomBytes(96).toString('base64url'),
        event: { eventId, kind: 'message' },
      },
    },
  );
  assert.equal(duplicateEvent.status, 409);
  assert.equal(
    (await duplicateEvent.json()).error?.code,
    'duplicate_encrypted_event',
  );
  const missingTargetEvent = await request(
    `/api/channels/${textChannel.id}/mls/messages`,
    {
      method: 'POST',
      token: owner.token,
      body: {
        clientOperationId: `mlsop_${crypto.randomBytes(16).toString('base64url')}`,
        messageClass: 'application',
        acceptedEpoch: 1,
        wireMessage: crypto.randomBytes(96).toString('base64url'),
        event: {
          eventId: crypto.randomBytes(16).toString('base64url'),
          kind: 'edit',
          targetEventId: crypto.randomBytes(16).toString('base64url'),
        },
      },
    },
  );
  assert.equal(missingTargetEvent.status, 409);
  assert.equal(
    (await missingTargetEvent.json()).error?.code,
    'invalid_encrypted_event_reference',
  );
  const welcomeResponse = await request(
    `/api/channels/${textChannel.id}/mls/messages`,
    {
      method: 'POST',
      token: owner.token,
      body: {
        clientOperationId: `mlsop_${crypto.randomBytes(16).toString('base64url')}`,
        messageClass: 'welcome',
        acceptedEpoch: 1,
        recipientDeviceId: member.mediaDeviceId,
        wireMessage: crypto.randomBytes(128).toString('base64url'),
      },
    },
  );
  assert.equal(welcomeResponse.status, 201);
  assert.equal((await welcomeResponse.json()).message.serverSequence, 6);

  const ownerDelivery = await (
    await request(
      `/api/channels/${textChannel.id}/mls/messages?after=0&limit=100`,
      { token: owner.token },
    )
  ).json();
  assert.deepEqual(
    ownerDelivery.messages.map((item) => item.serverSequence),
    [1, 2, 3, 4, 5],
  );
  const memberDelivery = await (
    await request(
      `/api/channels/${textChannel.id}/mls/messages?after=0&limit=100`,
      { token: member.token },
    )
  ).json();
  assert.deepEqual(
    memberDelivery.messages.map((item) => item.serverSequence),
    [1, 2, 3, 4, 5, 6],
  );
  const acknowledge = await request(
    `/api/channels/${textChannel.id}/mls/ack`,
    {
      method: 'POST',
      token: member.token,
      body: { acknowledgedSequence: 6, acknowledgedEpoch: 1 },
    },
  );
  assert.equal(acknowledge.status, 200);
  const acknowledgementRollback = await request(
    `/api/channels/${textChannel.id}/mls/ack`,
    {
      method: 'POST',
      token: member.token,
      body: { acknowledgedSequence: 3, acknowledgedEpoch: 0 },
    },
  );
  assert.equal(acknowledgementRollback.status, 409);

  await expectSocketRejected(null);
  await expectSocketRejected('invalid-session-token');
  await expectInvalidVoiceJoin(member.token, textChannel.id);

  const banResponse = await request('/api/admin/bans', {
    method: 'POST',
    token: owner.token,
    body: { userId: member.user.id, reason: 'authorization test cleanup' },
  });
  assert.equal(banResponse.status, 201);
  await expectStatus('/api/auth/me', 401, { token: member.token });
  const rotatedRoomState = await ownerRealtime.nextEvent('media:e2ee:state');
  assert.equal(rotatedRoomState.epoch, sharedEpoch + 1);
  assert.deepEqual(
    rotatedRoomState.devices.map((device) => device.id),
    [owner.mediaDeviceId],
  );
  ownerRealtime.close();
  memberRealtime.close();

  process.stdout.write('Authorization integration test passed.\n');
}

run()
  .catch((error) => {
    process.stderr.write(`${error.stack || error}\n${serverErrors}`);
    process.exitCode = 1;
  })
  .finally(() => {
    server.kill('SIGTERM');
    fs.rmSync(testDir, { recursive: true, force: true });
  });
