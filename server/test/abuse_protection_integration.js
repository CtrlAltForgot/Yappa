const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const nacl = require('tweetnacl');
const WebSocket = require('ws');

const port = 4199;
const baseUrl = `http://127.0.0.1:${port}`;
const testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'yappa-abuse-test-'));
const dbPath = path.join(testDir, 'test.db');

const server = spawn(process.execPath, ['src/server.js'], {
  cwd: path.resolve(__dirname, '..'),
  env: {
    ...process.env,
    PORT: String(port),
    DB_PATH: dbPath,
    BCRYPT_COST: '10',
    AUTH_RATE_LIMIT_MAX: '100',
    CHALLENGE_RATE_LIMIT_MAX: '100',
    CONTENT_MUTATION_RATE_LIMIT_WINDOW_MS: '60000',
    CONTENT_MUTATION_RATE_LIMIT_MAX: '3',
    EXPENSIVE_OPERATION_RATE_LIMIT_WINDOW_MS: '60000',
    EXPENSIVE_OPERATION_RATE_LIMIT_MAX: '2',
    SOCKET_CONTROL_RATE_LIMIT_WINDOW_MS: '60000',
    SOCKET_CONTROL_RATE_LIMIT_MAX: '2',
    SOCKET_CONNECTION_RATE_LIMIT_WINDOW_MS: '60000',
    SOCKET_CONNECTION_RATE_LIMIT_MAX: '2',
    CORS_ORIGIN: '',
    LIVEKIT_URL: 'ws://127.0.0.1:7880',
    LIVEKIT_API_KEY: 'abuse-test-key',
    LIVEKIT_API_SECRET: 'abuse-test-secret-that-is-long-enough',
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

async function request(route, { token, method = 'GET', body } = {}) {
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
  const yuidKeys = nacl.sign.keyPair();
  const mediaKeys = crypto.generateKeyPairSync('x25519');
  const mediaPublicKey = mediaKeys.publicKey.export({ format: 'jwk' }).x;
  const mediaDeviceId =
    `device_${crypto.randomBytes(18).toString('base64url')}`;
  const challengeResponse = await request('/api/auth/yuid/challenge');
  assert.equal(challengeResponse.status, 200);
  const challenge = (await challengeResponse.json()).challenge;
  const yuidMessage = Buffer.from(
    `yappa-auth-v1|${challenge.serverId}|${username}|${challenge.nonce}`,
  );
  const mediaMessage = Buffer.from(
    `yappa-media-device-v1|${challenge.serverId}|${username}|` +
      `${challenge.nonce}|${mediaPublicKey}|${mediaDeviceId}`,
  );
  const response = await request('/api/auth/session', {
    method: 'POST',
    body: {
      username,
      password: 'abuse-test-password',
      yuidPublicKey: Buffer.from(yuidKeys.publicKey).toString('base64url'),
      yuidSignature: Buffer.from(
        nacl.sign.detached(new Uint8Array(yuidMessage), yuidKeys.secretKey),
      ).toString('base64url'),
      yuidNonce: challenge.nonce,
      mediaDeviceId,
      mediaPublicKey,
      mediaDeviceSignature: Buffer.from(
        nacl.sign.detached(new Uint8Array(mediaMessage), yuidKeys.secretKey),
      ).toString('base64url'),
      deviceName: 'Abuse protection integration test',
    },
  });
  assert.equal(response.status, 201);
  return response.json();
}

async function sendMessage(account, channelId, sequence) {
  return request(`/api/channels/${channelId}/messages`, {
    token: account.token,
    method: 'POST',
    body: { content: `rate-limit-message-${sequence}` },
  });
}

async function connectRealtime(token) {
  const socket = new WebSocket(
    `ws://127.0.0.1:${port}/socket.io/?EIO=4&transport=websocket`,
  );
  const acknowledgements = new Map();
  let nextAckId = 1;
  let resolveConnected;
  let rejectConnected;
  const connected = new Promise((resolve, reject) => {
    resolveConnected = resolve;
    rejectConnected = reject;
  });
  socket.on('message', (data) => {
    const packet = data.toString();
    if (packet === '2') {
      socket.send('3');
    } else if (packet.startsWith('0')) {
      socket.send(`40${JSON.stringify({ token })}`);
    } else if (packet.startsWith('40')) {
      resolveConnected();
    } else if (packet.startsWith('44')) {
      socket.close();
      rejectConnected(new Error(`Realtime authentication failed: ${packet}`));
    } else {
      const match = /^43(\d+)(.*)$/.exec(packet);
      if (!match) return;
      const waiter = acknowledgements.get(Number(match[1]));
      if (!waiter) return;
      acknowledgements.delete(Number(match[1]));
      waiter(JSON.parse(match[2])[0]);
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
    emitWithAck(event, payload) {
      const ackId = nextAckId;
      nextAckId += 1;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error(`Realtime ${event} acknowledgement timed out.`)),
          2500,
        );
        acknowledgements.set(ackId, (value) => {
          clearTimeout(timer);
          resolve(value);
        });
        socket.send(`42${ackId}${JSON.stringify([event, payload])}`);
      });
    },
    close() {
      socket.close();
    },
  };
}

async function run() {
  await waitForServer();
  const first = await createAccount('ratelimitfirst');
  const second = await createAccount('ratelimitsecond');
  const textChannel = first.channels.find((channel) => channel.type === 'text');
  const voiceChannel = first.channels.find((channel) => channel.type === 'voice');
  assert.ok(textChannel);
  assert.ok(voiceChannel);

  for (let sequence = 1; sequence <= 3; sequence += 1) {
    const response = await sendMessage(first, textChannel.id, sequence);
    assert.equal(response.status, 201);
  }
  const limited = await sendMessage(first, textChannel.id, 4);
  assert.equal(limited.status, 429);
  assert.equal((await limited.json()).error?.code, 'content_rate_limited');
  assert.equal(limited.headers.get('ratelimit-limit'), '3');
  assert.equal(limited.headers.get('ratelimit-remaining'), '0');
  assert.ok(Number(limited.headers.get('retry-after')) >= 1);

  const otherAccount = await sendMessage(second, textChannel.id, 1);
  assert.equal(
    otherAccount.status,
    201,
    'Limits must be scoped to the authenticated account, not a shared IP.',
  );

  const voiceToken = await request('/api/voice/token', {
    token: first.token,
    method: 'POST',
    body: { channelId: voiceChannel.id },
  });
  assert.equal(
    voiceToken.status,
    200,
    'Content limits must not consume the resource-intensive operation budget.',
  );

  const realtime = await connectRealtime(first.token);
  try {
    assert.equal(
      (await realtime.emitWithAck('voice:join', {
        channelId: voiceChannel.id,
      })).ok,
      true,
    );
    assert.equal(
      (await realtime.emitWithAck('voice:join', {
        channelId: voiceChannel.id,
      })).ok,
      true,
    );
    const socketLimited = await realtime.emitWithAck('voice:join', {
      channelId: voiceChannel.id,
    });
    assert.equal(socketLimited.ok, false);
    assert.equal(socketLimited.error?.code, 'socket_rate_limited');
    assert.ok(socketLimited.error?.retryAfter >= 1);
  } finally {
    realtime.close();
  }

  const secondRealtime = await connectRealtime(second.token);
  secondRealtime.close();
  await assert.rejects(
    connectRealtime(first.token),
    /Realtime authentication failed/,
  );

  process.stdout.write('Abuse protection integration test passed.\n');
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
