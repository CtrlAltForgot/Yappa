const assert = require('assert');
const fs = require('fs');
const path = require('path');
const Ajv2020 = require('ajv/dist/2020');

const serverRoot = path.resolve(__dirname, '..');
const repositoryRoot = path.resolve(serverRoot, '..');
const manifestPath = path.join(serverRoot, 'install-manifest.json');
const schemaPath = path.join(serverRoot, 'install-manifest.schema.json');
const releaseVersionsPath = path.join(
  repositoryRoot,
  '.github',
  'release-versions.json',
);

const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
const releaseVersions = JSON.parse(
  fs.readFileSync(releaseVersionsPath, 'utf8'),
);

const ajv = new Ajv2020({allErrors: true, strict: true});
const validateManifest = ajv.compile(schema);
assert.equal(
  validateManifest(manifest),
  true,
  `Install manifest failed its JSON Schema: ${ajv.errorsText(
    validateManifest.errors,
    {separator: '\n'},
  )}`,
);

assert.equal(manifest.schemaVersion, 1);
assert.equal(schema.properties.schemaVersion.const, manifest.schemaVersion);
assert.equal(manifest.product, 'Yappa Server');
assert.equal(
  manifest.release.version,
  releaseVersions.yappa,
  'Client and server release metadata must use the same Yappa version.',
);
assert.equal(manifest.release.configurationSchemaVersion, 1);
assert.equal(manifest.release.databaseSchemaVersion, 3);
assert.equal(manifest.artifacts.serverBundle.format, 'tar.gz');
assert.equal(
  manifest.artifacts.serverBundle.rootPattern,
  'yappa-server-{version}',
);
assert.equal(
  manifest.artifacts.serverBundle.metadataFile,
  'BUILD-METADATA.json',
);
assert.equal(manifest.artifacts.serverBundle.checksumAlgorithm, 'sha256');

const expectedTargets = new Set([
  'ubuntu-lts-x64',
  'debian-stable-x64',
  'fedora-current-x64',
  'rhel-compatible-current-x64',
  'unraid-current-x64',
  'windows-11-wsl2-x64',
  'windows-server-current-x64',
]);
const actualTargets = new Set(
  manifest.supportTargets.map((target) => target.id),
);
assert.deepEqual(actualTargets, expectedTargets);
assert.equal(
  actualTargets.size,
  manifest.supportTargets.length,
  'Support target identifiers must be unique.',
);

for (const target of manifest.supportTargets) {
  assert.match(target.id, /^[a-z0-9-]+$/);
  assert.ok(['linux', 'windows'].includes(target.os));
  assert.equal(target.architecture, 'x86_64');
  assert.equal(target.tier, 1);
  assert.ok(
    ['pending', 'verified-development', 'verified-release'].includes(
      target.validation,
    ),
  );
  if (target.publiclySupported || target.installCommandAvailable) {
    assert.equal(
      target.validation,
      'verified-release',
      `${target.id} cannot be advertised before release validation.`,
    );
    assert.equal(
      manifest.release.published,
      true,
      `${target.id} cannot be advertised from an unpublished release.`,
    );
  }
}

const sha256Pattern = /^[a-f0-9]{64}$/;
for (const [name, artifact] of Object.entries(manifest.artifacts)) {
  if (artifact.status === 'published') {
    assert.match(artifact.url, /^https:\/\//, `${name} needs an HTTPS URL.`);
    assert.match(artifact.sha256, sha256Pattern, `${name} needs a SHA-256.`);
    assert.match(
      artifact.signatureUrl,
      /^https:\/\//,
      `${name} needs a detached signature URL.`,
    );
  } else {
    assert.equal(artifact.status, 'unpublished');
    assert.equal(artifact.url, null);
    assert.equal(artifact.sha256, null);
    assert.equal(artifact.signatureUrl, null);
  }
}

if (!manifest.release.published) {
  assert.equal(manifest.clientPolicy.allowInstallCommandGeneration, false);
  assert.equal(manifest.clientPolicy.allowLocalSupervision, false);
  for (const target of manifest.supportTargets) {
    assert.equal(target.publiclySupported, false);
    assert.equal(target.installCommandAvailable, false);
  }
}

assert.deepEqual(
  new Set(manifest.configuration.secretKeys),
  new Set([
    'ATTACHMENT_SIGNING_SECRET',
    'LIVEKIT_API_KEY',
    'LIVEKIT_API_SECRET',
  ]),
);
assert.deepEqual(
  new Set(manifest.configuration.backupIncludes),
  new Set(['.env', 'data']),
);

const publicSockets = manifest.network.publicPorts.map((entry) =>
  entry.port === undefined
    ? `${entry.protocol}:${entry.range.join('-')}`
    : `${entry.protocol}:${entry.port}`,
);
assert.deepEqual(publicSockets, [
  'tcp:80',
  'tcp:443',
  'udp:443',
  'tcp:7881',
  'udp:50000-50100',
]);
const forbiddenSockets = new Set(
  manifest.network.neverExposePorts.map(
    (entry) => `${entry.protocol}:${entry.port}`,
  ),
);
for (const socket of ['tcp:4100', 'tcp:7880', 'tcp:7882', 'udp:41201']) {
  assert.ok(forbiddenSockets.has(socket), `${socket} must remain private.`);
}

for (const capability of [
  'authentication',
  'yuid-proof',
  'opaque-mls-delivery',
  'encrypted-attachments',
  'https-wss',
  'livekit-media',
  'turn-udp',
  'signed-lan-discovery',
  'encrypted-backup',
  'isolated-restore-verification',
]) {
  assert.ok(
    manifest.requiredCapabilities.includes(capability),
    `Missing required capability ${capability}.`,
  );
}
for (const command of [
  'preflight',
  'install',
  'start',
  'stop',
  'status',
  'logs',
  'backup',
  'restore',
  'verify',
  'verify-backup',
  'upgrade',
  'rollback',
  'uninstall',
]) {
  assert.ok(
    manifest.lifecycleCommands.includes(command),
    `Missing lifecycle command ${command}.`,
  );
}
assert.deepEqual(manifest.implementedLifecycleCommands.linux, [
  'preflight',
  'install',
  'start',
  'stop',
  'status',
  'logs',
  'backup',
  'verify',
  'verify-backup',
]);
assert.deepEqual(manifest.implementedLifecycleCommands.windows, ['preflight']);
for (const commands of Object.values(
  manifest.implementedLifecycleCommands,
)) {
  for (const command of commands) {
    assert.ok(
      manifest.lifecycleCommands.includes(command),
      `Implemented command ${command} is absent from the lifecycle contract.`,
    );
  }
}
assert.deepEqual(manifest.implementedHealthChecks, [
  'container-health',
  'database-schema',
  'persistent-storage-write',
  'server-identity-proof',
  'https-api',
  'websocket-upgrade',
  'livekit-route',
]);
for (const healthCheck of manifest.implementedHealthChecks) {
  assert.ok(
    manifest.healthChecks.includes(healthCheck),
    `Implemented health check ${healthCheck} is absent from the contract.`,
  );
}

for (const artifact of [
  manifest.artifacts.linuxInstaller,
  manifest.artifacts.windowsInstaller,
]) {
  assert.ok(
    fs.existsSync(path.join(repositoryRoot, artifact.repositoryPath)),
    `Installer front end does not exist: ${artifact.repositoryPath}`,
  );
}

process.stdout.write('Install manifest validation passed.\n');
