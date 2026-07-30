#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

function filesBelow(directory) {
  return fs.readdirSync(directory, {withFileTypes: true}).flatMap((entry) => {
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) return filesBelow(absolute);
    return entry.isFile() && entry.name.endsWith('.js') ? [absolute] : [];
  });
}

function verifyServerRuntimeClosure(root) {
  const bundleRoot = path.resolve(root || '');
  const sourceRoot = path.join(bundleRoot, 'src');
  if (!root || !fs.statSync(sourceRoot, {throwIfNoEntry: false})?.isDirectory()) {
    throw new Error('Bundle root must contain a src directory.');
  }
  const failures = [];
  for (const sourceFile of filesBelow(sourceRoot)) {
    const source = fs.readFileSync(sourceFile, 'utf8');
    const requires = source.matchAll(/require\(\s*['"](\.[^'"]+)['"]\s*\)/g);
    for (const match of requires) {
      const requested = match[1];
      const unresolved = path.resolve(path.dirname(sourceFile), requested);
      const candidates = [
        unresolved,
        `${unresolved}.js`,
        path.join(unresolved, 'index.js'),
      ];
      const resolved = candidates.find(
        (candidate) => fs.statSync(candidate, {throwIfNoEntry: false})?.isFile(),
      );
      if (
        !resolved ||
        (resolved !== sourceRoot &&
          !resolved.startsWith(`${sourceRoot}${path.sep}`))
      ) {
        failures.push(
          `${path.relative(bundleRoot, sourceFile)} requires missing ${requested}`,
        );
      }
    }
  }
  if (failures.length > 0) {
    throw new Error(`Incomplete server runtime closure:\n${failures.join('\n')}`);
  }
}

module.exports = {verifyServerRuntimeClosure};

if (require.main === module) {
  if (!process.argv[2]) {
    process.stderr.write('Usage: verify-server-runtime-closure.js BUNDLE_ROOT\n');
    process.exit(2);
  }
  try {
    verifyServerRuntimeClosure(process.argv[2]);
    process.stdout.write('Server runtime module closure verified.\n');
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
  }
}
