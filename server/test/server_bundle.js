const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {spawnSync} = require('child_process');

const repositoryRoot = path.resolve(__dirname, '..', '..');
const buildScript = path.join(
  repositoryRoot,
  '.github',
  'scripts',
  'build-server-bundle.sh',
);
const temporaryRoot = fs.mkdtempSync(
  path.join(os.tmpdir(), 'yappa-server-bundle-test-'),
);

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: repositoryRoot,
    encoding: 'utf8',
    ...options,
  });
  assert.equal(
    result.status,
    0,
    `${command} ${args.join(' ')} failed:\n${result.stdout}\n${result.stderr}`,
  );
  return result.stdout;
}

function digest(filePath) {
  return crypto
    .createHash('sha256')
    .update(fs.readFileSync(filePath))
    .digest('hex');
}

try {
  const firstOutput = path.join(temporaryRoot, 'first');
  const secondOutput = path.join(temporaryRoot, 'second');
  const environment = {
    ...process.env,
    SOURCE_DATE_EPOCH: '1785211200',
    YAPPA_SOURCE_COMMIT: '0123456789abcdef0123456789abcdef01234567',
  };
  run(buildScript, ['0.1.0-dev', firstOutput], {env: environment});
  run(buildScript, ['0.1.0-dev', secondOutput], {env: environment});

  const archiveName = 'yappa-server-0.1.0-dev.tar.gz';
  const firstArchive = path.join(firstOutput, archiveName);
  const secondArchive = path.join(secondOutput, archiveName);
  assert.equal(
    digest(firstArchive),
    digest(secondArchive),
    'Identical server inputs must produce byte-identical archives.',
  );

  const checksum = fs
    .readFileSync(`${firstArchive}.sha256`, 'utf8')
    .trim()
    .split(/\s+/)[0];
  assert.equal(checksum, digest(firstArchive));

  const listing = run('tar', ['-tzf', firstArchive])
    .trim()
    .split('\n');
  for (const required of [
    'yappa-server-0.1.0-dev/BUILD-METADATA.json',
    'yappa-server-0.1.0-dev/install-manifest.json',
    'yappa-server-0.1.0-dev/install-yappa.sh',
    'yappa-server-0.1.0-dev/docker-compose.yml',
    'yappa-server-0.1.0-dev/src/server.js',
  ]) {
    assert.ok(listing.includes(required), `Bundle is missing ${required}.`);
  }
  for (const entry of listing) {
    assert.doesNotMatch(
      entry,
      /(^|\/)(\.env|livekit\.yaml|node_modules|data)(\/|$)|\.(db|age)$/,
      `Bundle contains generated or secret state: ${entry}`,
    );
    assert.equal(
      entry.includes('/test/'),
      false,
      `Runtime bundle contains development tests: ${entry}`,
    );
  }

  const extractedRoot = path.join(temporaryRoot, 'extracted');
  fs.mkdirSync(extractedRoot);
  run('tar', ['-xzf', firstArchive, '-C', extractedRoot]);
  const bundleRoot = path.join(extractedRoot, 'yappa-server-0.1.0-dev');
  const metadata = JSON.parse(
    fs.readFileSync(path.join(bundleRoot, 'BUILD-METADATA.json'), 'utf8'),
  );
  assert.deepEqual(metadata, {
    schemaVersion: 1,
    product: 'Yappa Server',
    version: '0.1.0-dev',
    sourceCommit: '0123456789abcdef0123456789abcdef01234567',
    sourceDateEpoch: 1785211200,
  });
  const bundledInstallerHelp = run(
    path.join(bundleRoot, 'install-yappa.sh'),
    ['help'],
    {cwd: bundleRoot},
  );
  assert.match(
    bundledInstallerHelp,
    /This development installer operates only on the locally present server tree/,
  );
  const installRoot = path.join(temporaryRoot, 'installed-server');
  const localInstall = run(
    path.join(bundleRoot, 'install-yappa.sh'),
    [
      'install',
      '--local-bundle',
      firstArchive,
      '--sha256',
      digest(firstArchive),
      '--install-dir',
      installRoot,
      '--no-start',
    ],
    {cwd: bundleRoot},
  );
  assert.match(localInstall, /checksum/i);
  assert.match(localInstall, /installed at/);
  assert.match(localInstall, /Startup was skipped/);
  assert.equal(
    fs.statSync(installRoot).mode & 0o777,
    0o700,
    'Installed server directory must be private.',
  );
  assert.deepEqual(
    JSON.parse(
      fs.readFileSync(path.join(installRoot, 'BUILD-METADATA.json'), 'utf8'),
    ),
    metadata,
  );
  assert.equal(fs.existsSync(path.join(installRoot, '.env')), false);
  assert.equal(fs.existsSync(path.join(installRoot, 'data')), false);

  const wrongDigestInstall = spawnSync(
    path.join(bundleRoot, 'install-yappa.sh'),
    [
      'install',
      '--local-bundle',
      firstArchive,
      '--sha256',
      '0'.repeat(64),
      '--install-dir',
      path.join(temporaryRoot, 'wrong-digest-install'),
      '--no-start',
    ],
    {cwd: bundleRoot, encoding: 'utf8'},
  );
  assert.notEqual(wrongDigestInstall.status, 0);
  assert.match(wrongDigestInstall.stderr, /checksum did not match/);
  assert.equal(
    fs.existsSync(path.join(temporaryRoot, 'wrong-digest-install')),
    false,
  );

  const mergeRefusal = spawnSync(
    path.join(bundleRoot, 'install-yappa.sh'),
    [
      'install',
      '--local-bundle',
      firstArchive,
      '--sha256',
      digest(firstArchive),
      '--install-dir',
      installRoot,
      '--no-start',
    ],
    {cwd: bundleRoot, encoding: 'utf8'},
  );
  assert.notEqual(mergeRefusal.status, 0);
  assert.match(mergeRefusal.stderr, /refusing to merge or overwrite/);

  const unsafeSource = path.join(temporaryRoot, 'unsafe-source');
  const unsafeBundleRoot = path.join(
    unsafeSource,
    'yappa-server-0.1.0-dev',
  );
  fs.mkdirSync(unsafeBundleRoot, {recursive: true});
  fs.copyFileSync(
    path.join(bundleRoot, 'BUILD-METADATA.json'),
    path.join(unsafeBundleRoot, 'BUILD-METADATA.json'),
  );
  fs.copyFileSync(
    path.join(bundleRoot, 'install-manifest.json'),
    path.join(unsafeBundleRoot, 'install-manifest.json'),
  );
  fs.copyFileSync(
    path.join(bundleRoot, 'install-yappa.sh'),
    path.join(unsafeBundleRoot, 'install-yappa.sh'),
  );
  fs.chmodSync(path.join(unsafeBundleRoot, 'install-yappa.sh'), 0o755);
  fs.symlinkSync('/etc/passwd', path.join(unsafeBundleRoot, 'unsafe-link'));
  const unsafeArchive = path.join(temporaryRoot, 'unsafe-bundle.tar.gz');
  run('tar', [
    '-czf',
    unsafeArchive,
    '-C',
    unsafeSource,
    'yappa-server-0.1.0-dev',
  ]);
  const unsafeInstallRoot = path.join(temporaryRoot, 'unsafe-install');
  const unsafeInstall = spawnSync(
    path.join(bundleRoot, 'install-yappa.sh'),
    [
      'install',
      '--local-bundle',
      unsafeArchive,
      '--sha256',
      digest(unsafeArchive),
      '--install-dir',
      unsafeInstallRoot,
      '--no-start',
    ],
    {cwd: bundleRoot, encoding: 'utf8'},
  );
  assert.notEqual(unsafeInstall.status, 0);
  assert.match(unsafeInstall.stderr, /unsupported file type/);
  assert.equal(fs.existsSync(unsafeInstallRoot), false);

  const refusal = spawnSync(
    buildScript,
    ['0.1.0-dev', firstOutput],
    {
      cwd: repositoryRoot,
      encoding: 'utf8',
      env: environment,
    },
  );
  assert.notEqual(refusal.status, 0);
  assert.match(refusal.stderr, /Refusing to overwrite an existing server bundle/);
} finally {
  fs.rmSync(temporaryRoot, {recursive: true, force: true});
}

process.stdout.write('Deterministic server bundle test passed.\n');
