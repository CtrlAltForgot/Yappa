const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const bcrypt = require('bcryptjs');
const Database = require('better-sqlite3');
const nacl = require('tweetnacl');

const port = 4198;
const baseUrl = `http://127.0.0.1:${port}`;
const testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'yappa-password-test-'));
const dbPath = path.join(testDir, 'test.db');
const username = 'passwordtest';
const password = 'strong-passphrase';
const keyPair = nacl.sign.keyPair();
const mediaKeyPair = crypto.generateKeyPairSync('x25519');
const mediaPublicKey = mediaKeyPair.publicKey.export({ format: 'jwk' }).x;
const mediaDeviceId = `device_${crypto.randomBytes(18).toString('base64url')}`;

const server = spawn(process.execPath, ['src/server.js'], {
  cwd: path.resolve(__dirname, '..'),
  env: {
    ...process.env,
    PORT: String(port),
    DB_PATH: dbPath,
    BCRYPT_COST: '12',
    NEW_ACCOUNT_PASSWORD_MIN_LENGTH: '10',
    AUTH_RATE_LIMIT_MAX: '100',
    CHALLENGE_RATE_LIMIT_MAX: '100',
    AUTH_BACKOFF_FREE_FAILURES: '2',
    AUTH_BACKOFF_BASE_MS: '50',
    AUTH_BACKOFF_MAX_MS: '100',
    AUTH_BACKOFF_RESET_MS: '1000',
    CORS_ORIGIN: '',
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

async function authenticate(candidatePassword) {
  const challengeResponse = await fetch(
    `${baseUrl}/api/auth/yuid/challenge`,
  );
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

  return fetch(`${baseUrl}/api/auth/session`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      username,
      password: candidatePassword,
      yuidPublicKey: Buffer.from(keyPair.publicKey).toString('base64url'),
      yuidSignature: Buffer.from(signature).toString('base64url'),
      yuidNonce: challenge.nonce,
      mediaDeviceId,
      mediaPublicKey,
      mediaDeviceSignature: Buffer.from(mediaSignature).toString('base64url'),
      deviceName: 'Password hardening integration test',
    }),
  });
}

async function run() {
  await waitForServer();

  const shortPasswordResponse = await authenticate('short123');
  assert.equal(shortPasswordResponse.status, 400);
  const shortPasswordBody = await shortPasswordResponse.json();
  assert.equal(shortPasswordBody.error?.code, 'password_too_short');

  const createResponse = await authenticate(password);
  assert.equal(createResponse.status, 201);

  const db = new Database(dbPath);
  const created = db
    .prepare('SELECT id, password_hash FROM users WHERE lower(username) = ?')
    .get(username);
  assert.ok(created);
  assert.equal(bcrypt.getRounds(created.password_hash), 12);

  assert.equal((await authenticate('incorrect-password-1')).status, 401);
  assert.equal((await authenticate('incorrect-password-2')).status, 401);
  const delayedFailure = await authenticate('incorrect-password-3');
  assert.equal(delayedFailure.status, 429);
  assert.equal(delayedFailure.headers.get('retry-after'), '1');
  assert.equal((await authenticate(password)).status, 429);
  await new Promise((resolve) => setTimeout(resolve, 150));
  assert.equal((await authenticate(password)).status, 201);
  assert.equal((await authenticate('incorrect-after-success')).status, 401);

  const legacyHash = await bcrypt.hash(password, 10);
  db.prepare('UPDATE users SET password_hash = ? WHERE id = ?').run(
    legacyHash,
    created.id,
  );

  const loginResponse = await authenticate(password);
  assert.equal(loginResponse.status, 201);
  const upgraded = db
    .prepare('SELECT password_hash FROM users WHERE id = ?')
    .get(created.id);
  assert.equal(bcrypt.getRounds(upgraded.password_hash), 12);
  assert.equal(await bcrypt.compare(password, upgraded.password_hash), true);
  db.close();

  process.stdout.write('Password hardening integration test passed.\n');
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
