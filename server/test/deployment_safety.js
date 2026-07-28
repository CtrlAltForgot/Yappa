const assert = require('assert');
const fs = require('fs');
const path = require('path');

const serverRoot = path.resolve(__dirname, '..');
const repositoryRoot = path.resolve(serverRoot, '..');
const workflowRoot = path.join(repositoryRoot, '.github', 'workflows');
const releaseScriptRoot = path.join(repositoryRoot, '.github', 'scripts');
const desktopWorkflowPaths = [
  'build_linux.yml',
  'build_windows.yml',
  'build_macos.yml',
].map((name) => path.join(workflowRoot, name));
const desktopWorkflows = desktopWorkflowPaths.map((workflowPath) =>
  fs.readFileSync(workflowPath, 'utf8'),
);
const desktopWorkflow = desktopWorkflows.join('\n');
const releaseVersions = fs.readFileSync(
  path.join(repositoryRoot, '.github', 'release-versions.json'),
  'utf8',
);
const releaseVersionManifest = JSON.parse(releaseVersions);
const rustToolchain = fs.readFileSync(
  path.join(repositoryRoot, 'rust-toolchain.toml'),
  'utf8',
);
const clientValidation = fs.readFileSync(
  path.join(releaseScriptRoot, 'validate-client.sh'),
  'utf8',
);
const linuxReleaseBuild = fs.readFileSync(
  path.join(releaseScriptRoot, 'build-linux.sh'),
  'utf8',
);
const windowsReleaseBuild = fs.readFileSync(
  path.join(releaseScriptRoot, 'build-windows.ps1'),
  'utf8',
);
const macosReleaseBuild = fs.readFileSync(
  path.join(releaseScriptRoot, 'build-macos.sh'),
  'utf8',
);
const macosSodiumInstall = fs.readFileSync(
  path.join(releaseScriptRoot, 'install-libsodium-macos.sh'),
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
assert.equal(releaseVersionManifest.yappa, '0.1.0-dev');
assert.equal(releaseVersionManifest.flutter, '3.44.7');
assert.equal(releaseVersionManifest.rust, '1.96.1');
assert.match(rustToolchain, /^channel = "1\.96\.1"$/m);
assert.equal(
  (rustToolchain.match(/^channel = /gm) || []).length,
  1,
  'The release-critical Rust toolchain must have one exact channel pin.',
);
assert.equal(releaseVersionManifest.libsodium.version, '1.0.20');
assert.equal(
  releaseVersionManifest.libsodium.sha256,
  '2ff97f9e3f5b341bdc808e698057bea1ae454f99e29ff6f9b62e14d0eb1b1baa',
  'The Windows libsodium runtime must be verified against its pinned digest.',
);
assert.match(
  releaseVersionManifest.libsodium.url,
  /libsodium-1\.0\.20-msvc\.zip$/,
);
assert.match(
  releaseVersionManifest.libsodium.sourceUrl,
  /libsodium-1\.0\.20\.tar\.gz$/,
);
assert.equal(
  releaseVersionManifest.libsodium.sourceSha256,
  'ebb65ef6ca439333c2bb41a0c1990587288da07f6c7fd07cb3a18cc18d30ce19',
  'The macOS libsodium source must be verified against its pinned digest.',
);
assert.match(windowsReleaseBuild, /"yappa_mls\.dll"/);
assert.match(windowsReleaseBuild, /"libsodium\.dll"/);
assert.match(windowsReleaseBuild, /Start-Process/);
assert.match(windowsReleaseBuild, /-FilePath \$executable/);
assert.match(windowsReleaseBuild, /-PassThru/);
assert.match(
  windowsReleaseBuild,
  /--split-debug-info=build\/windows-symbols/,
);
assert.match(
  windowsReleaseBuild,
  /Forbidden builder path, secret, or retired transport marker in [\s\S]*Windows bundle/,
);
assert.match(windowsReleaseBuild, /\[Text\.Encoding\]::Latin1\.GetString/);
assert.match(
  windowsReleaseBuild,
  /\(\?i:\[A-Z\]:\\\\Users\\\\\)\|\/Users\/\|\/home\//,
  'Windows user paths may be case-insensitive without treating /users/ API routes as macOS builder paths.',
);
assert.doesNotMatch(
  windowsReleaseBuild,
  /\(\?i\)\(\[A-Z\]:\\\\Users\\\\\|\/Users\//,
  'Do not make Unix builder-path checks globally case-insensitive.',
);
assert.match(
  windowsReleaseBuild,
  /\$env:PUB_CACHE = Join-Path \$temporaryRoot "yappa-neutral-pub-cache"/,
  'Windows release dependencies must not identify the runner account.',
);
assert.match(
  windowsCmake,
  /--remap-path-prefix=\$ENV\{USERPROFILE\}=\/_yappa_build_home/,
  'Native Windows Rust diagnostics must not identify the release builder.',
);
assert.match(
  windowsCmake,
  /target_compile_definitions\(\s*webview_all_windows_plugin[\s\S]*?_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS[\s\S]*?\)/,
  'The MSVC coroutine compatibility definition must target only the WebView plugin.',
);
assert.doesNotMatch(
  windowsCmake,
  /add_compile_definitions\([\s\S]*?_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS/,
  'Do not suppress experimental-coroutine diagnostics project-wide.',
);
assert.match(linuxReleaseBuild, /readelf -d "\$file"/);
assert.match(linuxReleaseBuild, /ldd "\$library"/);
assert.match(linuxReleaseBuild, /--split-debug-info=build\/linux-symbols/);
assert.match(
  linuxReleaseBuild,
  /mktemp -d "\$\{TMPDIR:-\/tmp\}\/yappa-linux-release\.XXXXXX"/,
);
assert.match(linuxReleaseBuild, /Builder home path found in Linux bundle/);
assert.match(
  linuxReleaseBuild,
  /export PUB_CACHE="\$release_source\/pub-cache"/,
);
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
assert.match(macosMlsBuild, /YAPPA_SODIUM_DYLIB/);
assert.match(macosMlsBuild, /libsodium\.dylib/);
assert.match(macosMlsBuild, /install_name_tool -id @rpath\/libsodium\.dylib/);
assert.match(macosSodiumInstall, /shasum -a 256/);
assert.match(macosSodiumInstall, /--disable-static/);
assert.match(macosSodiumInstall, /YAPPA_SODIUM_DYLIB=/);
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
assert.match(macosReleaseBuild, /libyappa_mls\.dylib/);
assert.match(macosReleaseBuild, /codesign --verify --deep --strict/);
assert.match(
  macosReleaseBuild,
  /mktemp -d "\$\{TMPDIR:-\/tmp\}\/yappa-macos-release\.XXXXXX"/,
);
assert.match(macosReleaseBuild, /--split-debug-info=build\/macos-symbols/);
assert.match(macosReleaseBuild, /otool -l "\$binary"/);
assert.match(
  macosReleaseBuild,
  /Absolute build path found in macOS runtime search metadata/,
);
assert.match(macosReleaseBuild, /sleep 8/);
assert.match(
  macosReleaseBuild,
  /export PUB_CACHE="\$release_source\/pub-cache"/,
);
assert.match(
  desktopWorkflows[2],
  /\.github\/scripts\/install-libsodium-macos\.sh/,
);
assert.match(
  clientValidation,
  /client\/native\/yappa_mls\/scripts\/test_openmls_vectors\.sh/,
);
for (const workflow of desktopWorkflows) {
  assert.match(
    workflow,
    /\.github\/scripts\/validate-client\.sh/,
    'Every desktop artifact workflow must run the shared client gate.',
  );
  assert.match(workflow, /persist-credentials: false/);
  assert.match(workflow, /permissions:\s*\n\s+contents: read/);
  assert.match(workflow, /if: \$\{\{ always\(\) \}\}/);
}
const securityWorkflow = fs.readFileSync(
  path.join(workflowRoot, 'security.yml'),
  'utf8',
);
assert.match(
  securityWorkflow,
  /\.github\/scripts\/validate-client\.sh/,
  'Security CI must use the same native/vector/Flutter gate as artifacts.',
);
assert.match(
  securityWorkflow,
  /flutter-version: \$\{\{ steps\.versions\.outputs\.flutter \}\}/,
  'Security CI must load Flutter from the centralized release manifest.',
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
