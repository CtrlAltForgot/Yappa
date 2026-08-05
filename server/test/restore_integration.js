const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {spawn, spawnSync} = require('child_process');
const Database = require('better-sqlite3');
const {
  createDb,
  createUserWithRole,
  nowIso,
  sessionTokenStorageValue,
} = require('../src/db');

const repositoryRoot = path.resolve(__dirname, '..', '..');
const serverRoot = path.join(repositoryRoot, 'server');
const buildScript = path.join(
  repositoryRoot,
  '.github',
  'scripts',
  'build-server-bundle.sh',
);
const temporaryRoot = fs.mkdtempSync(
  path.join(os.tmpdir(), 'yappa-restore-test-'),
);
const fakeAge = path.join(temporaryRoot, 'age');
const scaleSessionToken = 'restore-scale-authenticated-session-token';

function run(command, args, options = {}) {
  return spawnSync(command, args, {
    cwd: repositoryRoot,
    encoding: 'utf8',
    env: {...process.env, YAPPA_AGE_BIN: fakeAge},
    ...options,
  });
}

function digest(filePath) {
  return crypto
    .createHash('sha256')
    .update(fs.readFileSync(filePath))
    .digest('hex');
}

function wait(milliseconds) {
  Atomics.wait(
    new Int32Array(new SharedArrayBuffer(4)),
    0,
    0,
    milliseconds,
  );
}

function curlStatus(url, headers = []) {
  const response = spawnSync(
    'curl',
    [
      '--silent',
      '--show-error',
      '--output',
      '/dev/null',
      '--write-out',
      '%{http_code}',
      ...headers.flatMap((header) => ['--header', header]),
      url,
    ],
    {encoding: 'utf8'},
  );
  assert.equal(response.status, 0, response.stderr);
  return Number(response.stdout);
}

function curlJson(url, headers = []) {
  const response = spawnSync(
    'curl',
    [
      '--fail',
      '--silent',
      '--show-error',
      ...headers.flatMap((header) => ['--header', header]),
      url,
    ],
    {encoding: 'utf8'},
  );
  assert.equal(response.status, 0, response.stderr);
  return JSON.parse(response.stdout);
}

function makeBackup(name, schemaVersion = 3, envDatabase = './data/yappa.db') {
  const source = path.join(temporaryRoot, `${name}-source`);
  const backup = path.join(temporaryRoot, `${name}.tar.gz.age`);
  const identityDirectory = path.join(
    source,
    'data',
    'servers',
    'test-server',
  );
  fs.mkdirSync(identityDirectory, {recursive: true});
  fs.mkdirSync(path.join(source, 'data', 'attachments'));
  fs.writeFileSync(
    path.join(source, '.env'),
    `SESSION_SECRET=test-only\nDB_PATH=${envDatabase}\n`,
  );
  const database = new Database(path.join(source, 'data', 'yappa.db'));
  database.exec(`
    CREATE TABLE schema_migrations (version INTEGER NOT NULL);
    INSERT INTO schema_migrations (version) VALUES (${schemaVersion});
    CREATE TABLE messages (id INTEGER PRIMARY KEY, content TEXT);
    INSERT INTO messages (content) VALUES ('persistent restore sentinel');
  `);
  database.close();
  fs.writeFileSync(
    path.join(identityDirectory, 'server-identity.json'),
    '{"serverId":"test-server","publicKey":"fixture"}\n',
  );
  fs.writeFileSync(
    path.join(source, 'data', 'attachments', 'sentinel.bin'),
    'persistent attachment sentinel\n',
  );
  const archived = spawnSync(
    'tar',
    ['-czf', backup, '-C', source, '.env', 'data'],
    {encoding: 'utf8'},
  );
  assert.equal(archived.status, 0, archived.stderr);
  return backup;
}

function makeScaleBackup() {
  const source = path.join(temporaryRoot, 'scale-source');
  const backup = path.join(temporaryRoot, 'scale.tar.gz.age');
  const identityDirectory = path.join(
    source,
    'data',
    'servers',
    'scale-server',
  );
  fs.mkdirSync(identityDirectory, {recursive: true});
  fs.writeFileSync(
    path.join(source, '.env'),
    'SESSION_SECRET=test-only\nDB_PATH=./data/yappa.db\n',
  );
  fs.writeFileSync(
    path.join(identityDirectory, 'server-identity.json'),
    '{"serverId":"scale-server","publicKey":"fixture"}\n',
  );

  const databasePath = path.join(source, 'data', 'yappa.db');
  const database = createDb(databasePath, {
    serverName: 'Scale restore fixture',
    serverDescription: 'Disposable durable-chat restore evidence',
  });
  const owner = createUserWithRole(database, {
    username: 'scaleowner',
    usernameNormalized: 'scaleowner',
    passwordHash: 'unused-test-hash',
    role: 'owner',
  });
  const serverId = database
    .prepare('SELECT server_id FROM server_config WHERE id = 1')
    .pluck()
    .get();
  const attachmentsRoot = path.join(
    source,
    'data',
    'servers',
    serverId,
    'attachments',
  );
  fs.mkdirSync(attachmentsRoot, {recursive: true});
  const channel = database
    .prepare("SELECT id FROM channels WHERE type = 'text' ORDER BY id LIMIT 1")
    .get();
  const createdAt = nowIso();
  database.prepare(`
    INSERT INTO sessions (
      token, user_id, created_at, last_seen_at, expires_at, idle_expires_at,
      device_name
    )
    VALUES (?, ?, ?, ?, ?, ?, 'Restored download fixture')
  `).run(
    sessionTokenStorageValue(scaleSessionToken),
    owner.id,
    createdAt,
    createdAt,
    new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
    new Date(Date.now() + 60 * 60 * 1000).toISOString(),
  );
  const insertMessage = database.prepare(`
    INSERT INTO messages (channel_id, user_id, content, created_at)
    VALUES (?, ?, ?, ?)
  `);
  const insertAttachment = database.prepare(`
    INSERT INTO attachments (
      server_id, channel_id, message_id, uploader_user_id, kind,
      original_name, stored_name, relative_path, mime_type, size_bytes,
      created_at, expires_at, deleted_at
    )
    VALUES (?, ?, ?, ?, 'file', ?, ?, ?, 'application/octet-stream', ?,
      ?, NULL, NULL)
  `);
  const attachmentDigests = new Map();
  database.transaction(() => {
    for (let index = 0; index < 5000; index += 1) {
      const message = insertMessage.run(
        channel.id,
        owner.id,
        `durable scale message ${index.toString().padStart(4, '0')}`,
        createdAt,
      );
      if (index >= 5000 - 128) {
        const storedName = `scale-${index.toString().padStart(3, '0')}.bin`;
        const relativePath = `${serverId}/attachments/${storedName}`;
        const bytes = Buffer.alloc(64 * 1024);
        bytes.writeUInt32BE(index, 0);
        crypto
          .createHash('sha256')
          .update(`yappa-scale-${index}`)
          .digest()
          .copy(bytes, 4);
        fs.writeFileSync(path.join(attachmentsRoot, storedName), bytes);
        attachmentDigests.set(storedName, digest(path.join(attachmentsRoot, storedName)));
        insertAttachment.run(
          serverId,
          channel.id,
          message.lastInsertRowid,
          owner.id,
          storedName,
          storedName,
          relativePath,
          bytes.length,
          createdAt,
        );
      }
    }
  })();
  database.pragma('wal_checkpoint(TRUNCATE)');
  assert.equal(
    database
      .prepare('SELECT COALESCE(MAX(version), 0) FROM schema_migrations')
      .pluck()
      .get(),
    6,
  );
  database.close();

  const backupScript = path.join(source, 'backup-yappa.sh');
  fs.copyFileSync(path.join(serverRoot, 'backup-yappa.sh'), backupScript);
  fs.chmodSync(backupScript, 0o700);
  const fakeBin = path.join(source, 'test-bin');
  fs.mkdirSync(fakeBin);
  fs.writeFileSync(
    path.join(fakeBin, 'docker'),
    `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "inspect" ]]; then
  printf 'true\\n'
fi
`,
    {mode: 0o700},
  );
  const backedUp = spawnSync(backupScript, [backup], {
    cwd: source,
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${fakeBin}:${process.env.PATH}`,
      YAPPA_AGE_BIN: fakeAge,
    },
  });
  assert.equal(backedUp.status, 0, backedUp.stderr || backedUp.stdout);
  assert.equal(fs.statSync(backup).mode & 0o777, 0o600);
  fs.rmSync(source, {recursive: true, force: true});
  return {backup, attachmentDigests, channelId: channel.id, serverId};
}

function restore(backup, bundle, checksum, destination) {
  return run(path.join(serverRoot, 'install-yappa.sh'), [
    'restore',
    '--backup',
    backup,
    '--local-bundle',
    bundle,
    '--sha256',
    checksum,
    '--install-dir',
    destination,
  ]);
}

try {
  fs.writeFileSync(
    fakeAge,
    `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "--decrypt" ]]; then
  cat "$2"
  exit 0
fi
output=''
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--output" ]]; then
    output="$2"
    shift 2
  else
    shift
  fi
done
[[ -n "$output" ]]
cat > "$output"
`,
    {mode: 0o700},
  );
  const bundleDirectory = path.join(temporaryRoot, 'bundle');
  const built = run(buildScript, ['0.1.0-restore-test', bundleDirectory], {
    env: {
      ...process.env,
      SOURCE_DATE_EPOCH: '1785211200',
      YAPPA_SOURCE_COMMIT:
        '0123456789abcdef0123456789abcdef01234567',
      YAPPA_AGE_BIN: fakeAge,
    },
  });
  assert.equal(built.status, 0, built.stderr || built.stdout);
  const bundle = path.join(
    bundleDirectory,
    'yappa-server-0.1.0-restore-test.tar.gz',
  );
  const checksum = digest(bundle);

  const backup = makeBackup('valid');
  const destination = path.join(temporaryRoot, 'restored-server');
  const restored = restore(backup, bundle, checksum, destination);
  assert.equal(restored.status, 0, restored.stderr || restored.stdout);
  assert.match(restored.stdout, /restored into a new installation/i);
  assert.match(restored.stdout, /restored server is stopped/i);
  assert.equal(fs.statSync(destination).mode & 0o777, 0o700);
  assert.equal(fs.statSync(path.join(destination, '.env')).mode & 0o777, 0o600);
  assert.equal(
    fs.statSync(
      path.join(
        destination,
        'data',
        'servers',
        'test-server',
        'server-identity.json',
      ),
    ).mode & 0o777,
    0o600,
  );
  assert.equal(
    fs.readFileSync(
      path.join(destination, 'data', 'attachments', 'sentinel.bin'),
      'utf8',
    ),
    'persistent attachment sentinel\n',
  );
  assert.equal(fs.existsSync(path.join(destination, 'livekit.yaml')), false);
  const restoredDatabase = new Database(
    path.join(destination, 'data', 'yappa.db'),
    {readonly: true},
  );
  assert.equal(
    restoredDatabase
      .prepare('SELECT content FROM messages')
      .pluck()
      .get(),
    'persistent restore sentinel',
  );
  restoredDatabase.close();

  const scale = makeScaleBackup();
  const scaleDestination = path.join(temporaryRoot, 'scale-restored-server');
  const scaleRestored = restore(
    scale.backup,
    bundle,
    checksum,
    scaleDestination,
  );
  assert.equal(
    scaleRestored.status,
    0,
    scaleRestored.stderr || scaleRestored.stdout,
  );
  const scaleDatabase = new Database(
    path.join(scaleDestination, 'data', 'yappa.db'),
    {readonly: true},
  );
  assert.equal(scaleDatabase.pragma('quick_check', {simple: true}), 'ok');
  assert.deepEqual(scaleDatabase.pragma('foreign_key_check'), []);
  assert.equal(
    scaleDatabase.prepare('SELECT COUNT(*) FROM messages').pluck().get(),
    5000,
  );
  assert.equal(
    scaleDatabase
      .prepare(
        `SELECT COUNT(*) FROM attachments
         WHERE message_id IS NOT NULL
         AND expires_at IS NULL
         AND deleted_at IS NULL`,
      )
      .pluck()
      .get(),
    128,
  );
  assert.equal(
    scaleDatabase
      .prepare('SELECT content FROM messages ORDER BY id LIMIT 1')
      .pluck()
      .get(),
    'durable scale message 0000',
  );
  assert.equal(
    scaleDatabase
      .prepare('SELECT content FROM messages ORDER BY id DESC LIMIT 1')
      .pluck()
      .get(),
    'durable scale message 4999',
  );
  scaleDatabase.close();
  for (const [storedName, expectedDigest] of scale.attachmentDigests) {
    assert.equal(
      digest(
        path.join(
          scaleDestination,
          'data',
          'servers',
          scale.serverId,
          'attachments',
          storedName,
        ),
      ),
      expectedDigest,
    );
  }

  const runtimePort = 4300 + crypto.randomInt(500);
  const runtimeBaseUrl = `http://127.0.0.1:${runtimePort}`;
  const restoredRuntime = spawn(process.execPath, ['src/server.js'], {
    cwd: serverRoot,
    env: {
      ...process.env,
      PORT: String(runtimePort),
      DB_PATH: path.join(scaleDestination, 'data', 'yappa.db'),
      DATA_ROOT: path.join(scaleDestination, 'data', 'servers'),
      SESSION_SECRET: 'restore-runtime-session-secret',
      ATTACHMENT_GRANT_SECRET: 'restore-runtime-attachment-grant-secret',
      BCRYPT_COST: '10',
      NEW_ACCOUNT_PASSWORD_MIN_LENGTH: '10',
      CORS_ORIGIN: '',
    },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let runtimeErrors = '';
  restoredRuntime.stderr.on('data', (chunk) => {
    runtimeErrors += chunk.toString();
  });
  try {
    let healthy = false;
    for (let attempt = 0; attempt < 60; attempt += 1) {
      const probe = spawnSync(
        'curl',
        ['--fail', '--silent', `${runtimeBaseUrl}/health`],
        {encoding: 'utf8'},
      );
      if (probe.status === 0) {
        healthy = true;
        break;
      }
      wait(100);
    }
    assert.equal(healthy, true, runtimeErrors || 'Restored server did not start.');
    const historyUrl =
      `${runtimeBaseUrl}/api/channels/${scale.channelId}/messages?limit=100`;
    assert.equal(curlStatus(historyUrl), 401);
    const authorization = `Authorization: Bearer ${scaleSessionToken}`;
    const history = curlJson(historyUrl, [authorization]);
    assert.equal(history.messages.length, 100);
    const restoredAttachment = history.messages
      .flatMap((message) => message.attachments)
      .at(0);
    assert.ok(restoredAttachment);
    assert.match(
      restoredAttachment.url,
      /^\/api\/attachments\/[0-9]+\/content\?/,
    );
    const downloaded = path.join(temporaryRoot, 'restored-download.bin');
    const download = spawnSync(
      'curl',
      [
        '--silent',
        '--show-error',
        '--output',
        downloaded,
        '--write-out',
        '%{http_code}',
        `${runtimeBaseUrl}${restoredAttachment.url}`,
      ],
      {encoding: 'utf8'},
    );
    assert.equal(download.status, 0, download.stderr);
    assert.equal(
      Number(download.stdout),
      200,
      fs.readFileSync(downloaded, 'utf8'),
    );
    assert.equal(fs.statSync(downloaded).size, restoredAttachment.sizeBytes);
    assert.equal(
      digest(downloaded),
      scale.attachmentDigests.get(restoredAttachment.storedName),
    );
  } finally {
    restoredRuntime.kill('SIGTERM');
    wait(300);
  }

  const wrongDigestDestination = path.join(temporaryRoot, 'wrong-digest');
  const wrongDigest = restore(
    backup,
    bundle,
    '0'.repeat(64),
    wrongDigestDestination,
  );
  assert.notEqual(wrongDigest.status, 0);
  assert.equal(fs.existsSync(wrongDigestDestination), false);

  const existing = path.join(temporaryRoot, 'existing');
  fs.mkdirSync(existing);
  fs.writeFileSync(path.join(existing, 'sentinel'), 'unchanged\n');
  const overwrite = restore(backup, bundle, checksum, existing);
  assert.notEqual(overwrite.status, 0);
  assert.equal(
    fs.readFileSync(path.join(existing, 'sentinel'), 'utf8'),
    'unchanged\n',
  );

  for (const [name, invalidBackup, expectedError] of [
    ['future-schema', makeBackup('future-schema', 7), /schema is not supported/],
    [
      'escaped-database',
      makeBackup('escaped-database', 3, '../outside.db'),
      /DB_PATH must identify/,
    ],
  ]) {
    const invalidDestination = path.join(temporaryRoot, name);
    const invalid = restore(
      invalidBackup,
      bundle,
      checksum,
      invalidDestination,
    );
    assert.notEqual(invalid.status, 0);
    assert.match(invalid.stderr, expectedError);
    assert.equal(fs.existsSync(invalidDestination), false);
  }

  const maliciousSource = path.join(temporaryRoot, 'malicious-source');
  fs.mkdirSync(path.join(maliciousSource, 'data'), {recursive: true});
  fs.writeFileSync(path.join(maliciousSource, '.env'), 'DB_PATH=./data/yappa.db\n');
  fs.symlinkSync('/etc/passwd', path.join(maliciousSource, 'data', 'yappa.db'));
  const maliciousBackup = path.join(temporaryRoot, 'malicious.tar.gz.age');
  const maliciousArchive = spawnSync(
    'tar',
    ['-czf', maliciousBackup, '-C', maliciousSource, '.env', 'data'],
    {encoding: 'utf8'},
  );
  assert.equal(maliciousArchive.status, 0, maliciousArchive.stderr);
  const maliciousDestination = path.join(temporaryRoot, 'malicious');
  const malicious = restore(
    maliciousBackup,
    bundle,
    checksum,
    maliciousDestination,
  );
  assert.notEqual(malicious.status, 0);
  assert.match(malicious.stderr, /symbolic link or unsupported file type/);
  assert.equal(fs.existsSync(maliciousDestination), false);

  assert.deepEqual(
    fs
      .readdirSync(temporaryRoot)
      .filter((entry) => entry.startsWith('.yappa-restore-assembly.')),
    [],
  );
} finally {
  fs.rmSync(temporaryRoot, {recursive: true, force: true});
}

process.stdout.write('Fresh-install encrypted restore test passed.\n');
