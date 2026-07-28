const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {spawnSync} = require('child_process');

const serverRoot = path.resolve(__dirname, '..');
const temporaryRoot = fs.mkdtempSync(
  path.join(os.tmpdir(), 'yappa-uninstall-test-'),
);
const binRoot = path.join(temporaryRoot, 'bin');
const logPath = path.join(temporaryRoot, 'uninstall.log');

function writeExecutable(filePath, contents) {
  fs.writeFileSync(filePath, contents, {mode: 0o700});
}

function makeInstallation(name) {
  const root = path.join(temporaryRoot, name);
  fs.mkdirSync(path.join(root, 'data', 'attachments'), {recursive: true});
  for (const script of ['install-yappa.sh', 'uninstall-yappa.sh']) {
    fs.copyFileSync(path.join(serverRoot, script), path.join(root, script));
    fs.chmodSync(path.join(root, script), 0o700);
  }
  fs.copyFileSync(
    path.join(serverRoot, 'install-manifest.json'),
    path.join(root, 'install-manifest.json'),
  );
  fs.writeFileSync(path.join(root, '.env'), 'DB_PATH=./data/yappa.db\n', {
    mode: 0o600,
  });
  fs.writeFileSync(
    path.join(root, 'data', 'attachments', 'sentinel'),
    'preserve me\n',
  );
  fs.chmodSync(path.join(root, 'data'), 0o700);
  writeExecutable(
    path.join(root, 'start-yappa.sh'),
    '#!/usr/bin/env bash\nset -euo pipefail\nprintf "start\\n" >> "$YAPPA_TEST_LOG"\n',
  );
  writeExecutable(
    path.join(root, 'verify-yappa-install.sh'),
    '#!/usr/bin/env bash\nset -euo pipefail\nprintf "verify\\n" >> "$YAPPA_TEST_LOG"\n',
  );
  writeExecutable(
    path.join(root, 'backup-yappa.sh'),
    `#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == /* && ! -e "$1" ]]
printf 'encrypted fixture\\n' > "$1"
chmod 600 "$1"
printf 'backup\\n' >> "$YAPPA_TEST_LOG"
`,
  );
  writeExecutable(
    path.join(root, 'verify-yappa-backup.sh'),
    '#!/usr/bin/env bash\nset -euo pipefail\n[[ -f "$1" ]]\nprintf "verify-backup\\n" >> "$YAPPA_TEST_LOG"\n',
  );
  return root;
}

function uninstall(root, backup, preservation) {
  return spawnSync(
    path.join(root, 'install-yappa.sh'),
    [
      'uninstall',
      '--backup',
      backup,
      '--preserve-data',
      preservation,
    ],
    {
      cwd: root,
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${binRoot}:${process.env.PATH}`,
        YAPPA_TEST_LOG: logPath,
      },
    },
  );
}

try {
  fs.mkdirSync(binRoot);
  writeExecutable(
    path.join(binRoot, 'docker'),
    '#!/usr/bin/env bash\nset -euo pipefail\nprintf "stop\\n" >> "$YAPPA_TEST_LOG"\n',
  );

  const root = makeInstallation('server');
  const backup = path.join(temporaryRoot, 'pre-uninstall.age');
  const preservation = path.join(temporaryRoot, 'preserved-state');
  const result = uninstall(root, backup, preservation);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /runtime was uninstalled/);
  assert.equal(fs.existsSync(root), false);
  assert.equal(fs.statSync(backup).mode & 0o777, 0o600);
  assert.equal(fs.statSync(preservation).mode & 0o777, 0o700);
  assert.equal(
    fs.statSync(path.join(preservation, '.env')).mode & 0o777,
    0o600,
  );
  assert.equal(
    fs.readFileSync(
      path.join(preservation, 'data', 'attachments', 'sentinel'),
      'utf8',
    ),
    'preserve me\n',
  );

  const refusedRoot = makeInstallation('refused');
  const retained = `${refusedRoot}.rollback`;
  fs.mkdirSync(retained);
  const refusedBackup = path.join(temporaryRoot, 'refused.age');
  const refusedPreservation = path.join(temporaryRoot, 'refused-state');
  const refused = uninstall(
    refusedRoot,
    refusedBackup,
    refusedPreservation,
  );
  assert.notEqual(refused.status, 0);
  assert.match(refused.stderr, /Resolve the retained \.rollback/);
  assert.equal(fs.existsSync(refusedRoot), true);
  assert.equal(fs.existsSync(refusedBackup), false);
  assert.equal(fs.existsSync(refusedPreservation), false);

  const existingRoot = makeInstallation('existing-target');
  const existingPreservation = path.join(temporaryRoot, 'existing-state');
  fs.mkdirSync(existingPreservation);
  fs.writeFileSync(path.join(existingPreservation, 'sentinel'), 'unchanged\n');
  const existing = uninstall(
    existingRoot,
    path.join(temporaryRoot, 'existing.age'),
    existingPreservation,
  );
  assert.notEqual(existing.status, 0);
  assert.equal(fs.existsSync(existingRoot), true);
  assert.equal(
    fs.readFileSync(path.join(existingPreservation, 'sentinel'), 'utf8'),
    'unchanged\n',
  );

  assert.equal(
    fs
      .readdirSync(temporaryRoot)
      .some((entry) => entry.includes('.uninstalling')),
    false,
  );
  assert.match(
    fs.readFileSync(logPath, 'utf8'),
    /verify\nbackup\nverify-backup\nstop/,
  );
} finally {
  fs.rmSync(temporaryRoot, {recursive: true, force: true});
}

process.stdout.write('Data-preserving uninstall test passed.\n');
