const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const Database = require('better-sqlite3');
const {
  createDb,
  createUserWithRole,
  nowIso,
  sessionTokenStorageValue,
} = require('../src/db');

const port = 4205;
const baseUrl = `http://127.0.0.1:${port}`;
const testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'yappa-storage-full-'));
const dbPath = path.join(testDir, 'data', 'yappa.db');
const dataRoot = path.join(testDir, 'data', 'servers');
const token = 'storage-full-test-token';

const db = createDb(dbPath, {
  serverName: 'Storage full test',
  serverDescription: 'Disposable storage guard fixture',
});
const owner = createUserWithRole(db, {
  username: 'storageowner',
  usernameNormalized: 'storageowner',
  passwordHash: 'unused-test-hash',
  role: 'owner',
});
const createdAt = nowIso();
db.prepare(`
  INSERT INTO sessions (
    token, user_id, created_at, last_seen_at, expires_at, idle_expires_at,
    device_name
  )
  VALUES (?, ?, ?, ?, ?, ?, 'Storage guard fixture')
`).run(
  sessionTokenStorageValue(token),
  owner.id,
  createdAt,
  createdAt,
  new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
  new Date(Date.now() + 60 * 60 * 1000).toISOString(),
);
const channelId = db
  .prepare("SELECT id FROM channels WHERE type = 'text' ORDER BY id LIMIT 1")
  .pluck()
  .get();
db.close();

const filesystem = fs.statfsSync(testDir, { bigint: true });
const available = filesystem.bavail * filesystem.bsize;
const maximum = BigInt(Number.MAX_SAFE_INTEGER - 32 * 1024 * 1024);
const critical = Number(available < maximum ? available + 1n : maximum);
const warning = critical + 16 * 1024 * 1024;

const server = spawn(process.execPath, ['src/server.js'], {
  cwd: path.resolve(__dirname, '..'),
  env: {
    ...process.env,
    PORT: String(port),
    DB_PATH: dbPath,
    DATA_ROOT: dataRoot,
    BCRYPT_COST: '10',
    NEW_ACCOUNT_PASSWORD_MIN_LENGTH: '10',
    CORS_ORIGIN: '',
    DURABLE_STORAGE_CRITICAL_FREE_BYTES: String(critical),
    DURABLE_STORAGE_WARNING_FREE_BYTES: String(warning),
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

async function run() {
  await waitForServer();
  const storageResponse = await fetch(`${baseUrl}/api/server/storage`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal(storageResponse.status, 200);
  const storage = (await storageResponse.json()).storage;
  assert.equal(storage.status, 'critical');
  assert.equal(storage.acceptsDurableWrites, false);

  const messageResponse = await fetch(
    `${baseUrl}/api/channels/${channelId}/messages`,
    {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ content: 'must not be accepted' }),
    },
  );
  assert.equal(messageResponse.status, 507);
  assert.equal(messageResponse.headers.get('retry-after'), '60');
  const error = (await messageResponse.json()).error;
  assert.equal(error.code, 'durable_storage_unavailable');
  assert.equal(error.retryable, true);
  assert.equal(error.storageStatus, 'critical');

  const mlsResponse = await fetch(
    `${baseUrl}/api/channels/${channelId}/mls/messages`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({}),
    },
  );
  assert.equal(mlsResponse.status, 507);

  const ordinaryForm = new FormData();
  ordinaryForm.append('channelId', String(channelId));
  ordinaryForm.append(
    'file',
    new Blob([Buffer.from('ordinary')], { type: 'text/plain' }),
    'ordinary.txt',
  );
  const ordinaryUploadResponse = await fetch(
    `${baseUrl}/api/uploads/attachments`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
      body: ordinaryForm,
    },
  );
  assert.equal(ordinaryUploadResponse.status, 507);

  const encryptedForm = new FormData();
  encryptedForm.append(
    'ciphertext',
    new Blob([Buffer.from('ciphertext')], {
      type: 'application/octet-stream',
    }),
    'ciphertext.bin',
  );
  const encryptedUploadResponse = await fetch(
    `${baseUrl}/api/channels/${channelId}/encrypted-attachments`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
      body: encryptedForm,
    },
  );
  assert.equal(encryptedUploadResponse.status, 507);

  const check = new Database(dbPath, { readonly: true });
  assert.equal(
    check.prepare('SELECT COUNT(*) FROM messages').pluck().get(),
    0,
  );
  assert.equal(
    check.prepare('SELECT COUNT(*) FROM mls_delivery_messages').pluck().get(),
    0,
  );
  assert.equal(
    check.prepare('SELECT COUNT(*) FROM attachments').pluck().get(),
    0,
  );
  assert.equal(
    check.prepare('SELECT COUNT(*) FROM encrypted_attachments').pluck().get(),
    0,
  );
  check.close();
  process.stdout.write('Storage-full fail-closed integration test passed.\n');
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
