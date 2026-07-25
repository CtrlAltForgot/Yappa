const assert = require('assert');
const { createPinnedLookup } = require('../src/safe-preview-lookup');

const lookup = createPinnedLookup({ address: '93.184.216.34', family: 4 });

lookup('example.com', { all: false }, (error, address, family) => {
  assert.ifError(error);
  assert.equal(address, '93.184.216.34');
  assert.equal(family, 4);
});

lookup('example.com', { all: true }, (error, addresses) => {
  assert.ifError(error);
  assert.deepEqual(addresses, [{ address: '93.184.216.34', family: 4 }]);
});

assert.throws(
  () => createPinnedLookup({ address: '', family: 4 }),
  /Invalid pinned preview address/,
);

process.stdout.write('Safe preview lookup test passed.\n');
