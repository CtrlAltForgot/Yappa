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
const serverHostWorkflow = fs.readFileSync(
  path.join(workflowRoot, 'server_linux_conformance.yml'),
  'utf8',
);
const serverRuntimeWorkflow = fs.readFileSync(
  path.join(workflowRoot, 'server_linux_runtime.yml'),
  'utf8',
);
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
const serverBundleBuild = fs.readFileSync(
  path.join(releaseScriptRoot, 'build-server-bundle.sh'),
  'utf8',
);
const serverHostContract = fs.readFileSync(
  path.join(releaseScriptRoot, 'test-server-host-contract.sh'),
  'utf8',
);
const serverRuntimeLauncher = fs.readFileSync(
  path.join(releaseScriptRoot, 'run-server-runtime-container.sh'),
  'utf8',
);
const serverRuntimeContract = fs.readFileSync(
  path.join(releaseScriptRoot, 'test-server-runtime-contract.sh'),
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
const restoreInstaller = fs.readFileSync(
  path.join(serverRoot, 'restore-yappa-backup.sh'),
  'utf8',
);
const upgradeInstaller = fs.readFileSync(
  path.join(serverRoot, 'upgrade-yappa.sh'),
  'utf8',
);
const rollbackInstaller = fs.readFileSync(
  path.join(serverRoot, 'rollback-yappa.sh'),
  'utf8',
);
const uninstallInstaller = fs.readFileSync(
  path.join(serverRoot, 'uninstall-yappa.sh'),
  'utf8',
);
const serviceInstaller = fs.readFileSync(
  path.join(serverRoot, 'service-yappa.sh'),
  'utf8',
);
const firewallInstaller = fs.readFileSync(
  path.join(serverRoot, 'firewall-yappa.sh'),
  'utf8',
);
const recoveryInstaller = fs.readFileSync(
  path.join(serverRoot, 'recover-yappa.sh'),
  'utf8',
);
const installManifest = JSON.parse(
  fs.readFileSync(path.join(serverRoot, 'install-manifest.json'), 'utf8'),
);
const linuxInstaller = fs.readFileSync(
  path.join(serverRoot, 'install-yappa.sh'),
  'utf8',
);
const windowsInstaller = fs.readFileSync(
  path.join(serverRoot, 'Install-Yappa.ps1'),
  'utf8',
);
const installVerifier = fs.readFileSync(
  path.join(serverRoot, 'verify-yappa-install.sh'),
  'utf8',
);
const identityVerifier = fs.readFileSync(
  path.join(serverRoot, 'src', 'verify-server-identity.js'),
  'utf8',
);
const dbSource = fs.readFileSync(
  path.join(serverRoot, 'src', 'db.js'),
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
  ['restore-yappa-backup.sh', restoreInstaller],
  ['upgrade-yappa.sh', upgradeInstaller],
  ['rollback-yappa.sh', rollbackInstaller],
  ['uninstall-yappa.sh', uninstallInstaller],
  ['service-yappa.sh', serviceInstaller],
  ['firewall-yappa.sh', firewallInstaller],
  ['recover-yappa.sh', recoveryInstaller],
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

assert.match(startup, /chmod 640 livekit\.yaml/);
assert.match(startup, /RUNTIME_UID="\$\(id -u\)"/);
assert.match(startup, /startup must run as an unprivileged installation owner/);
assert.match(startup, /YAPPA_RUNTIME_UID=\$\{RUNTIME_UID\}/);
assert.match(startup, /data must be owned by the installation owner/);
assert.doesNotMatch(startup, /chown -R 1000:1000 data/);
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
assert.match(restoreInstaller, /"\$AGE_BIN" --decrypt "\$BACKUP" \|/);
assert.match(restoreInstaller, /PRAGMA quick_check/);
assert.match(restoreInstaller, /schema_migrations/);
assert.match(restoreInstaller, /server-identity\.json/);
assert.match(restoreInstaller, /Backup DB_PATH must identify/);
assert.match(restoreInstaller, /mktemp -d "\$INSTALL_PARENT\/\.yappa-restore/);
assert.match(restoreInstaller, /mv -- "\$RUNTIME_ROOT" "\$INSTALL_DIRECTORY"/);
assert.match(restoreInstaller, /The restored server is stopped/);
assert.doesNotMatch(
  restoreInstaller,
  /age[^|\n]*--output/,
  'Restore must not write a decrypted archive to disk.',
);
assert.match(upgradeInstaller, /verify-yappa-backup\.sh/);
assert.match(upgradeInstaller, /install-yappa\.sh" verify/);
assert.match(upgradeInstaller, /PRAGMA quick_check/);
assert.match(upgradeInstaller, /CURRENT_SCHEMA > TARGET_SCHEMA/);
assert.match(upgradeInstaller, /mv -- "\$SCRIPT_ROOT" "\$ROLLBACK_ROOT"/);
assert.match(upgradeInstaller, /previous installation was restored/);
assert.match(rollbackInstaller, /verify-yappa-backup\.sh/);
assert.match(
  rollbackInstaller,
  /mv -- "\$SCRIPT_ROOT" "\$PRE_ROLLBACK_ROOT"/,
);
assert.match(rollbackInstaller, /newer installation was restored/);
assert.match(uninstallInstaller, /verify-yappa-backup\.sh/);
assert.match(uninstallInstaller, /install-yappa\.sh" verify/);
assert.match(uninstallInstaller, /cp -a -- "\$SCRIPT_ROOT\/\.env"/);
assert.match(uninstallInstaller, /cp -a -- "\$SCRIPT_ROOT\/data"/);
assert.match(uninstallInstaller, /mv -- "\$SCRIPT_ROOT" "\$TOMBSTONE_ROOT"/);
assert.match(uninstallInstaller, /server installation was restored/);
assert.match(
  uninstallInstaller,
  /Resolve the retained \.\$retained_suffix installation/,
);
assert.match(serviceInstaller, /if \(\(EUID == 0\)\)/);
assert.match(serviceInstaller, /systemctl --user enable --now/);
assert.match(serviceInstaller, /systemctl --user disable --now/);
assert.match(serviceInstaller, /ExecStart=.*install-yappa\.sh.*start/);
assert.match(serviceInstaller, /ExecStartPost=.*install-yappa\.sh.*verify/);
assert.match(serviceInstaller, /ExecStop=.*install-yappa\.sh.*stop/);
assert.match(serviceInstaller, /NoNewPrivileges=yes/);
assert.match(serviceInstaller, /PrivateTmp=yes/);
assert.match(serviceInstaller, /UMask=0077/);
assert.match(serviceInstaller, /OnUnitActiveSec=1min/);
assert.match(serviceInstaller, /install-yappa\.sh.*recover/);
assert.doesNotMatch(
  serviceInstaller,
  /loginctl|enable-linger|sudo|pkexec/,
  'User autostart must not silently request persistence or privilege.',
);
assert.match(firewallInstaller, /if \(\(EUID != 0\)\)/);
assert.match(firewallInstaller, /\/var\/lib\/yappa/);
assert.match(firewallInstaller, /stat -c '%u:%a'/);
assert.match(firewallInstaller, /A requested firewall rule already exists/);
assert.match(firewallInstaller, /rollback_partial_apply/);
assert.match(firewallInstaller, /ufw must already be active/);
assert.match(firewallInstaller, /firewalld must already be running/);
assert.equal(
  (firewallInstaller.match(/port="\$\{port\/:\/-\}"/g) || []).length,
  3,
  'Every firewalld query/mutation path must translate colon ranges to hyphens.',
);
assert.match(firewallInstaller, /This script never invokes sudo/);
assert.doesNotMatch(
  firewallInstaller,
  /\bsudo\b[^\n]*\b(ufw|firewall-cmd)\b|\bpkexec\b/,
  'Firewall lifecycle must not invoke privilege escalation.',
);
assert.doesNotMatch(
  firewallInstaller,
  /\bufw\s+(--force\s+)?enable\b|systemctl[^\\n]*firewalld/,
  'Yappa must not enable or start the host firewall implicitly.',
);
assert.match(recoveryInstaller, /desired-state/);
assert.match(recoveryInstaller, /flock -n 9/);
assert.match(recoveryInstaller, /MAX_FAILURES=3/);
assert.match(recoveryInstaller, /COOLDOWN_SECONDS=900/);
assert.match(recoveryInstaller, /VERIFY_ATTEMPTS=12/);
assert.match(recoveryInstaller, /docker compose.*up -d/);
assert.match(recoveryInstaller, /verify-yappa-install\.sh/);
assert.match(recoveryInstaller, /intentionally stopped/);
assert.doesNotMatch(
  recoveryInstaller,
  /docker compose[^\n]*down|while true/,
  'Recovery must be bounded and must not turn a health check into shutdown.',
);
assert.match(
  serverBundleBuild,
  /-name '\.yappa-host-state'/,
  'Host-local registration state must never enter a release bundle.',
);
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
assert.match(
  compose,
  /user:\s*["']\$\{YAPPA_RUNTIME_UID:-1000\}:\$\{YAPPA_RUNTIME_GID:-1000\}["']/,
);
assert.match(
  compose,
  /yappa-livekit:[\s\S]*?user:\s*["']0:0["'][\s\S]*?group_add:\s*\n\s+- ["']\$\{YAPPA_RUNTIME_GID:-1000\}["'][\s\S]*?cap_add:\s*\n\s+- NET_BIND_SERVICE/,
  'LiveKit low-port root exception must remain explicit and capability-bounded.',
);
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
  (compose.match(/restart:\s*unless-stopped/g) || []).length,
  4,
  'Every canonical container must recover after an unexpected process exit.',
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
for (const image of [
  'ubuntu@sha256:',
  'debian@sha256:',
  'fedora@sha256:',
  'rockylinux/rockylinux@sha256:',
]) {
  assert.ok(
    serverHostWorkflow.includes(image),
    `Server host matrix must digest-pin ${image}`,
  );
}
for (const image of [
  'ubuntu@sha256:',
  'debian@sha256:',
  'fedora@sha256:',
  'rockylinux/rockylinux@sha256:',
]) {
  assert.ok(
    serverRuntimeWorkflow.includes(image),
    `Server runtime matrix must digest-pin ${image}`,
  );
}
assert.match(
  serverRuntimeWorkflow,
  /actions\/checkout@[a-f0-9]{40}/,
  'Server runtime checkout action must be commit-pinned.',
);
assert.match(serverRuntimeWorkflow, /run-server-runtime-container\.sh/);
assert.match(serverRuntimeWorkflow, /backend: ufw/);
assert.match(serverRuntimeWorkflow, /backend: firewalld/);
assert.doesNotMatch(serverRuntimeWorkflow, /continue-on-error:\s*true/);
assert.match(serverRuntimeLauncher, /--privileged/);
assert.match(serverRuntimeLauncher, /\/workspace:ro/);
assert.match(serverRuntimeLauncher, /docker rm -f/);
assert.match(serverRuntimeContract, /\/proc\/1\/comm/);
assert.match(serverRuntimeContract, /systemctl --user is-active/);
assert.match(serverRuntimeContract, /MANAGER_STATUS.*224/s);
assert.match(serverRuntimeContract, /allow-hosted-pam-block/);
assert.match(serverRuntimeContract, /User-service runtime is not claimed/);
assert.match(serverRuntimeContract, /firewall-yappa\.sh" apply/);
assert.match(serverRuntimeContract, /firewall-yappa\.sh" remove/);
assert.match(
  serverHostWorkflow,
  /actions\/checkout@[a-f0-9]{40}/,
  'Server host matrix checkout action must be commit-pinned.',
);
assert.match(serverHostWorkflow, /test-server-host-contract\.sh/);
for (const target of [
  'ubuntu-lts-x64',
  'debian-stable-x64',
  'fedora-current-x64',
  'rhel-compatible-current-x64',
]) {
  assert.match(serverHostWorkflow, new RegExp(target));
}
assert.match(serverHostContract, /publiclySupported/);
assert.match(serverHostContract, /installCommandAvailable/);
assert.match(
  serverHostContract,
  /does not claim Docker, media, systemd, or firewall runtime conformance/,
);
assert.doesNotMatch(
  serverHostWorkflow,
  /continue-on-error:\s*true/,
  'No Tier-1 host may be optional in the matrix.',
);
const securityWorkflow = fs.readFileSync(
  path.join(workflowRoot, 'security.yml'),
  'utf8',
);
const serverFullStackWorkflow = fs.readFileSync(
  path.join(workflowRoot, 'server_full_stack.yml'),
  'utf8',
);
const serverFullStackContract = fs.readFileSync(
  path.join(repositoryRoot, '.github', 'scripts', 'test-server-full-stack.sh'),
  'utf8',
);
assert.match(
  serverFullStackWorkflow,
  /actions\/checkout@[a-f0-9]{40}/,
  'Full-stack checkout action must be commit-pinned.',
);
assert.doesNotMatch(serverFullStackWorkflow, /continue-on-error:\s*true/);
assert.match(serverFullStackWorkflow, /test-server-full-stack\.sh/);
assert.match(serverFullStackContract, /build-server-bundle\.sh/);
assert.match(serverFullStackContract, /install-yappa\.sh" install/);
assert.match(serverFullStackContract, /install-yappa\.sh" verify/);
assert.match(serverFullStackContract, /install-yappa\.sh" stop/);
assert.match(serverFullStackContract, /install-yappa\.sh" recover/);
assert.match(serverFullStackContract, /docker stop newchat-node/);
assert.match(serverFullStackContract, /sha256sum "\$IDENTITY_PATH"/);
assert.match(serverFullStackContract, /down --volumes --remove-orphans/);
assert.match(
  desktopWorkflows[0],
  /bash -n server\/install-yappa\.sh/,
  'Linux artifact CI must syntax-check the server installer.',
);
assert.match(
  desktopWorkflows[0],
  /node server\/test\/install_manifest\.js/,
  'Linux artifact CI must validate the shared server manifest.',
);
assert.match(
  desktopWorkflows[1],
  /System\.Management\.Automation\.Language\.Parser/,
  'Windows artifact CI must parse the PowerShell server installer.',
);
assert.match(
  desktopWorkflows[1],
  /node server\/test\/install_manifest\.js/,
  'Windows artifact CI must validate the shared server manifest.',
);
assert.match(
  desktopWorkflows[1],
  /Install-Yappa\.ps1 help/,
  'Windows artifact CI must execute the non-mutating installer entry point.',
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
assert.match(
  securityWorkflow,
  /\.github\/scripts\/build-server-bundle\.sh/,
  'Security CI must build and inspect the deterministic server bundle.',
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

assert.equal(installManifest.release.published, false);
assert.equal(
  installManifest.clientPolicy.allowInstallCommandGeneration,
  false,
  'The client must not generate commands from an unpublished manifest.',
);
assert.equal(
  installManifest.clientPolicy.allowLocalSupervision,
  false,
  'The client must not supervise an unpublished server release.',
);
for (const artifact of Object.values(installManifest.artifacts)) {
  assert.equal(artifact.status, 'unpublished');
  assert.equal(artifact.url, null);
  assert.equal(artifact.sha256, null);
  assert.equal(artifact.signatureUrl, null);
}
for (const target of installManifest.supportTargets) {
  assert.equal(target.publiclySupported, false);
  assert.equal(target.installCommandAvailable, false);
}
assert.match(linuxInstaller, /^set -euo pipefail$/m);
assert.match(linuxInstaller, /^umask 077$/m);
assert.match(linuxInstaller, /install --local-source/);
assert.match(
  linuxInstaller,
  /Remote installation is unavailable for this development release/,
);
assert.match(linuxInstaller, /docker compose version/);
assert.match(linuxInstaller, /minimum 4096 MiB/);
assert.match(linuxInstaller, /minimum 10240 MiB/);
assert.match(linuxInstaller, /--local-bundle/);
assert.match(linuxInstaller, /\^\[a-f0-9\]\{64\}\$/);
assert.match(linuxInstaller, /sha256sum "\$archive"/);
assert.match(linuxInstaller, /must contain exactly one versioned root/);
assert.match(linuxInstaller, /tar -tvzf "\$archive"/);
assert.match(linuxInstaller, /cut -c1/);
assert.match(linuxInstaller, /unsupported file type/);
assert.match(linuxInstaller, /refusing to merge or overwrite/);
assert.match(linuxInstaller, /mkdir -m 700 "\$install_directory"/);
assert.match(
  linuxInstaller,
  /find "\$install_directory" -type f -exec chmod 644 \{\} \+/,
);
assert.match(
  linuxInstaller,
  /chmod 755 "\$install_directory\/\$installed_executable"/,
);
assert.match(
  linuxInstaller,
  /verify\)[\s\S]*?"\$SCRIPT_ROOT\/verify-yappa-install\.sh"/,
  'The lifecycle verify command must run installation verification.',
);
assert.match(
  linuxInstaller,
  /verify-backup\)[\s\S]*?"\$SCRIPT_ROOT\/verify-yappa-backup\.sh"/,
  'Backup restore verification must remain separately addressable.',
);
assert.doesNotMatch(
  linuxInstaller,
  /curl[^\r\n]*(\||;)[^\r\n]*(sh|bash)/,
  'The development installer must not pipe remote content into a shell.',
);
assert.match(windowsInstaller, /Set-StrictMode -Version Latest/);
assert.match(windowsInstaller, /\$ErrorActionPreference = "Stop"/);
assert.match(windowsInstaller, /ConvertFrom-Json/);
assert.match(
  windowsInstaller,
  /Yappa never asks for or stores a remote Administrator password/,
);
assert.match(
  windowsInstaller,
  /runs Yappa's canonical Linux lifecycle inside one[\s\S]*explicit WSL2 distribution/,
);
assert.match(windowsInstaller, /Invoke-Wsl -Arguments \$arguments\.ToArray\(\)/);
assert.match(windowsInstaller, /not a Windows \/mnt drive/);
assert.doesNotMatch(
  windowsInstaller,
  /(?:bash|sh)",\s*"-c"/,
  'Windows lifecycle dispatch must not interpolate arguments into a shell command.',
);
assert.doesNotMatch(
  windowsInstaller,
  /(ConvertTo-SecureString|PSCredential|Get-Credential)/,
  'The Windows wrapper must not request or retain administrator credentials.',
);
assert.match(installVerifier, /^set -euo pipefail$/m);
assert.match(installVerifier, /^umask 077$/m);
assert.match(installVerifier, /stat -c '%a' \.env/);
assert.match(installVerifier, /stat -c '%a' data/);
assert.match(installVerifier, /SELECT COALESCE\(MAX\(version\), 0\)/);
assert.match(installVerifier, /PRAGMA quick_check/);
assert.match(installVerifier, /server-identity\.json/);
assert.match(
  installVerifier,
  /\^\(srv_\[a-f0-9\]\{32\}\|node_\[a-f0-9\]\{16\}\)\$/,
  'Install verification must accept canonical IDs and immutable legacy IDs.',
);
assert.match(
  dbSource,
  /`srv_\$\{crypto\.randomBytes\(16\)\.toString\('hex'\)\}`/,
  'Fresh servers must receive a 128-bit canonical server identifier.',
);
assert.match(installVerifier, /docker compose ps --status running --services/);
assert.match(installVerifier, /docker inspect -f '\{\{\.State\.Health\.Status\}\}'/);
assert.match(installVerifier, /node src\/verify-server-identity\.js/);
assert.match(installVerifier, /--connect-to/);
assert.match(installVerifier, /Sec-WebSocket-Version: 13/);
assert.match(installVerifier, /\^HTTP\/\[0-9\.\]\+ 101/);
assert.match(installVerifier, /Yappa LiveKit route did not reach/);
assert.match(
  installVerifier,
  /External reachability, forced TURN, and real media remain separate release tests/,
  'Host verification must not overclaim externally observable media behavior.',
);
assert.match(identityVerifier, /yappa-server-proof-v1/);
assert.match(identityVerifier, /crypto\.verify/);
assert.match(identityVerifier, /AbortSignal\.timeout/);
assert.doesNotMatch(
  identityVerifier,
  /console\.(log|error)/,
  'Identity verification must use bounded, intentional output.',
);
assert.match(serverBundleBuild, /^set -euo pipefail$/m);
assert.match(serverBundleBuild, /^umask 077$/m);
assert.match(serverBundleBuild, /--sort=name/);
assert.match(serverBundleBuild, /--mtime="@\$SOURCE_DATE_EPOCH"/);
assert.match(serverBundleBuild, /--owner=0/);
assert.match(serverBundleBuild, /--group=0/);
assert.match(serverBundleBuild, /--numeric-owner/);
assert.match(serverBundleBuild, /gzip -n/);
assert.match(serverBundleBuild, /sha256sum "\$ARCHIVE_NAME"/);
assert.match(serverBundleBuild, /Refusing to overwrite an existing server bundle/);
const runtimeFileBlock = serverBundleBuild.match(
  /^RUNTIME_FILES=\(\n([\s\S]*?)^\)$/m,
);
assert.ok(runtimeFileBlock, 'Server bundle must use an explicit runtime allowlist.');
assert.doesNotMatch(
  runtimeFileBlock[1],
  /^\s+"(?:test\/|node_modules|livekit\.yaml|\.env)"$/m,
  'The runtime bundle input list must not include tests, dependencies, or generated secrets.',
);

process.stdout.write('Deployment safety test passed.\n');
