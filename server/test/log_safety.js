const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const Database = require('better-sqlite3');
const { CURRENT_SCHEMA_VERSION } = require('../src/db');

const serverRoot = path.resolve(__dirname, '..');
const repositoryRoot = path.resolve(serverRoot, '..');
const sensitiveLogTerms = [
  /password/i,
  /\btoken\b/i,
  /secret/i,
  /privateKey/i,
  /private_key/i,
  /authorization/i,
  /req\.body/i,
  /message\.content/i,
  /absolutePath/i,
  /\bDB_PATH\b/,
  /\bDATA_ROOT\b/,
];

function sourceFiles(root, extensions) {
  const files = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const fullPath = path.join(root, entry.name);
    if (entry.isDirectory()) {
      files.push(...sourceFiles(fullPath, extensions));
    } else if (extensions.has(path.extname(entry.name))) {
      files.push(fullPath);
    }
  }
  return files;
}

function assertStaticLogSafety() {
  const files = [
    ...sourceFiles(path.join(serverRoot, 'src'), new Set(['.js'])),
    ...sourceFiles(path.join(repositoryRoot, 'client', 'lib'), new Set(['.dart'])),
  ];
  const logCallPattern =
    /(?:console\.(?:log|error|warn|debug)|debugPrint)\s*\(([\s\S]*?)\);/g;

  for (const file of files) {
    const source = fs.readFileSync(file, 'utf8');
    for (const match of source.matchAll(logCallPattern)) {
      const call = match[0];
      for (const forbidden of sensitiveLogTerms) {
        assert.equal(
          forbidden.test(call),
          false,
          `Sensitive value may reach a log in ${path.relative(repositoryRoot, file)}: ${call}`,
        );
      }
    }
  }
}

function assertClientErrorSanitization() {
  const source = fs.readFileSync(
    path.join(serverRoot, 'src', 'server.js'),
    'utf8',
  );
  assert.doesNotMatch(
    source,
    /error\??\.message/,
    'Raw exception messages must not be returned to HTTP or realtime clients.',
  );
}

async function assertRuntimeLogSafety() {
  const port = 4196;
  const baseUrl = `http://127.0.0.1:${port}`;
  const testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'yappa-log-test-'));
  const dbPath = path.join(testDir, 'test.db');
  const sentinels = [
    'SENTINEL_PASSWORD_DO_NOT_LOG',
    'SENTINEL_BEARER_DO_NOT_LOG',
    'SENTINEL_PRIVATE_KEY_DO_NOT_LOG',
    'SENTINEL_SIGNATURE_DO_NOT_LOG',
    'SENTINEL_MESSAGE_DO_NOT_LOG',
  ];
  let output = '';
  const server = spawn(process.execPath, ['src/server.js'], {
    cwd: serverRoot,
    env: {
      ...process.env,
      PORT: String(port),
      DB_PATH: dbPath,
      CORS_ORIGIN: '',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  server.stdout.on('data', (chunk) => {
    output += chunk.toString();
  });
  server.stderr.on('data', (chunk) => {
    output += chunk.toString();
  });

  try {
    for (let attempt = 0; attempt < 50; attempt += 1) {
      try {
        const response = await fetch(`${baseUrl}/health`);
        if (response.ok) break;
      } catch (_) {
        // The disposable server is still starting.
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }

    await fetch(`${baseUrl}/api/auth/me`, {
      headers: { Authorization: `Bearer ${sentinels[1]}` },
    });
    await fetch(`${baseUrl}/api/auth/session`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        username: 'logsafety',
        password: sentinels[0],
        yuidPublicKey: sentinels[2],
        yuidSignature: sentinels[3],
        yuidNonce: 'invalid-log-safety-challenge',
        content: sentinels[4],
      }),
    });
    await new Promise((resolve) => setTimeout(resolve, 50));

    for (const sentinel of sentinels) {
      assert.equal(output.includes(sentinel), false, `${sentinel} reached logs`);
    }
  } finally {
    server.kill('SIGTERM');
    fs.rmSync(testDir, { recursive: true, force: true });
  }
}

async function assertMigrationFailureLogSafety() {
  const testDir = fs.mkdtempSync(
    path.join(os.tmpdir(), 'yappa-migration-log-test-'),
  );
  const dbPath = path.join(testDir, 'SENTINEL_DB_PATH_DO_NOT_LOG.db');
  const db = new Database(dbPath);
  db.exec(`
    CREATE TABLE schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at TEXT NOT NULL
    );
  `);
  db.prepare(
    'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
  ).run(CURRENT_SCHEMA_VERSION + 1, '2026-07-24T00:00:00.000Z');
  db.close();

  let output = '';
  const server = spawn(process.execPath, ['src/server.js'], {
    cwd: serverRoot,
    env: {...process.env, DB_PATH: dbPath},
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  server.stdout.on('data', (chunk) => {
    output += chunk.toString();
  });
  server.stderr.on('data', (chunk) => {
    output += chunk.toString();
  });
  try {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error('Migration refusal did not exit.')),
        5000,
      );
      server.once('exit', () => {
        clearTimeout(timer);
        resolve();
      });
    });
    assert.match(output, /code=unsupported_schema_version/);
    assert.equal(output.includes(dbPath), false);
    assert.equal(output.includes('SENTINEL_DB_PATH_DO_NOT_LOG'), false);
    assert.equal(output.includes('Database schema version'), false);
  } finally {
    server.kill('SIGTERM');
    fs.rmSync(testDir, {recursive: true, force: true});
  }
}

async function assertInvalidConfigurationFailsClosed() {
  for (const [name, sentinel] of [
    ['AUTH_RATE_LIMIT_MAX', 'SENTINEL_INVALID_RATE_LIMIT_DO_NOT_LOG'],
    ['ATTACHMENT_SIGNING_SECRET', 'short-secret-sentinel'],
    ['LIVEKIT_API_SECRET', 'short-livekit-secret'],
  ]) {
    let output = '';
    const server = spawn(process.execPath, ['src/server.js'], {
      cwd: serverRoot,
      env: {
        ...process.env,
        [name]: sentinel,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    server.stdout.on('data', (chunk) => {
      output += chunk.toString();
    });
    server.stderr.on('data', (chunk) => {
      output += chunk.toString();
    });
    try {
      const exitCode = await new Promise((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error('Invalid configuration did not exit.')),
          5000,
        );
        server.once('exit', (code) => {
          clearTimeout(timer);
          resolve(code);
        });
      });
      assert.notEqual(exitCode, 0);
      assert.match(output, /code=invalid_configuration/);
      assert.equal(output.includes(sentinel), false);
      assert.equal(output.includes(name), false);
      assert.equal(output.includes(serverRoot), false);
    } finally {
      server.kill('SIGTERM');
    }
  }
}

async function run() {
  assertStaticLogSafety();
  assertClientErrorSanitization();
  await assertRuntimeLogSafety();
  await assertMigrationFailureLogSafety();
  await assertInvalidConfigurationFailsClosed();
  process.stdout.write('Log safety test passed.\n');
}

run().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
