const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {spawnSync} = require('child_process');

const serverRoot = path.resolve(__dirname, '..');
const temporaryRoot = fs.mkdtempSync(
  path.join(os.tmpdir(), 'yappa-service-test-'),
);
const homeRoot = path.join(temporaryRoot, 'home');
const binRoot = path.join(temporaryRoot, 'bin');
const installation = path.join(temporaryRoot, 'Yappa Server');
const systemctlLog = path.join(temporaryRoot, 'systemctl.log');

function writeExecutable(filePath, contents) {
  fs.writeFileSync(filePath, contents, {mode: 0o700});
}

function run(action, extraEnv = {}) {
  return spawnSync(path.join(installation, 'service-yappa.sh'), [action], {
    cwd: installation,
    encoding: 'utf8',
    env: {
      ...process.env,
      HOME: homeRoot,
      XDG_CONFIG_HOME: path.join(homeRoot, '.config'),
      PATH: `${binRoot}:${process.env.PATH}`,
      SYSTEMCTL_LOG: systemctlLog,
      ...extraEnv,
    },
  });
}

try {
  assert.notEqual(
    process.getuid?.(),
    0,
    'Service integration must run as an unprivileged CI user.',
  );
  fs.mkdirSync(path.join(installation, 'data'), {recursive: true});
  fs.mkdirSync(binRoot);
  fs.mkdirSync(homeRoot);
  fs.copyFileSync(
    path.join(serverRoot, 'service-yappa.sh'),
    path.join(installation, 'service-yappa.sh'),
  );
  fs.chmodSync(path.join(installation, 'service-yappa.sh'), 0o700);
  fs.writeFileSync(path.join(installation, '.env'), 'DB_PATH=./data/yappa.db\n');
  writeExecutable(
    path.join(installation, 'install-yappa.sh'),
    '#!/usr/bin/env bash\nexit 0\n',
  );
  writeExecutable(
    path.join(binRoot, 'systemctl'),
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$SYSTEMCTL_LOG"
if [[ "\${SYSTEMCTL_FAIL_ENABLE:-false}" == "true" &&
  "$*" == *"enable --now"* ]]; then
  exit 27
fi
if [[ "$*" == *"status"* ]]; then
  printf 'active (exited)\\n'
fi
`,
  );

  const installed = run('install');
  assert.equal(installed.status, 0, installed.stderr || installed.stdout);
  assert.match(installed.stdout, /sign-in autostart enabled/);
  const registration = path.join(
    installation,
    '.yappa-host-state',
    'service-registration',
  );
  const unitName = fs.readFileSync(registration, 'utf8').trim();
  assert.match(unitName, /^yappa-server-[a-f0-9]{16}\.service$/);
  const unitPath = path.join(
    homeRoot,
    '.config',
    'systemd',
    'user',
    unitName,
  );
  const unit = fs.readFileSync(unitPath, 'utf8');
  assert.equal(fs.statSync(unitPath).mode & 0o777, 0o600);
  assert.equal(fs.statSync(registration).mode & 0o777, 0o600);
  assert.match(unit, /^Type=oneshot$/m);
  assert.match(unit, /^RemainAfterExit=yes$/m);
  assert.match(unit, /^NoNewPrivileges=yes$/m);
  assert.match(unit, /^PrivateTmp=yes$/m);
  assert.match(unit, /^UMask=0077$/m);
  assert.match(unit, /ExecStart=.*install-yappa\.sh" start$/m);
  assert.match(unit, /ExecStartPost=.*install-yappa\.sh" verify$/m);
  assert.match(unit, /ExecStop=.*install-yappa\.sh" stop$/m);
  assert.doesNotMatch(unit, /\.env|password|secret|token/i);

  const duplicate = run('install');
  assert.notEqual(duplicate.status, 0);
  assert.match(duplicate.stderr, /already has service registration/);

  const status = run('status');
  assert.equal(status.status, 0, status.stderr);
  assert.match(status.stdout, /active \(exited\)/);

  const removed = run('remove');
  assert.equal(removed.status, 0, removed.stderr || removed.stdout);
  assert.match(removed.stdout, /registration removed/);
  assert.equal(fs.existsSync(unitPath), false);
  assert.equal(fs.existsSync(registration), false);
  assert.equal(
    fs.existsSync(path.join(installation, '.yappa-host-state')),
    false,
  );
  assert.match(
    fs.readFileSync(systemctlLog, 'utf8'),
    /--user enable --now yappa-server-/,
  );
  assert.match(
    fs.readFileSync(systemctlLog, 'utf8'),
    /--user disable --now yappa-server-/,
  );

  const failed = run('install', {SYSTEMCTL_FAIL_ENABLE: 'true'});
  assert.notEqual(failed.status, 0);
  assert.match(failed.stderr, /registration failed and was removed/);
  assert.equal(fs.existsSync(unitPath), false);
  assert.equal(fs.existsSync(registration), false);
} finally {
  fs.rmSync(temporaryRoot, {recursive: true, force: true});
}

process.stdout.write('Explicit user-service lifecycle test passed.\n');
