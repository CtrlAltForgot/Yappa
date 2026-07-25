const assert = require('assert');
const crypto = require('crypto');
const dgram = require('dgram');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const port = 4201;
const baseUrl = `http://127.0.0.1:${port}`;
const testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'yappa-identity-test-'));
const dbPath = path.join(testDir, 'test.db');
const dataRoot = path.join(testDir, 'servers');

async function startServer() {
  const child = spawn(process.execPath, ['src/server.js'], {
    cwd: path.resolve(__dirname, '..'),
    env: {
      ...process.env,
      PORT: String(port),
      DB_PATH: dbPath,
      DATA_ROOT: dataRoot,
      YAPPA_HTTPS_PORT: '8443',
      YAPPA_ADVERTISED_ADDRESS: '203.0.113.10',
      BCRYPT_COST: '10',
      CORS_ORIGIN: '',
    },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let errors = '';
  child.stderr.on('data', (chunk) => {
    errors += chunk.toString();
  });
  for (let attempt = 0; attempt < 50; attempt += 1) {
    try {
      const response = await fetch(`${baseUrl}/health`);
      if (response.ok) return { child, errors: () => errors };
    } catch (_) {
      // The disposable server is still starting.
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  child.kill('SIGTERM');
  throw new Error(`Disposable identity server did not start.\n${errors}`);
}

async function stopServer(child) {
  if (child.exitCode !== null) return;
  await new Promise((resolve) => {
    child.once('exit', resolve);
    child.kill('SIGTERM');
    setTimeout(resolve, 1500);
  });
}

async function fetchIdentity() {
  const nonce = crypto.randomBytes(32).toString('base64url');
  const response = await fetch(
    `${baseUrl}/api/server/identity?nonce=${nonce}`,
  );
  assert.equal(response.status, 200);
  return (await response.json()).identity;
}

async function discoverIdentity() {
  const nonce = crypto.randomBytes(32).toString('base64url');
  const socket = dgram.createSocket('udp4');
  const response = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      socket.close();
      reject(new Error('LAN discovery response timed out.'));
    }, 2000);
    socket.on('message', (message) => {
      clearTimeout(timer);
      socket.close();
      resolve(JSON.parse(message.toString('utf8')));
    });
    socket.send(
      Buffer.from(
        JSON.stringify({
          protocol: 'yappa-lan-discovery-v1',
          nonce,
        }),
      ),
      41200,
      '127.0.0.1',
    );
  });
  assert.equal(response.protocol, 'yappa-lan-discovery-v1');
  assert.equal(response.nonce, nonce);
  assert.equal(response.tlsPort, 8443);
  assert.equal(response.advertisedAddress, '203.0.113.10');
  const publicKey = crypto.createPublicKey({
    key: {
      kty: 'OKP',
      crv: 'Ed25519',
      x: response.publicKey,
    },
    format: 'jwk',
  });
  const proof =
    `yappa-lan-discovery-v1|${response.serverId}|${nonce}|` +
    `${response.tlsPort}|${response.advertisedAddress}`;
  assert.equal(
    crypto.verify(
      null,
      Buffer.from(proof, 'utf8'),
      publicKey,
      Buffer.from(response.signature, 'base64url'),
    ),
    true,
  );
  return response;
}

async function run() {
  let running = await startServer();
  const first = await fetchIdentity();
  const discovered = await discoverIdentity();
  assert.equal(discovered.serverId, first.serverId);
  assert.equal(discovered.publicKey, first.publicKey);
  await stopServer(running.child);

  running = await startServer();
  const second = await fetchIdentity();
  assert.equal(second.serverId, first.serverId);
  assert.equal(second.publicKey, first.publicKey);
  assert.notEqual(second.nonce, first.nonce);
  assert.notEqual(second.signature, first.signature);

  const identityFiles = fs
    .readdirSync(path.join(dataRoot, first.serverId))
    .filter((name) => name === 'server-identity.json');
  assert.deepEqual(identityFiles, ['server-identity.json']);
  const mode =
    fs.statSync(
      path.join(dataRoot, first.serverId, 'server-identity.json'),
    ).mode & 0o777;
  assert.equal(mode, 0o600);

  await stopServer(running.child);
  process.stdout.write('Server identity integration test passed.\n');
}

run()
  .catch((error) => {
    process.stderr.write(`${error.stack || error}\n`);
    process.exitCode = 1;
  })
  .finally(() => {
    fs.rmSync(testDir, { recursive: true, force: true });
  });
