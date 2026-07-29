const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {spawnSync} = require('child_process');
const Database = require('better-sqlite3');

const serverRoot = path.resolve(__dirname, '..');
const temporaryRoot = fs.mkdtempSync(
  path.join(os.tmpdir(), 'yappa-upgrade-test-'),
);
const binRoot = path.join(temporaryRoot, 'bin');
const logPath = path.join(temporaryRoot, 'lifecycle.log');

function copyExecutable(name, destination) {
  fs.copyFileSync(path.join(serverRoot, name), path.join(destination, name));
  fs.chmodSync(path.join(destination, name), 0o700);
}

function writeExecutable(filePath, contents) {
  fs.writeFileSync(filePath, contents, {mode: 0o700});
}

function writeRuntimeScripts(root, failVerify = false) {
  writeExecutable(
    path.join(root, 'start-yappa.sh'),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'start %s\\n' "$(basename -- "$(dirname -- "$0")")" >> "$YAPPA_TEST_LOG"
`,
  );
  writeExecutable(
    path.join(root, 'verify-yappa-install.sh'),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'verify %s\\n' "$(basename -- "$(dirname -- "$0")")" >> "$YAPPA_TEST_LOG"
${failVerify ? 'exit 41' : 'exit 0'}
`,
  );
  writeExecutable(
    path.join(root, 'backup-yappa.sh'),
    `#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ "$1" == /* && ! -e "$1" ]]
printf 'encrypted fixture\\n' > "$1"
chmod 600 "$1"
printf 'backup %s\\n' "$(basename -- "$(dirname -- "$0")")" >> "$YAPPA_TEST_LOG"
`,
  );
  writeExecutable(
    path.join(root, 'verify-yappa-backup.sh'),
    `#!/usr/bin/env bash
set -euo pipefail
[[ -f "$1" ]]
printf 'verify-backup %s\\n' "$(basename -- "$(dirname -- "$0")")" >> "$YAPPA_TEST_LOG"
`,
  );
}

function makeCurrentInstallation(name) {
  const root = path.join(temporaryRoot, name);
  fs.mkdirSync(path.join(root, 'data'), {recursive: true});
  for (const script of [
    'install-yappa.sh',
    'upgrade-yappa.sh',
    'rollback-yappa.sh',
  ]) {
    copyExecutable(script, root);
  }
  fs.copyFileSync(
    path.join(serverRoot, 'install-manifest.json'),
    path.join(root, 'install-manifest.json'),
  );
  fs.writeFileSync(path.join(root, '.env'), 'DB_PATH=./data/yappa.db\n');
  fs.writeFileSync(path.join(root, 'runtime-version'), 'old\n');
  fs.mkdirSync(path.join(root, '.yappa-host-state'));
  fs.chmodSync(path.join(root, '.yappa-host-state'), 0o700);
  fs.writeFileSync(
    path.join(root, '.yappa-host-state', 'service-registration'),
    'test.service\n',
    {mode: 0o600},
  );
  const database = new Database(path.join(root, 'data', 'yappa.db'));
  database.exec(`
    CREATE TABLE schema_migrations (version INTEGER NOT NULL);
    INSERT INTO schema_migrations (version) VALUES (3);
    CREATE TABLE messages (content TEXT);
    INSERT INTO messages (content) VALUES ('preserved');
  `);
  database.close();
  writeRuntimeScripts(root);
  return root;
}

function makeBundle(name, failVerify = false) {
  const version = `0.1.0-${name}`;
  const source = path.join(temporaryRoot, `${name}-bundle-source`);
  const root = path.join(source, `yappa-server-${version}`);
  fs.mkdirSync(root, {recursive: true});
  for (const script of [
    'install-yappa.sh',
    'upgrade-yappa.sh',
    'rollback-yappa.sh',
  ]) {
    copyExecutable(script, root);
  }
  fs.copyFileSync(
    path.join(serverRoot, 'install-manifest.json'),
    path.join(root, 'install-manifest.json'),
  );
  fs.writeFileSync(
    path.join(root, 'BUILD-METADATA.json'),
    `{\n  "version": "${version}"\n}\n`,
  );
  fs.writeFileSync(path.join(root, 'runtime-version'), `${name}\n`);
  writeRuntimeScripts(root, failVerify);
  const archive = path.join(temporaryRoot, `yappa-server-${version}.tar.gz`);
  const archived = spawnSync(
    'tar',
    ['-czf', archive, '-C', source, path.basename(root)],
    {encoding: 'utf8'},
  );
  assert.equal(archived.status, 0, archived.stderr);
  return {
    archive,
    digest: crypto
      .createHash('sha256')
      .update(fs.readFileSync(archive))
      .digest('hex'),
  };
}

function lifecycle(root, args) {
  return spawnSync(path.join(root, 'install-yappa.sh'), args, {
    cwd: root,
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${binRoot}:${process.env.PATH}`,
      YAPPA_TEST_LOG: logPath,
    },
  });
}

try {
  fs.mkdirSync(binRoot);
  writeExecutable(
    path.join(binRoot, 'docker'),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\\n' "$*" >> "$YAPPA_TEST_LOG"
`,
  );

  const successfulRoot = makeCurrentInstallation('successful');
  const successfulBundle = makeBundle('new');
  const upgradeBackup = path.join(temporaryRoot, 'pre-upgrade.age');
  const upgraded = lifecycle(successfulRoot, [
    'upgrade',
    '--local-bundle',
    successfulBundle.archive,
    '--sha256',
    successfulBundle.digest,
    '--backup',
    upgradeBackup,
  ]);
  assert.equal(upgraded.status, 0, upgraded.stderr || upgraded.stdout);
  assert.match(upgraded.stdout, /passed operational verification/);
  assert.equal(
    fs.readFileSync(path.join(successfulRoot, 'runtime-version'), 'utf8'),
    'new\n',
  );
  assert.equal(
    fs.readFileSync(
      path.join(
        successfulRoot,
        '.yappa-host-state',
        'service-registration',
      ),
      'utf8',
    ),
    'test.service\n',
  );
  assert.equal(
    fs.readFileSync(
      path.join(temporaryRoot, 'successful.rollback', 'runtime-version'),
      'utf8',
    ),
    'old\n',
  );
  const upgradedDatabase = new Database(
    path.join(successfulRoot, 'data', 'yappa.db'),
    {readonly: true},
  );
  assert.equal(
    upgradedDatabase.prepare('SELECT content FROM messages').pluck().get(),
    'preserved',
  );
  upgradedDatabase.close();
  assert.equal(fs.statSync(upgradeBackup).mode & 0o777, 0o600);

  const rollbackBackup = path.join(temporaryRoot, 'pre-rollback.age');
  const rolledBack = lifecycle(successfulRoot, [
    'rollback',
    '--backup',
    rollbackBackup,
  ]);
  assert.equal(rolledBack.status, 0, rolledBack.stderr || rolledBack.stdout);
  assert.match(rolledBack.stdout, /rollback completed/i);
  assert.equal(
    fs.readFileSync(path.join(successfulRoot, 'runtime-version'), 'utf8'),
    'old\n',
  );
  assert.equal(
    fs.readFileSync(
      path.join(temporaryRoot, 'successful.pre-rollback', 'runtime-version'),
      'utf8',
    ),
    'new\n',
  );

  const failureRoot = makeCurrentInstallation('failure');
  const failureBundle = makeBundle('broken', true);
  const failureBackup = path.join(temporaryRoot, 'failed-upgrade.age');
  const failed = lifecycle(failureRoot, [
    'upgrade',
    '--local-bundle',
    failureBundle.archive,
    '--sha256',
    failureBundle.digest,
    '--backup',
    failureBackup,
  ]);
  assert.notEqual(failed.status, 0);
  assert.match(failed.stderr, /previous installation was restored/);
  assert.equal(
    fs.readFileSync(path.join(failureRoot, 'runtime-version'), 'utf8'),
    'old\n',
  );
  assert.equal(
    fs.readFileSync(
      path.join(temporaryRoot, 'failure.failed-upgrade', 'runtime-version'),
      'utf8',
    ),
    'broken\n',
  );
  assert.equal(fs.existsSync(path.join(temporaryRoot, 'failure.rollback')), false);

  const log = fs.readFileSync(logPath, 'utf8');
  assert.match(log, /backup successful/);
  assert.match(log, /verify-backup successful/);
  assert.match(log, /start successful/);
  assert.match(log, /verify successful/);
  assert.match(log, /verify failure/);
} finally {
  fs.rmSync(temporaryRoot, {recursive: true, force: true});
}

process.stdout.write('Transactional upgrade and rollback test passed.\n');
