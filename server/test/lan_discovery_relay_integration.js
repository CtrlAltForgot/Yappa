const assert = require('assert');
const dgram = require('dgram');
const {
  createLanDiscoveryRelay,
  isPrivateIpv4,
} = require('../src/lan-discovery-relay');

function bind(socket, port = 0, host = '127.0.0.1') {
  return new Promise((resolve) => {
    socket.bind(port, host, () => resolve(socket.address().port));
  });
}

function receive(socket) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error('UDP relay test timed out.')),
      2000,
    );
    socket.once('message', (message, remote) => {
      clearTimeout(timeout);
      resolve({ message, remote });
    });
  });
}

async function main() {
  assert.equal(isPrivateIpv4('192.168.1.20'), true);
  assert.equal(isPrivateIpv4('10.0.0.1'), true);
  assert.equal(isPrivateIpv4('8.8.8.8'), false);

  const backend = dgram.createSocket('udp4');
  const backendPort = await bind(backend);
  const relay = createLanDiscoveryRelay({
    listenHost: '127.0.0.1',
    listenPort: 0,
    allowEphemeralListenPort: true,
    backendPort,
  });
  await new Promise((resolve) => relay.once('listening', resolve));
  const client = dgram.createSocket('udp4');
  await bind(client);
  const nonce = 'abcdefghijklmnopqrstuv';
  const request = Buffer.from(
    JSON.stringify({
      protocol: 'yappa-lan-discovery-v1',
      nonce,
      relayClientAddress: '8.8.8.8',
    }),
  );

  const backendReceipt = receive(backend);
  client.send(request, relay.address().port, '127.0.0.1');
  const forwarded = await backendReceipt;
  const forwardedPacket = JSON.parse(forwarded.message.toString('utf8'));
  assert.equal(forwardedPacket.relayClientAddress, '127.0.0.1');

  const responseReceipt = receive(client);
  const response = Buffer.from(
    JSON.stringify({ protocol: 'yappa-lan-discovery-v1', nonce }),
  );
  backend.send(response, forwarded.remote.port, forwarded.remote.address);
  const delivered = await responseReceipt;
  assert.deepEqual(delivered.message, response);

  backend.close();
  relay.close();
  client.close();
  process.stdout.write('LAN discovery relay integration test passed.\n');
}

main().catch((error) => {
  process.stderr.write(`${error.stack}\n`);
  process.exitCode = 1;
});
