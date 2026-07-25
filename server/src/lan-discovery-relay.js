const dgram = require('dgram');
const net = require('net');

const protocol = 'yappa-lan-discovery-v1';
const noncePattern = /^[A-Za-z0-9_-]{22,128}$/;

function isPrivateIpv4(address) {
  if (net.isIP(address) !== 4) return false;
  const [a, b] = address.split('.').map(Number);
  return (
    a === 10 ||
    a === 127 ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168)
  );
}

function parsePort(value, fallback, allowZero = false) {
  const parsed = Number(value ?? fallback);
  if (
    !Number.isSafeInteger(parsed) ||
    parsed < (allowZero ? 0 : 1) ||
    parsed > 65535
  ) {
    throw new Error('Invalid LAN discovery relay port.');
  }
  return parsed;
}

function decodePacket(message, maximumBytes) {
  if (!Buffer.isBuffer(message) || message.length > maximumBytes) return null;
  try {
    const packet = JSON.parse(message.toString('utf8'));
    const nonce = String(packet?.nonce || '').trim();
    if (packet?.protocol !== protocol || !noncePattern.test(nonce)) return null;
    return { packet, nonce };
  } catch {
    return null;
  }
}

function createLanDiscoveryRelay(options = {}) {
  const listenHost = options.listenHost || '0.0.0.0';
  const listenPort = parsePort(
    options.listenPort,
    41200,
    options.allowEphemeralListenPort === true,
  );
  const backendHost = options.backendHost || '127.0.0.1';
  const backendPort = parsePort(options.backendPort, 41201);
  const socket = options.socket || dgram.createSocket('udp4');
  const pending = new Map();
  const rates = new Map();

  socket.on('message', (message, remote) => {
    const fromBackend =
      remote.address === backendHost && remote.port === backendPort;
    const decoded = decodePacket(message, fromBackend ? 2048 : 512);
    if (!decoded) return;

    const now = Date.now();
    if (fromBackend) {
      const client = pending.get(decoded.nonce);
      if (!client || client.expiresAt <= now) return;
      pending.delete(decoded.nonce);
      socket.send(message, client.port, client.address);
      return;
    }

    if (!isPrivateIpv4(remote.address) || pending.has(decoded.nonce)) return;
    const previous = rates.get(remote.address);
    const rate =
      !previous || previous.resetAt <= now
        ? { count: 0, resetAt: now + 60_000 }
        : previous;
    rate.count += 1;
    rates.set(remote.address, rate);
    if (rate.count > 30) return;

    pending.set(decoded.nonce, {
      address: remote.address,
      port: remote.port,
      expiresAt: now + 5000,
    });
    const forwarded = Buffer.from(
      JSON.stringify({
        ...decoded.packet,
        relayClientAddress: remote.address,
      }),
      'utf8',
    );
    socket.send(forwarded, backendPort, backendHost);

    if (pending.size > 1000 || rates.size > 1000) {
      for (const [nonce, entry] of pending) {
        if (entry.expiresAt <= now) pending.delete(nonce);
      }
      for (const [address, entry] of rates) {
        if (entry.resetAt <= now) rates.delete(address);
      }
    }
  });

  socket.on('error', () => {
    process.stderr.write('LAN discovery relay socket failure.\n');
  });
  socket.bind(listenPort, listenHost);
  return socket;
}

if (require.main === module) {
  createLanDiscoveryRelay({
    listenHost: process.env.LAN_DISCOVERY_RELAY_HOST || '0.0.0.0',
    listenPort: process.env.LAN_DISCOVERY_RELAY_PORT || 41200,
    backendHost: process.env.LAN_DISCOVERY_BACKEND_HOST || '127.0.0.1',
    backendPort: process.env.LAN_DISCOVERY_BACKEND_PORT || 41201,
  });
}

module.exports = { createLanDiscoveryRelay, isPrivateIpv4 };
