const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {spawnSync} = require('child_process');

const serverRoot = path.resolve(__dirname, '..');
const temporaryRoot = fs.mkdtempSync(
  path.join(os.tmpdir(), 'yappa-firewall-test-'),
);
const installation = path.join(temporaryRoot, 'server');
const binRoot = path.join(temporaryRoot, 'bin');

function writeEnvironment(addressMode, overrides = '') {
  fs.writeFileSync(
    path.join(installation, '.env'),
    `YAPPA_ADDRESS_MODE=${addressMode}
YAPPA_HTTP_PORT=80
YAPPA_HTTPS_PORT=443
YAPPA_LIVEKIT_PROXY_PORT=7882
LIVEKIT_TCP_PORT=7881
LIVEKIT_TURN_UDP_PORT=443
LIVEKIT_UDP_PORT_RANGE_START=50000
LIVEKIT_UDP_PORT_RANGE_END=50100
${overrides}`,
  );
}

function run(args) {
  return spawnSync(path.join(installation, 'firewall-yappa.sh'), args, {
    cwd: installation,
    encoding: 'utf8',
  });
}

try {
  fs.mkdirSync(path.join(installation, 'data'), {recursive: true});
  fs.mkdirSync(binRoot);
  fs.copyFileSync(
    path.join(serverRoot, 'firewall-yappa.sh'),
    path.join(installation, 'firewall-yappa.sh'),
  );
  fs.chmodSync(path.join(installation, 'firewall-yappa.sh'), 0o700);

  writeEnvironment('automatic-ip');
  const publicPlan = run(['plan', 'ufw', '']);
  assert.equal(publicPlan.status, 0, publicPlan.stderr);
  assert.match(publicPlan.stdout, /TCP 80\s+source any/);
  assert.match(publicPlan.stdout, /TCP 443\s+source any/);
  assert.match(publicPlan.stdout, /UDP 443\s+source any/);
  assert.match(publicPlan.stdout, /TCP 7881\s+source any/);
  assert.match(publicPlan.stdout, /UDP 50000:50100\s+source any/);
  for (const forbidden of ['TCP 4100 ', 'TCP 7880 ', 'TCP 7882 ', 'UDP 41201 ']) {
    assert.equal(
      publicPlan.stdout
        .split('Rules to allow:')[1]
        .split('Raw backend')[0]
        .includes(forbidden),
      false,
      `Public plan must not allow ${forbidden.trim()}.`,
    );
  }

  const publicWithLan = run([
    'plan',
    'firewalld',
    '192.168.50.0/24',
  ]);
  assert.equal(publicWithLan.status, 0, publicWithLan.stderr);
  assert.match(
    publicWithLan.stdout,
    /UDP 41200\s+source 192\.168\.50\.0\/24/,
  );

  writeEnvironment('lan');
  const missingCidr = run(['plan', 'ufw', '']);
  assert.notEqual(missingCidr.status, 0);
  assert.match(missingCidr.stderr, /require --lan-cidr/);
  const lanPlan = run(['plan', 'ufw', '10.20.0.0/16']);
  assert.equal(lanPlan.status, 0, lanPlan.stderr);
  for (const expected of [
    /TCP 80\s+source 10\.20\.0\.0\/16/,
    /TCP 7882\s+source 10\.20\.0\.0\/16/,
    /TCP 7881\s+source 10\.20\.0\.0\/16/,
    /UDP 443\s+source 10\.20\.0\.0\/16/,
    /UDP 50000:50100\s+source 10\.20\.0\.0\/16/,
    /UDP 41200\s+source 10\.20\.0\.0\/16/,
  ]) {
    assert.match(lanPlan.stdout, expected);
  }

  const unsafeCidr = run(['plan', 'ufw', '999.1.1.0/24']);
  assert.notEqual(unsafeCidr.status, 0);
  assert.match(unsafeCidr.stderr, /explicit IPv4 CIDR/);

  writeEnvironment(
    'automatic-ip',
    'LIVEKIT_UDP_PORT_RANGE_START=50100\nLIVEKIT_UDP_PORT_RANGE_END=50000\n',
  );
  const reversed = run(['plan', 'ufw', '']);
  assert.notEqual(reversed.status, 0);
  assert.match(reversed.stderr, /range is reversed/);

  writeEnvironment('automatic-ip');
  const unprivilegedApply = run(['apply', 'ufw', '']);
  assert.notEqual(unprivilegedApply.status, 0);
  assert.match(unprivilegedApply.stderr, /launched explicitly as root/);
  assert.match(unprivilegedApply.stderr, /never invokes sudo/);
  assert.equal(
    fs.existsSync(
      path.join(
        installation,
        '.yappa-host-state',
        'firewall-registration',
      ),
    ),
    false,
  );

  const ufwState = path.join(temporaryRoot, 'ufw.state');
  const ufwLog = path.join(temporaryRoot, 'ufw.log');
  const namespaceVarLib = path.join(temporaryRoot, 'var-lib');
  fs.mkdirSync(namespaceVarLib);
  fs.writeFileSync(ufwState, '');
  fs.writeFileSync(
    path.join(binRoot, 'ufw'),
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$UFW_LOG"
if [[ "$*" == "status" ]]; then
  printf 'Status: active\\n'
elif [[ "$*" == "show added" ]]; then
  cat "$UFW_STATE"
elif [[ "\${1:-}" == "--force" && "\${2:-}" == "delete" ]]; then
  shift 2
  target="ufw $*"
  grep -Fxv "$target" "$UFW_STATE" > "$UFW_STATE.next" || true
  mv "$UFW_STATE.next" "$UFW_STATE"
else
  printf 'ufw %s\\n' "$*" >> "$UFW_STATE"
fi
`,
    {mode: 0o700},
  );
  const rootMutation = spawnSync(
    'unshare',
    [
      '-Urm',
      'sh',
      '-c',
      `
set -eu
mount --bind "$3" /var/lib
PATH="$2:$PATH"
export PATH UFW_LOG="$4" UFW_STATE="$5"
"$1/firewall-yappa.sh" apply ufw ""
test -f /var/lib/yappa/firewall-*
test -f "$1/.yappa-host-state/firewall-registration"
"$1/firewall-yappa.sh" remove
test ! -e "$1/.yappa-host-state/firewall-registration"
test ! -d /var/lib/yappa
test ! -s "$5"
`,
      'sh',
      installation,
      binRoot,
      namespaceVarLib,
      ufwLog,
      ufwState,
    ],
    {encoding: 'utf8'},
  );
  if (
    rootMutation.status !== 0 &&
    /uid_map: Operation not permitted/.test(rootMutation.stderr)
  ) {
    process.stdout.write(
      'Hosted kernel forbids unprivileged user namespaces; root firewall mutation fixture skipped.\n',
    );
  } else {
    assert.equal(
      rootMutation.status,
      0,
      rootMutation.stderr || rootMutation.stdout,
    );
    const mutationLog = fs.readFileSync(ufwLog, 'utf8');
    assert.match(mutationLog, /allow 80\/tcp/);
    assert.match(mutationLog, /allow 443\/udp/);
    assert.match(mutationLog, /allow 50000:50100\/udp/);
    assert.match(mutationLog, /--force delete allow 80\/tcp/);
  }
} finally {
  fs.rmSync(temporaryRoot, {recursive: true, force: true});
}

process.stdout.write(
  'Firewall plan, root mutation, removal, and privilege-boundary test passed.\n',
);
