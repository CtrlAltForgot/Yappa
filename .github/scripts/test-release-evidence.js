#!/usr/bin/env node
'use strict';

const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {execFileSync, spawnSync} = require('child_process');

const repositoryRoot = path.resolve(__dirname, '../..');
const generator = path.join(
  repositoryRoot,
  '.github/scripts/generate-release-evidence.js',
);
const validator = path.join(
  repositoryRoot,
  '.github/scripts/validate-release-ref.js',
);
const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'yappa-evidence-'));

try {
  const commit = execFileSync('git', ['rev-parse', 'HEAD'], {
    cwd: repositoryRoot,
    encoding: 'utf8',
  }).trim();
  const artifact = path.join(temporaryRoot, 'Yappa fixture.zip');
  const output = path.join(temporaryRoot, 'evidence');
  fs.writeFileSync(artifact, crypto.randomBytes(64));
  execFileSync(
    process.execPath,
    [
      generator,
      '--artifact',
      artifact,
      '--output-dir',
      output,
      '--version',
      '0.1.0-dev',
      '--commit',
      commit,
    ],
    {cwd: repositoryRoot},
  );

  const digest = crypto
    .createHash('sha256')
    .update(fs.readFileSync(artifact))
    .digest('hex');
  assert.equal(
    fs.readFileSync(path.join(output, 'Yappa fixture.zip.sha256'), 'utf8'),
    `${digest} *Yappa fixture.zip\n`,
  );
  const sbom = JSON.parse(
    fs.readFileSync(path.join(output, 'Yappa fixture.zip.spdx.json'), 'utf8'),
  );
  assert.equal(sbom.spdxVersion, 'SPDX-2.3');
  assert.deepEqual(sbom.documentDescribes, ['SPDXRef-Yappa-Artifact']);
  assert.ok(sbom.packages.length > 100);
  assert.ok(
    sbom.packages.some((item) =>
      item.externalRefs?.some((reference) =>
        reference.referenceLocator.startsWith('pkg:cargo/'),
      ),
    ),
  );
  assert.ok(
    sbom.packages.some((item) =>
      item.externalRefs?.some((reference) =>
        reference.referenceLocator.startsWith('pkg:npm/'),
      ),
    ),
  );
  assert.ok(
    sbom.packages.some((item) =>
      item.externalRefs?.some((reference) =>
        reference.referenceLocator.startsWith('pkg:pub/'),
      ),
    ),
  );
  const evidence = JSON.parse(
    fs.readFileSync(path.join(output, 'Yappa fixture.zip.evidence.json'), 'utf8'),
  );
  assert.equal(evidence.artifact.sha256, digest);
  assert.equal(evidence.signatures.platform, false);
  assert.equal(evidence.provenance.githubArtifactAttestation, false);

  const overwrite = spawnSync(
    process.execPath,
    [
      generator,
      '--artifact',
      artifact,
      '--output-dir',
      output,
      '--version',
      '0.1.0-dev',
      '--commit',
      commit,
    ],
    {cwd: repositoryRoot, encoding: 'utf8'},
  );
  assert.notEqual(overwrite.status, 0);
  assert.match(overwrite.stderr, /Refusing to overwrite release evidence/);

  const developmentRelease = spawnSync(process.execPath, [validator], {
    cwd: repositoryRoot,
    encoding: 'utf8',
    env: {
      ...process.env,
      GITHUB_REF_TYPE: 'tag',
      GITHUB_REF_NAME: 'v0.1.0-dev',
      GITHUB_SHA: commit,
    },
  });
  assert.notEqual(developmentRelease.status, 0);
  assert.match(developmentRelease.stderr, /cannot use a development/);

  process.stdout.write('Release evidence and exact-tag guard test passed.\n');
} finally {
  fs.rmSync(temporaryRoot, {recursive: true, force: true});
}
