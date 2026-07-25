const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const Database = require('better-sqlite3');

const serverRoot = path.resolve(__dirname, '..');
const sourceScript = path.join(serverRoot, 'backup-yappa.sh');
const sourceVerifier = path.join(serverRoot, 'verify-yappa-backup.sh');
const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'yappa-backup-test-'));

function writeExecutable(filePath, contents) {
  fs.writeFileSync(filePath, contents, { mode: 0o700 });
}

function makeInstallation(name) {
  const root = path.join(tempRoot, name);
  const bin = path.join(root, 'test-bin');
  fs.mkdirSync(path.join(root, 'data', 'attachments'), { recursive: true });
  fs.mkdirSync(bin);
  fs.copyFileSync(sourceScript, path.join(root, 'backup-yappa.sh'));
  fs.chmodSync(path.join(root, 'backup-yappa.sh'), 0o700);
  fs.copyFileSync(sourceVerifier, path.join(root, 'verify-yappa-backup.sh'));
  fs.chmodSync(path.join(root, 'verify-yappa-backup.sh'), 0o700);
  fs.writeFileSync(path.join(root, '.env'), 'SESSION_SECRET=test-only\n');
  const database = new Database(path.join(root, 'data', 'yappa.db'));
  database.exec(`
    CREATE TABLE schema_migrations (version INTEGER NOT NULL);
    INSERT INTO schema_migrations (version) VALUES (3);
    CREATE TABLE users (id INTEGER PRIMARY KEY);
    INSERT INTO users DEFAULT VALUES;
    CREATE TABLE messages (id INTEGER PRIMARY KEY);
    INSERT INTO messages DEFAULT VALUES;
  `);
  database.close();
  fs.mkdirSync(path.join(root, 'data', 'servers', 'server-id'), {
    recursive: true,
  });
  fs.writeFileSync(
    path.join(
      root,
      'data',
      'servers',
      'server-id',
      'server-identity.json',
    ),
    '{"test":"public fixture"}\n',
  );
  fs.writeFileSync(
    path.join(root, 'data', 'attachments', 'example.bin'),
    'attachment bytes\n',
  );

  writeExecutable(
    path.join(bin, 'docker'),
    `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "inspect" ]]; then
  printf 'true\\n'
  exit 0
fi
printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
`,
  );
  writeExecutable(
    path.join(bin, 'age'),
    `#!/usr/bin/env bash
set -euo pipefail
output=''
input=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    --decrypt)
      input="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
if [[ -n "$input" ]]; then
  cat "$input"
  exit 0
fi
if [[ "\${FAKE_AGE_FAIL:-false}" == "true" ]]; then
  printf 'simulated encryption failure\\n' >&2
  exit 23
fi
test -n "$output"
cp /dev/stdin "$output"
`,
  );

  return { root, bin, log: path.join(root, 'docker.log') };
}

function runBackup(installation, target, extraEnv = {}) {
  return spawnSync(
    path.join(installation.root, 'backup-yappa.sh'),
    [target],
    {
      cwd: installation.root,
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${installation.bin}:${process.env.PATH}`,
        FAKE_DOCKER_LOG: installation.log,
        ...extraEnv,
      },
    },
  );
}

try {
  const successful = makeInstallation('success');
  const target = path.join(successful.root, 'backup.tar.gz.age');
  const result = runBackup(successful, target);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.equal(fs.existsSync(target), true);
  assert.equal(fs.existsSync(`${target}.partial`), false);
  assert.equal(fs.statSync(target).mode & 0o777, 0o600);
  assert.deepEqual(
    fs.readFileSync(successful.log, 'utf8').trim().split('\n'),
    ['compose stop newchat-node', 'compose start newchat-node'],
  );

  const listing = spawnSync('tar', ['--list', '--gzip', '--file', target], {
    encoding: 'utf8',
  });
  assert.equal(listing.status, 0, listing.stderr);
  assert.match(listing.stdout, /^\.env$/m);
  assert.match(listing.stdout, /^data\/yappa\.db$/m);
  assert.match(listing.stdout, /^data\/attachments\/example\.bin$/m);
  assert.match(listing.stdout, /server-identity\.json$/m);

  const restoreTemp = path.join(successful.root, 'restore-temp');
  fs.mkdirSync(restoreTemp);
  const verified = spawnSync(
    path.join(successful.root, 'verify-yappa-backup.sh'),
    [target],
    {
      cwd: successful.root,
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${successful.bin}:${process.env.PATH}`,
        TMPDIR: restoreTemp,
      },
    },
  );
  assert.equal(verified.status, 0, verified.stderr || verified.stdout);
  assert.match(verified.stdout, /restore verification passed/);
  assert.match(verified.stdout, /Schema version: 3/);
  assert.match(verified.stdout, /Users: 1/);
  assert.deepEqual(fs.readdirSync(restoreTemp), []);

  const refused = runBackup(successful, target);
  assert.notEqual(refused.status, 0);
  assert.match(refused.stdout, /Refusing to overwrite existing backup/);

  const failed = makeInstallation('failure');
  const failedTarget = path.join(failed.root, 'failed.tar.gz.age');
  const failedResult = runBackup(failed, failedTarget, {
    FAKE_AGE_FAIL: 'true',
  });
  assert.notEqual(failedResult.status, 0);
  assert.equal(fs.existsSync(failedTarget), false);
  assert.equal(fs.existsSync(`${failedTarget}.partial`), false);
  assert.deepEqual(
    fs.readFileSync(failed.log, 'utf8').trim().split('\n'),
    ['compose stop newchat-node', 'compose start newchat-node'],
  );
} finally {
  fs.rmSync(tempRoot, { recursive: true, force: true });
}

process.stdout.write('Backup orchestration integration test passed.\n');
