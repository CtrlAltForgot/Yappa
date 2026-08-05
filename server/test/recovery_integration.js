const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {spawnSync} = require('child_process');

const serverRoot = path.resolve(__dirname, '..');
const temporaryRoot = fs.mkdtempSync(
  path.join(os.tmpdir(), 'yappa-recovery-test-'),
);
const installation = path.join(temporaryRoot, 'server');
const binRoot = path.join(temporaryRoot, 'bin');
const dockerState = path.join(temporaryRoot, 'docker.state');
const dockerLog = path.join(temporaryRoot, 'docker.log');

function setDesiredState(state) {
  fs.writeFileSync(
    path.join(installation, '.yappa-host-state', 'desired-state'),
    `${state}\n`,
    {mode: 0o600},
  );
}

function run(extraEnv = {}) {
  return spawnSync(path.join(installation, 'recover-yappa.sh'), [], {
    cwd: installation,
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${binRoot}:${process.env.PATH}`,
      DOCKER_STATE: dockerState,
      DOCKER_LOG: dockerLog,
      ...extraEnv,
    },
  });
}

try {
  fs.mkdirSync(path.join(installation, '.yappa-host-state'), {
    recursive: true,
    mode: 0o700,
  });
  fs.mkdirSync(binRoot);
  fs.copyFileSync(
    path.join(serverRoot, 'recover-yappa.sh'),
    path.join(installation, 'recover-yappa.sh'),
  );
  fs.chmodSync(path.join(installation, 'recover-yappa.sh'), 0o700);
  fs.writeFileSync(dockerState, 'healthy\n');
  fs.writeFileSync(dockerLog, '');
  fs.writeFileSync(
    path.join(binRoot, 'docker'),
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$DOCKER_LOG"
state="$(cat "$DOCKER_STATE")"
if [[ "$*" == *"ps --status running --services"* ]]; then
  if [[ "$state" == "healthy" ]]; then
    printf '%s\\n' newchat-node yappa-discovery yappa-livekit yappa-proxy
  else
    printf '%s\\n' yappa-proxy
  fi
elif [[ "\${1:-}" == "inspect" ]]; then
  [[ "$state" == "healthy" ]] && printf 'healthy\\n' || printf 'unhealthy\\n'
elif [[ "$*" == *"up -d"* &&
  "\${RECOVERY_SHOULD_SUCCEED:-false}" == "true" ]]; then
  printf 'healthy\\n' > "$DOCKER_STATE"
fi
`,
    {mode: 0o700},
  );
  fs.writeFileSync(
    path.join(binRoot, 'sleep'),
    '#!/usr/bin/env bash\nexit 0\n',
    {mode: 0o700},
  );
  fs.writeFileSync(
    path.join(installation, 'verify-yappa-install.sh'),
    `#!/usr/bin/env bash
set -euo pipefail
[[ "\${FORCE_VERIFY_FAIL:-false}" != "true" ]]
[[ "$(cat "$DOCKER_STATE")" == "healthy" ]]
`,
    {mode: 0o700},
  );

  setDesiredState('stopped');
  const stopped = run();
  assert.equal(stopped.status, 0, stopped.stderr);
  assert.match(stopped.stdout, /intentionally stopped/);
  assert.equal(fs.readFileSync(dockerLog, 'utf8'), '');

  setDesiredState('running');
  const healthy = run();
  assert.equal(healthy.status, 0, healthy.stderr);
  assert.match(healthy.stdout, /healthy; recovery did nothing/);
  assert.doesNotMatch(fs.readFileSync(dockerLog, 'utf8'), /up -d/);

  fs.writeFileSync(dockerState, 'degraded\n');
  const recovered = run({RECOVERY_SHOULD_SUCCEED: 'true'});
  assert.equal(recovered.status, 0, recovered.stderr || recovered.stdout);
  assert.match(recovered.stdout, /recovery completed/);
  assert.match(fs.readFileSync(dockerLog, 'utf8'), /up -d/);
  assert.equal(
    fs.existsSync(
      path.join(installation, '.yappa-host-state', 'recovery-state'),
    ),
    false,
  );

  fs.writeFileSync(dockerState, 'degraded\n');
  fs.writeFileSync(dockerLog, '');
  for (let failure = 1; failure <= 3; failure += 1) {
    const failed = run({FORCE_VERIFY_FAIL: 'true'});
    assert.notEqual(failed.status, 0);
    assert.match(failed.stderr, /failed operational verification/);
  }
  const recoveryState = fs.readFileSync(
    path.join(installation, '.yappa-host-state', 'recovery-state'),
    'utf8',
  );
  assert.match(recoveryState, /^failures=3$/m);
  assert.match(recoveryState, /^last_failure=[0-9]+$/m);
  const attemptsBeforeCooldown = (
    fs.readFileSync(dockerLog, 'utf8').match(/up -d/g) || []
  ).length;
  const cooledDown = run({FORCE_VERIFY_FAIL: 'true'});
  assert.notEqual(cooledDown.status, 0);
  assert.match(cooledDown.stderr, /cooling down/);
  const attemptsAfterCooldown = (
    fs.readFileSync(dockerLog, 'utf8').match(/up -d/g) || []
  ).length;
  assert.equal(attemptsAfterCooldown, attemptsBeforeCooldown);
} finally {
  fs.rmSync(temporaryRoot, {recursive: true, force: true});
}

process.stdout.write('Bounded desired-state recovery test passed.\n');
