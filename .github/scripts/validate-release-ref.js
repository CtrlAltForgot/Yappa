#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const repositoryRoot = path.resolve(__dirname, '../..');

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

const refType = process.env.GITHUB_REF_TYPE || '';
const refName = process.env.GITHUB_REF_NAME || '';
const sourceCommit = process.env.GITHUB_SHA || '';
const versions = JSON.parse(
  fs.readFileSync(path.join(repositoryRoot, '.github/release-versions.json'), 'utf8'),
);
const installManifest = JSON.parse(
  fs.readFileSync(path.join(repositoryRoot, 'server/install-manifest.json'), 'utf8'),
);
const version = String(versions.yappa || '');

if (!/^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/.test(version)) {
  fail('Central Yappa release version is not valid semantic version text.');
}
if (version.includes('-dev') || version.includes('+')) {
  fail('Public release tags cannot use a development or build-metadata version.');
}
if (refType !== 'tag' || refName !== `v${version}`) {
  fail(`Release workflow requires exact tag v${version}.`);
}
if (!/^[a-f0-9]{40}$/.test(sourceCommit)) {
  fail('Release workflow requires one exact source commit.');
}
if (installManifest.release.version !== version) {
  fail('Server install manifest version does not match the central release version.');
}
if (installManifest.release.channel !== 'stable') {
  fail('Server install manifest must use the stable channel before publication.');
}
if (installManifest.release.published !== true) {
  fail('Server install manifest must be explicitly published before tag release.');
}
if (
  installManifest.supportTargets.some(
    (target) =>
      target.publiclySupported &&
      (target.validation !== 'verified-release' ||
        target.installCommandAvailable !== true),
  )
) {
  fail('A public server target is not release-verified and install-enabled.');
}

process.stdout.write(`Exact release ref verified: ${refName} at ${sourceCommit}\n`);
