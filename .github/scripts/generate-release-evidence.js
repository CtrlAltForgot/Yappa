#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const {execFileSync} = require('child_process');

const repositoryRoot = path.resolve(__dirname, '../..');

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

function parseArguments(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flag?.startsWith('--') || !value) {
      fail('Release evidence requires flag/value arguments.');
    }
    if (values.has(flag)) fail(`Duplicate release evidence option: ${flag}`);
    values.set(flag, value);
  }
  for (const flag of ['--artifact', '--output-dir', '--version', '--commit']) {
    if (!values.has(flag)) fail(`Missing required release evidence option: ${flag}`);
  }
  return values;
}

function sha256File(filePath) {
  const hash = crypto.createHash('sha256');
  hash.update(fs.readFileSync(filePath));
  return hash.digest('hex');
}

function packageId(purl) {
  return `SPDXRef-Package-${crypto
    .createHash('sha256')
    .update(purl)
    .digest('hex')
    .slice(0, 20)}`;
}

function npmPackages() {
  const lock = JSON.parse(
    fs.readFileSync(path.join(repositoryRoot, 'server/package-lock.json'), 'utf8'),
  );
  return Object.entries(lock.packages || {})
    .filter(([location, metadata]) => location && metadata?.version)
    .map(([location, metadata]) => {
      const fallback = location.split('node_modules/').pop();
      const name = metadata.name || fallback;
      return {
        ecosystem: 'npm',
        name,
        version: String(metadata.version),
        purl: `pkg:npm/${encodeURIComponent(name)}@${encodeURIComponent(
          metadata.version,
        )}`,
      };
    });
}

function cargoPackages() {
  const content = fs.readFileSync(
    path.join(repositoryRoot, 'client/native/yappa_mls/Cargo.lock'),
    'utf8',
  );
  return content
    .split(/\n\[\[package\]\]\n/)
    .map((block) => ({
      name: block.match(/^name = "([^"]+)"$/m)?.[1],
      version: block.match(/^version = "([^"]+)"$/m)?.[1],
      source: block.match(/^source = "([^"]+)"$/m)?.[1],
    }))
    .filter((item) => item.name && item.version && item.source)
    .map((item) => ({
      ecosystem: 'cargo',
      name: item.name,
      version: item.version,
      purl: `pkg:cargo/${encodeURIComponent(item.name)}@${encodeURIComponent(
        item.version,
      )}`,
    }));
}

function pubPackages() {
  const content = fs.readFileSync(
    path.join(repositoryRoot, 'client/pubspec.lock'),
    'utf8',
  );
  const packages = [];
  let current = null;
  for (const line of content.split(/\r?\n/)) {
    const packageMatch = line.match(/^  ([A-Za-z0-9_]+):$/);
    if (packageMatch) {
      if (current?.name && current.version && current.source === 'hosted') {
        packages.push(current);
      }
      current = {name: packageMatch[1], version: null, source: null};
      continue;
    }
    if (!current) continue;
    current.source ||= line.match(/^    source: ([A-Za-z0-9_-]+)$/)?.[1] || null;
    current.version ||= line.match(/^    version: "([^"]+)"$/)?.[1] || null;
  }
  if (current?.name && current.version && current.source === 'hosted') {
    packages.push(current);
  }
  return packages.map((item) => ({
    ecosystem: 'pub',
    name: item.name,
    version: item.version,
    purl: `pkg:pub/${encodeURIComponent(item.name)}@${encodeURIComponent(
      item.version,
    )}`,
  }));
}

function sourceTimestamp(commit) {
  const output = execFileSync(
    'git',
    ['-C', repositoryRoot, 'show', '-s', '--format=%ct', commit],
    {encoding: 'utf8'},
  ).trim();
  if (!/^[0-9]+$/.test(output)) fail('Source commit timestamp is invalid.');
  return new Date(Number(output) * 1000).toISOString();
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  const artifact = path.resolve(options.get('--artifact'));
  const outputDirectory = path.resolve(options.get('--output-dir'));
  const version = options.get('--version');
  const commit = options.get('--commit');
  const githubAttestation =
    options.get('--github-attestation') === 'true';
  if (
    options.has('--github-attestation') &&
    !['true', 'false'].includes(options.get('--github-attestation'))
  ) {
    fail('--github-attestation must be true or false.');
  }

  if (!fs.statSync(artifact, {throwIfNoEntry: false})?.isFile()) {
    fail(`Release artifact is missing: ${artifact}`);
  }
  if (!/^[0-9A-Za-z][0-9A-Za-z.+-]*$/.test(version)) {
    fail('Release evidence version is malformed.');
  }
  if (!/^[a-f0-9]{40}$/.test(commit)) {
    fail('Release evidence commit must be one full lowercase Git SHA.');
  }

  fs.mkdirSync(outputDirectory, {recursive: true, mode: 0o755});
  const artifactName = path.basename(artifact);
  const artifactDigest = sha256File(artifact);
  const checksumPath = path.join(outputDirectory, `${artifactName}.sha256`);
  const sbomPath = path.join(outputDirectory, `${artifactName}.spdx.json`);
  const evidencePath = path.join(outputDirectory, `${artifactName}.evidence.json`);
  for (const output of [checksumPath, sbomPath, evidencePath]) {
    if (fs.existsSync(output)) fail(`Refusing to overwrite release evidence: ${output}`);
  }

  const dependencyMap = new Map();
  for (const dependency of [
    ...npmPackages(),
    ...cargoPackages(),
    ...pubPackages(),
  ]) {
    dependencyMap.set(dependency.purl, dependency);
  }
  const dependencies = [...dependencyMap.values()].sort((left, right) =>
    left.purl.localeCompare(right.purl),
  );
  const artifactSpdxId = 'SPDXRef-Yappa-Artifact';
  const packages = [
    {
      SPDXID: artifactSpdxId,
      name: artifactName,
      versionInfo: version,
      downloadLocation: 'NOASSERTION',
      filesAnalyzed: false,
      licenseConcluded: 'NOASSERTION',
      licenseDeclared: 'NOASSERTION',
      checksums: [{algorithm: 'SHA256', checksumValue: artifactDigest}],
    },
    ...dependencies.map((dependency) => ({
      SPDXID: packageId(dependency.purl),
      name: dependency.name,
      versionInfo: dependency.version,
      downloadLocation: 'NOASSERTION',
      filesAnalyzed: false,
      licenseConcluded: 'NOASSERTION',
      licenseDeclared: 'NOASSERTION',
      externalRefs: [
        {
          referenceCategory: 'PACKAGE-MANAGER',
          referenceType: 'purl',
          referenceLocator: dependency.purl,
        },
      ],
    })),
  ];
  const sbom = {
    spdxVersion: 'SPDX-2.3',
    dataLicense: 'CC0-1.0',
    SPDXID: 'SPDXRef-DOCUMENT',
    name: `${artifactName} source-dependency SBOM`,
    documentNamespace:
      `https://yappa.app/spdx/${encodeURIComponent(artifactName)}/` +
      `${commit}/${artifactDigest}`,
    creationInfo: {
      created: sourceTimestamp(commit),
      creators: ['Tool: Yappa generate-release-evidence.js'],
    },
    documentDescribes: [artifactSpdxId],
    packages,
    relationships: dependencies.map((dependency) => ({
      spdxElementId: artifactSpdxId,
      relationshipType: 'DEPENDS_ON',
      relatedSpdxElement: packageId(dependency.purl),
    })),
  };
  const evidence = {
    schemaVersion: 1,
    product: 'Yappa',
    version,
    sourceCommit: commit,
    artifact: {
      name: artifactName,
      size: fs.statSync(artifact).size,
      sha256: artifactDigest,
    },
    sbom: {
      format: 'SPDX-2.3',
      file: path.basename(sbomPath),
      scope: 'locked source dependencies plus artifact digest',
    },
    signatures: {
      platform: false,
      detached: false,
    },
    provenance: {
      githubArtifactAttestation: githubAttestation,
    },
  };

  fs.writeFileSync(checksumPath, `${artifactDigest} *${artifactName}\n`, {
    mode: 0o644,
    flag: 'wx',
  });
  fs.writeFileSync(sbomPath, `${JSON.stringify(sbom, null, 2)}\n`, {
    mode: 0o644,
    flag: 'wx',
  });
  fs.writeFileSync(evidencePath, `${JSON.stringify(evidence, null, 2)}\n`, {
    mode: 0o644,
    flag: 'wx',
  });
  process.stdout.write(`Artifact checksum: ${checksumPath}\n`);
  process.stdout.write(`SPDX SBOM:        ${sbomPath}\n`);
  process.stdout.write(`Evidence record:  ${evidencePath}\n`);
}

main();
