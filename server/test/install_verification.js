const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const {execFile} = require('child_process');

const serverRoot = path.resolve(__dirname, '..');
const verifier = path.join(
  serverRoot,
  'src',
  'verify-server-identity.js',
);

function executeVerifier(origin) {
  return new Promise((resolve) => {
    execFile(
      process.execPath,
      [verifier, origin],
      {
        cwd: serverRoot,
        encoding: 'utf8',
        timeout: 15_000,
      },
      (error, stdout, stderr) => resolve({error, stdout, stderr}),
    );
  });
}

async function run() {
  const keyPair = crypto.generateKeyPairSync('ed25519');
  const publicJwk = keyPair.publicKey.export({format: 'jwk'});
  const serverId = `srv_${crypto.randomBytes(16).toString('hex')}`;
  let tamperSignature = false;
  const upgradedSockets = new Set();

  const testServer = http.createServer((request, response) => {
    response.setHeader('content-type', 'application/json');
    if (request.url === '/health') {
      response.end(
        JSON.stringify({ok: true, time: new Date().toISOString()}),
      );
      return;
    }
    if (request.url === '/api/server') {
      response.end(JSON.stringify({ok: true, server: {id: serverId}}));
      return;
    }
    if (request.url === '/rtc') {
      response.statusCode = 401;
      response.end(JSON.stringify({ok: false}));
      return;
    }
    const parsedUrl = new URL(request.url, 'http://127.0.0.1');
    if (parsedUrl.pathname === '/api/server/identity') {
      const nonce = parsedUrl.searchParams.get('nonce');
      const proof = Buffer.from(
        `yappa-server-proof-v1|${serverId}|${nonce}`,
        'utf8',
      );
      const signature = crypto.sign(null, proof, keyPair.privateKey);
      if (tamperSignature) {
        signature[0] ^= 0x80;
      }
      response.end(
        JSON.stringify({
          ok: true,
          identity: {
            serverId,
            algorithm: 'Ed25519',
            publicKey: publicJwk.x,
            nonce,
            signature: signature.toString('base64url'),
          },
        }),
      );
      return;
    }
    response.statusCode = 404;
    response.end(JSON.stringify({ok: false}));
  });
  testServer.on('upgrade', (request, socket) => {
    if (
      !request.url.startsWith('/socket.io/') ||
      request.headers.upgrade?.toLowerCase() !== 'websocket'
    ) {
      socket.destroy();
      return;
    }
    const accept = crypto
      .createHash('sha1')
      .update(
        `${request.headers['sec-websocket-key']}` +
          '258EAFA5-E914-47DA-95CA-C5AB0DC85B11',
      )
      .digest('base64');
    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n' +
        'Connection: Upgrade\r\n' +
        'Upgrade: websocket\r\n' +
        `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
    );
    upgradedSockets.add(socket);
    socket.on('close', () => upgradedSockets.delete(socket));
  });

  await new Promise((resolve) => {
    testServer.listen(0, '127.0.0.1', resolve);
  });
  try {
    const address = testServer.address();
    const origin = `http://127.0.0.1:${address.port}`;
    const valid = await executeVerifier(origin);
    assert.equal(valid.error, null, valid.stderr);
    assert.deepEqual(JSON.parse(valid.stdout), {
      ok: true,
      serverId,
      publicKey: publicJwk.x,
    });
    assert.equal(valid.stderr, '');

    tamperSignature = true;
    const tampered = await executeVerifier(origin);
    assert.ok(tampered.error);
    assert.equal(tampered.stdout, '');
    assert.match(
      tampered.stderr,
      /Yappa server identity signature is invalid/,
    );
    assert.equal(
      tampered.stderr.includes(serverId),
      false,
      'Identity verification failures must not include instance metadata.',
    );

    tamperSignature = false;
    const installationRoot = fs.mkdtempSync(
      path.join(os.tmpdir(), 'yappa-install-verifier-test-'),
    );
    try {
      const fakeBin = path.join(installationRoot, 'fake-bin');
      const dataRoot = path.join(installationRoot, 'data');
      const identityRoot = path.join(dataRoot, serverId);
      fs.mkdirSync(fakeBin);
      fs.mkdirSync(identityRoot, {recursive: true, mode: 0o700});
      fs.chmodSync(dataRoot, 0o700);
      fs.writeFileSync(
        path.join(installationRoot, '.env'),
        [
          'YAPPA_ADDRESS_MODE=lan',
          `YAPPA_HTTP_PORT=${address.port}`,
          'YAPPA_HTTPS_PORT=443',
          'DB_PATH=./data/newchat.db',
          '',
        ].join('\n'),
        {mode: 0o600},
      );
      fs.writeFileSync(path.join(dataRoot, 'newchat.db'), 'fixture', {
        mode: 0o600,
      });
      fs.writeFileSync(
        path.join(identityRoot, 'server-identity.json'),
        JSON.stringify({fixture: true}),
        {mode: 0o600},
      );
      fs.copyFileSync(
        path.join(serverRoot, 'verify-yappa-install.sh'),
        path.join(installationRoot, 'verify-yappa-install.sh'),
      );
      fs.chmodSync(
        path.join(installationRoot, 'verify-yappa-install.sh'),
        0o755,
      );
      fs.writeFileSync(
        path.join(installationRoot, 'install-manifest.json'),
        JSON.stringify({release: {databaseSchemaVersion: 3}}, null, 2),
        {mode: 0o600},
      );

      fs.writeFileSync(
        path.join(fakeBin, 'sqlite3'),
        `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${*: -1}" == "PRAGMA quick_check;" ]]; then
  echo ok
else
  echo "\${MOCK_SCHEMA_VERSION:-3}"
fi
`,
        {mode: 0o755},
      );
      fs.writeFileSync(
        path.join(fakeBin, 'docker'),
        `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "inspect" ]]; then
  echo healthy
elif [[ "\${1:-} \${2:-} \${3:-}" == "compose ps --status" ]]; then
  printf '%s\\n' newchat-node yappa-discovery yappa-livekit yappa-proxy
elif [[ "\${1:-} \${2:-} \${3:-}" == "compose exec -T" ]]; then
  printf '{"ok":true,"serverId":"%s","publicKey":"%s"}\\n' \
    "\${MOCK_SERVER_ID}" "\${MOCK_PUBLIC_KEY}"
else
  echo "Unexpected docker fixture arguments: $*" >&2
  exit 1
fi
`,
        {mode: 0o755},
      );

      const verificationEnvironment = {
        ...process.env,
        PATH: `${fakeBin}:${process.env.PATH}`,
        MOCK_SERVER_ID: serverId,
        MOCK_PUBLIC_KEY: publicJwk.x,
      };
      const operational = await new Promise((resolve) => {
        execFile(
          path.join(installationRoot, 'verify-yappa-install.sh'),
          [],
          {
            cwd: installationRoot,
            encoding: 'utf8',
            env: verificationEnvironment,
            timeout: 20_000,
          },
          (error, stdout, stderr) => resolve({error, stdout, stderr}),
        );
      });
      assert.equal(operational.error, null, operational.stderr);
      assert.match(operational.stdout, /Yappa installation verification passed/);
      assert.match(operational.stdout, /Schema:[ ]+3/);
      assert.match(operational.stdout, /WebSocket upgrade verified/);
      assert.match(operational.stdout, /guarded endpoint reached/);
      assert.match(
        operational.stdout,
        /forced TURN, and real media remain separate release tests/,
      );
      assert.equal(operational.stderr, '');

      const wrongSchema = await new Promise((resolve) => {
        execFile(
          path.join(installationRoot, 'verify-yappa-install.sh'),
          [],
          {
            cwd: installationRoot,
            encoding: 'utf8',
            env: {...verificationEnvironment, MOCK_SCHEMA_VERSION: '2'},
            timeout: 20_000,
          },
          (error, stdout, stderr) => resolve({error, stdout, stderr}),
        );
      });
      assert.ok(wrongSchema.error);
      assert.equal(wrongSchema.stdout, '');
      assert.match(
        wrongSchema.stderr,
        /database schema does not match the install manifest/,
      );
    } finally {
      fs.rmSync(installationRoot, {recursive: true, force: true});
    }
  } finally {
    for (const socket of upgradedSockets) {
      socket.destroy();
    }
    await new Promise((resolve, reject) => {
      testServer.close((error) => (error ? reject(error) : resolve()));
    });
  }
}

run()
  .then(() => {
    process.stdout.write('Install identity verification test passed.\n');
  })
  .catch((error) => {
    process.stderr.write(`${error.stack || error}\n`);
    process.exitCode = 1;
  });
