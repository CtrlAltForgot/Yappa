function createPinnedLookup(target) {
  const address = String(target?.address || '').trim();
  const family = Number(target?.family);
  if (!address || (family !== 4 && family !== 6)) {
    throw new Error('Invalid pinned preview address.');
  }

  return (_hostname, options, callback) => {
    if (options?.all === true) {
      callback(null, [{ address, family }]);
      return;
    }
    callback(null, address, family);
  };
}

module.exports = { createPinnedLookup };
