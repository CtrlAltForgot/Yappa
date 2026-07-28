const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {spawnSync} = require('child_process');
const Database = require('better-sqlite3');

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
    '#!/usr/bin/env bash\nset -euo pipefail\n[[ "$1" == "--decrypt" ]]\ncat "$2"\n',
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
    ['future-schema', makeBackup('future-schema', 4), /schema is not supported/],
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
