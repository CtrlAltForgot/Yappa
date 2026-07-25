const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const repositoryRoot = path.resolve(__dirname, '..', '..');
const excludedSegments = new Set([
  '.dart_tool',
  '.git',
  'build',
  'coverage',
  'dist',
  'node_modules',
  'target',
]);
const forbiddenBasenames = new Set([
  '.env',
  'authorized_keys',
  'id_dsa',
  'id_ecdsa',
  'id_ed25519',
  'id_rsa',
  'server-identity.json',
]);
const forbiddenExtensions = new Set([
  '.db',
  '.key',
  '.p12',
  '.pem',
  '.pfx',
  '.sqlite',
  '.sqlite3',
]);
const forbiddenContent = [
  new RegExp(
    '-----BEGIN ' + '(?:DSA |EC |OPENSSH |PGP |RSA )?PRIVATE KEY-----',
  ),
  new RegExp('-----BEGIN ' + 'ENCRYPTED PRIVATE KEY-----'),
  /\bAKIA[0-9A-Z]{16}\b/,
  /\bgh[opsu]_[A-Za-z0-9_]{30,}\b/,
  /\bgithub_pat_[A-Za-z0-9_]{40,}\b/,
  /\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}\b/,
];

function repositoryFiles() {
  const result = spawnSync(
    'git',
    ['ls-files', '--cached', '--others', '--exclude-standard', '-z'],
    {
      cwd: repositoryRoot,
      encoding: 'utf8',
      maxBuffer: 16 * 1024 * 1024,
    },
  );
  assert.equal(
    result.status,
    0,
    `Could not enumerate repository files: ${result.stderr}`,
  );
  return result.stdout
    .split('\0')
    .filter(Boolean)
    .filter((relativePath) => {
      const segments = relativePath.split('/');
      return !segments.some((segment) => excludedSegments.has(segment));
    });
}

function assertSafeFilename(relativePath) {
  const basename = path.basename(relativePath);
  const extension = path.extname(basename).toLowerCase();
  assert.equal(
    forbiddenBasenames.has(basename) ||
      forbiddenExtensions.has(extension),
    false,
    `Credential or production-data file must not enter the repository: ${relativePath}`,
  );
}

function assertSafeContent(relativePath) {
  const absolutePath = path.join(repositoryRoot, relativePath);
  if (!fs.existsSync(absolutePath)) return;
  const stat = fs.statSync(absolutePath);
  if (!stat.isFile() || stat.size > 5 * 1024 * 1024) return;
  const bytes = fs.readFileSync(absolutePath);
  if (bytes.includes(0)) return;
  const source = bytes.toString('utf8');
  for (const pattern of forbiddenContent) {
    assert.equal(
      pattern.test(source),
      false,
      `Possible committed secret matched ${pattern} in ${relativePath}`,
    );
  }
}

for (const relativePath of repositoryFiles()) {
  assertSafeFilename(relativePath);
  assertSafeContent(relativePath);
}

process.stdout.write('Repository secret scan passed.\n');
