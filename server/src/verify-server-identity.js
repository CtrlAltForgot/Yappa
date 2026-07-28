const crypto = require('crypto');

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

async function readJson(url, timeoutMs = 10_000) {
  const response = await fetch(url, {
    headers: {accept: 'application/json'},
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }
  return response.json();
}

async function main() {
  if (process.argv.length !== 3) {
    fail('Usage: node src/verify-server-identity.js http://127.0.0.1:4100');
  }
  const baseUrl = new URL(process.argv[2]);
  if (!['http:', 'https:'].includes(baseUrl.protocol)) {
    fail('Verification URL must use HTTP or HTTPS.');
  }
  if (
    baseUrl.username ||
    baseUrl.password ||
    (baseUrl.pathname !== '/' && baseUrl.pathname !== '') ||
    baseUrl.search ||
    baseUrl.hash
  ) {
    fail('Verification URL must be an origin without credentials or a path.');
  }

  const origin = baseUrl.origin;
  const health = await readJson(`${origin}/health`);
  if (health?.ok !== true || typeof health.time !== 'string') {
    fail('Yappa health response is invalid.');
  }

  const serverResponse = await readJson(`${origin}/api/server`);
  const serverId = String(serverResponse?.server?.id || '');
  if (!/^srv_[a-f0-9]{32}$/.test(serverId)) {
    fail('Yappa server response has an invalid server id.');
  }

  const nonce = crypto.randomBytes(32).toString('base64url');
  const identityResponse = await readJson(
    `${origin}/api/server/identity?nonce=${encodeURIComponent(nonce)}`,
  );
  const identity = identityResponse?.identity;
  if (
    identity?.serverId !== serverId ||
    identity?.algorithm !== 'Ed25519' ||
    identity?.nonce !== nonce ||
    !/^[A-Za-z0-9_-]{43}$/.test(String(identity?.publicKey || '')) ||
    !/^[A-Za-z0-9_-]{86}$/.test(String(identity?.signature || ''))
  ) {
    fail('Yappa server identity response is invalid.');
  }

  const publicKey = crypto.createPublicKey({
    key: {
      kty: 'OKP',
      crv: 'Ed25519',
      x: identity.publicKey,
    },
    format: 'jwk',
  });
  const proof = Buffer.from(
    `yappa-server-proof-v1|${serverId}|${nonce}`,
    'utf8',
  );
  if (
    !crypto.verify(
      null,
      proof,
      publicKey,
      Buffer.from(identity.signature, 'base64url'),
    )
  ) {
    fail('Yappa server identity signature is invalid.');
  }

  process.stdout.write(
    `${JSON.stringify({
      ok: true,
      serverId,
      publicKey: identity.publicKey,
    })}\n`,
  );
}

main().catch(() => {
  fail('Yappa server identity verification failed.');
});
