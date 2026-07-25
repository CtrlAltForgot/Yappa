const assert = require('assert');
const fs = require('fs');
const path = require('path');

const serverRoot = path.resolve(__dirname, '..');
const repositoryRoot = path.resolve(serverRoot, '..');
const desktopWorkflow = fs.readFileSync(
  path.join(repositoryRoot, '.github', 'workflows', 'build_desktop.yml'),
  'utf8',
);
const startup = fs.readFileSync(path.join(serverRoot, 'start-yappa.sh'), 'utf8');
const domainSetup = fs.readFileSync(
  path.join(serverRoot, 'setup-domain.sh'),
  'utf8',
);
const backup = fs.readFileSync(
  path.join(serverRoot, 'backup-yappa.sh'),
  'utf8',
);
const restoreVerifier = fs.readFileSync(
  path.join(serverRoot, 'verify-yappa-backup.sh'),
  'utf8',
);
const compose = fs.readFileSync(
  path.join(serverRoot, 'docker-compose.yml'),
  'utf8',
);
const caddy = fs.readFileSync(path.join(serverRoot, 'Caddyfile'), 'utf8');
const clientApi = fs.readFileSync(
  path.join(repositoryRoot, 'client', 'lib', 'data', 'api_client.dart'),
  'utf8',
);
const clientServerModel = fs.readFileSync(
  path.join(repositoryRoot, 'client', 'lib', 'models', 'server_model.dart'),
  'utf8',
);
const linuxCmake = fs.readFileSync(
  path.join(repositoryRoot, 'client', 'linux', 'CMakeLists.txt'),
  'utf8',
);
const windowsCmake = fs.readFileSync(
  path.join(repositoryRoot, 'client', 'windows', 'CMakeLists.txt'),
  'utf8',
);
const macosMlsBuild = fs.readFileSync(
  path.join(repositoryRoot, 'client', 'macos', 'build_yappa_mls.sh'),
  'utf8',
);
const macosReleaseEntitlements = fs.readFileSync(
  path.join(
    repositoryRoot,
    'client',
    'macos',
    'Runner',
    'Release.entitlements',
  ),
  'utf8',
);
const mlsNativeClient = fs.readFileSync(
  path.join(repositoryRoot, 'client', 'lib', 'data', 'mls_native.dart'),
  'utf8',
);
const dockerfile = fs.readFileSync(
  path.join(serverRoot, 'Dockerfile'),
  'utf8',
);
const dockerIgnore = fs.readFileSync(
  path.join(serverRoot, '.dockerignore'),
  'utf8',
);
const ignore = fs.readFileSync(path.join(serverRoot, '.gitignore'), 'utf8');
const serverSource = fs.readFileSync(
  path.join(serverRoot, 'src', 'server.js'),
  'utf8',
);

for (const [name, script] of [
  ['start-yappa.sh', startup],
  ['setup-domain.sh', domainSetup],
  ['backup-yappa.sh', backup],
  ['verify-yappa-backup.sh', restoreVerifier],
]) {
  assert.match(script, /^umask 077$/m, `${name} must create private files`);
}
for (const [name, script] of [
  ['start-yappa.sh', startup],
  ['setup-domain.sh', domainSetup],
]) {
  assert.match(script, /chmod 600 \.env/, `${name} must protect existing .env`);
}

assert.match(startup, /chmod 600 livekit\.yaml/);
assert.match(startup, /chown -R 1000:1000 data/);
assert.match(startup, /chmod 700 data/);
assert.match(
  startup,
  /set_env_value BACKEND_BIND_ADDRESS "127\.0\.0\.1"/,
  'Startup must migrate raw backend publication to host loopback.',
);
assert.match(restoreVerifier, /"\$AGE_BIN" --decrypt/);
assert.match(restoreVerifier, /"\$SCRIPT_ROOT\/bin\/age"/);
assert.match(restoreVerifier, /PRAGMA quick_check/);
assert.match(restoreVerifier, /server-identity\.json/);
assert.match(restoreVerifier, /rm -rf -- "\$RESTORE_ROOT"/);
assert.match(startup, /Public join address: \$\{YAPPA_ADVERTISED_ADDRESS\}/);
assert.match(
  startup,
  /if \[\[ "\$\{YAPPA_ADVERTISED_ADDRESS:-\}" != "\$CURRENT_PUBLIC_IP" \]\]; then/,
  'Existing automatic-IP installs must migrate the advertised address.',
);
assert.doesNotMatch(
  startup,
  /Public client address: https:\/\/\$\{YAPPA_SITE_ADDRESS\}/,
);
assert.match(
  startup,
  /Router port forwarding \(external -> internal\):/,
);
assert.match(startup, /turn:\s*\n\s+enabled: true\s*\n\s+udp_port:/);
assert.match(
  startup,
  /UDP \$\{LIVEKIT_TURN_UDP_PORT:-443\} -> \$\{LIVEKIT_TURN_UDP_PORT:-443\} \(voice fallback\)/,
);
assert.match(domainSetup, /if \[\[ \$# -ne 1 \]\]; then/);
assert.match(domainSetup, /set_env_value LIVEKIT_SITE_ADDRESS "\$YAPPA_DOMAIN"/);
assert.match(domainSetup, /set_env_value LIVEKIT_URL "wss:\/\/\$\{YAPPA_DOMAIN\}"/);
assert.match(caddy, /@livekit path \/rtc\*/);
assert.match(caddy, /reverse_proxy @livekit host\.docker\.internal:7880/);
const retiredWildcardDnsService = ['ss', 'lip.io'].join('');
for (const [name, content] of [
  ['start-yappa.sh', startup],
  ['setup-domain.sh', domainSetup],
  ['Caddyfile', caddy],
  ['client ApiClient', clientApi],
  ['client server model', clientServerModel],
]) {
  assert.equal(
    content.toLowerCase().includes(retiredWildcardDnsService),
    false,
    `${name} must not retain the retired wildcard-DNS transport.`,
  );
}

assert.match(
  compose,
  /\$\{BACKEND_BIND_ADDRESS:-127\.0\.0\.1\}:\$\{PORT:-4100\}:4100/,
);
assert.match(compose, /LISTEN_HOST:\s*["']0\.0\.0\.0["']/);
assert.match(compose, /127\.0\.0\.1:41201:41200\/udp/);
assert.doesNotMatch(compose, /-\s*["']?41200:41200\/udp/);
assert.match(compose, /yappa-discovery:[\s\S]*network_mode:\s*host/);
assert.doesNotMatch(compose, /-\s*["']?4100:4100/);
assert.doesNotMatch(compose, /-\s*["']?7880:7880/);
assert.doesNotMatch(
  compose,
  /\$\{YAPPA_HTTPS_PORT:-443\}:443\/udp/,
  'UDP 443 must remain available to the authenticated LiveKit TURN fallback.',
);
assert.match(compose, /user:\s*["']1000:1000["']/);
assert.equal(
  (compose.match(/read_only:\s*true/g) || []).length,
  4,
  'Every production container must have a read-only root filesystem.',
);
assert.equal(
  (compose.match(/no-new-privileges:true/g) || []).length,
  4,
  'Every production container must forbid privilege escalation.',
);
assert.equal(
  (compose.match(/cap_drop:\s*\n\s+- ALL/g) || []).length,
  4,
  'Every production container must drop default Linux capabilities.',
);
assert.match(compose, /\/tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777/);
assert.match(dockerfile, /npm ci --omit=dev/);
assert.doesNotMatch(dockerfile, /npm install/);
assert.match(dockerfile, /^USER node$/m);
assert.match(dockerfile, /^HEALTHCHECK /m);
assert.match(dockerfile, /^CMD \["node", "src\/server\.js"\]$/m);
for (const ignored of [
  '.env',
  'data',
  'livekit.yaml',
  'node_modules',
  '*.age',
  '*.db',
]) {
  assert.match(
    dockerIgnore,
    new RegExp(`^${ignored.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`, 'm'),
    `Docker build context must exclude ${ignored}`,
  );
}
assert.match(ignore, /^\.env$/m);
assert.match(ignore, /^livekit\.yaml$/m);
assert.match(
  serverSource,
  /const CORS_ORIGIN = process\.env\.CORS_ORIGIN \?\? '';/,
  'Direct backend startup must default to native-only browser CORS.',
);
assert.match(
  serverSource,
  /const LISTEN_HOST = String\(process\.env\.LISTEN_HOST \|\| '127\.0\.0\.1'\)/,
  'Direct backend startup must bind loopback unless explicitly configured.',
);
assert.match(serverSource, /httpServer\.listen\(PORT, LISTEN_HOST,/);
assert.match(serverSource, /app\.disable\('x-powered-by'\)/);
assert.doesNotMatch(
  serverSource,
  /const CORS_ORIGIN = process\.env\.CORS_ORIGIN \?\? '\*';/,
);
assert.equal(
  fs.existsSync(path.join(serverRoot, 'livekit.yaml')),
  false,
  'Generated LiveKit credentials must not be stored in the repository.',
);
assert.match(desktopWorkflow, /libsodium-1\.0\.20-msvc\.zip/);
assert.match(
  desktopWorkflow,
  /2ff97f9e3f5b341bdc808e698057bea1ae454f99e29ff6f9b62e14d0eb1b1baa/,
  'The Windows libsodium runtime must be verified against its pinned digest.',
);
assert.match(desktopWorkflow, /YAPPA_SODIUM_DLL=/);
assert.match(desktopWorkflow, /"yappa_mls\.dll"/);
assert.match(desktopWorkflow, /"libsodium\.dll"/);
assert.match(desktopWorkflow, /name: Smoke-test Windows startup/);
assert.match(desktopWorkflow, /Start-Process -FilePath \$executable -PassThru/);
assert.match(
  desktopWorkflow,
  /--split-debug-info=build\/windows-symbols/,
);
assert.match(
  desktopWorkflow,
  /Forbidden builder path, secret, or retired transport marker in Windows bundle/,
);
assert.match(desktopWorkflow, /\[Text\.Encoding\]::Latin1\.GetString/);
assert.match(
  windowsCmake,
  /--remap-path-prefix=\$ENV\{USERPROFILE\}=\/_yappa_build_home/,
  'Native Windows Rust diagnostics must not identify the release builder.',
);
assert.match(desktopWorkflow, /name: Validate Linux bundle isolation/);
assert.match(desktopWorkflow, /readelf -d "\$file"/);
assert.match(desktopWorkflow, /ldd "\$library"/);
assert.match(desktopWorkflow, /--split-debug-info=build\/linux-symbols/);
assert.match(
  desktopWorkflow,
  /\/tmp\/yappa-release-source-\$\{GITHUB_RUN_ID\}-\$\{GITHUB_RUN_ATTEMPT\}/,
);
assert.match(desktopWorkflow, /Builder home path found in Linux bundle/);
assert.match(linuxCmake, /BUILD_WITH_INSTALL_RPATH TRUE/);
assert.match(linuxCmake, /BUILD_RPATH "\\\$ORIGIN"/);
assert.match(linuxCmake, /INSTALL_RPATH "\\\$ORIGIN"/);
assert.match(linuxCmake, /INSTALL_RPATH_USE_LINK_PATH FALSE/);
assert.match(
  linuxCmake,
  /--remap-path-prefix=\$ENV\{HOME\}=\/_yappa_build_home/,
  'Native Rust diagnostics must not identify the release builder home.',
);
assert.match(mlsNativeClient, /Platform\.isMacOS/);
assert.match(mlsNativeClient, /libyappa_mls\.dylib/);
assert.match(macosMlsBuild, /cargo build/);
assert.match(macosMlsBuild, /--locked/);
assert.match(macosMlsBuild, /libyappa_mls\.dylib/);
assert.match(macosMlsBuild, /codesign --force --sign -/);
for (const entitlement of [
  'com.apple.security.app-sandbox',
  'com.apple.security.network.client',
  'com.apple.security.device.audio-input',
  'com.apple.security.device.camera',
]) {
  assert.match(
    macosReleaseEntitlements,
    new RegExp(`<key>${entitlement.replaceAll('.', '\\.')}</key>`),
    `macOS release must declare ${entitlement}.`,
  );
}
assert.match(desktopWorkflow, /name: Verify macOS runtime bundle/);
assert.match(desktopWorkflow, /libyappa_mls\.dylib/);
assert.match(desktopWorkflow, /codesign --verify --deep --strict/);
assert.match(
  desktopWorkflow,
  /\/tmp\/yappa-macos-release-source-\$\{GITHUB_RUN_ID\}-\$\{GITHUB_RUN_ATTEMPT\}/,
);
assert.match(desktopWorkflow, /--split-debug-info=build\/macos-symbols/);
assert.match(desktopWorkflow, /otool -l "\$binary"/);
assert.match(
  desktopWorkflow,
  /Absolute build path found in macOS runtime search metadata/,
);
assert.match(desktopWorkflow, /name: Smoke-test macOS startup/);
assert.equal(
  (
    desktopWorkflow.match(
      /client\/native\/yappa_mls\/scripts\/test_openmls_vectors\.sh/g,
    ) || []
  ).length,
  3,
  'Every desktop artifact must run the pinned OpenMLS vectors.',
);

assert.match(backup, /docker compose stop newchat-node/);
assert.match(backup, /docker compose start newchat-node/);
assert.match(
  backup,
  /\| "\$AGE_BIN" --passphrase --output "\$TEMP_TARGET"/,
);
assert.match(backup, /"\$ROOT_DIR\/bin\/age"/);
assert.match(backup, /Refusing to overwrite existing backup/);
assert.match(backup, /\.env\s+\\\n\s+data\s+\\\n\s+\| "\$AGE_BIN"/);
assert.match(backup, /--file=-/);

process.stdout.write('Deployment safety test passed.\n');
