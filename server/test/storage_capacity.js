const assert = require('assert');

const { readStorageCapacity } = require('../src/storage-capacity');

function fakeDb() {
  return {
    prepare() {
      return {
        get() {
          return {
            ordinary_bytes: 1200,
            encrypted_bytes: 3400,
          };
        },
      };
    },
  };
}

function fakeFs({ availableBytes = 4096, fail = false } = {}) {
  return {
    statfsSync() {
      if (fail) throw Object.assign(new Error('unavailable'), { code: 'EIO' });
      return {
        bavail: BigInt(availableBytes),
        bsize: 1n,
        blocks: 16384n,
      };
    },
    statSync(filePath) {
      const sizes = {
        '/data/yappa.db': 100,
        '/data/yappa.db-wal': 20,
        '/data/yappa.db-shm': 10,
        '/backups/one.age': 700,
      };
      if (!(filePath in sizes)) {
        throw Object.assign(new Error('missing'), { code: 'ENOENT' });
      }
      return {
        isFile: () => true,
        size: BigInt(sizes[filePath]),
      };
    },
    readdirSync(directory) {
      if (directory !== '/backups') {
        throw Object.assign(new Error('missing'), { code: 'ENOENT' });
      }
      return [
        {
          name: 'one.age',
          isDirectory: () => false,
          isFile: () => true,
        },
      ];
    },
  };
}

const healthy = readStorageCapacity({
  db: fakeDb(),
  dbPath: '/data/yappa.db',
  dataRoot: '/data',
  backupRoot: '/backups',
  warningFreeBytes: 2048,
  criticalFreeBytes: 1024,
  includeBackupSize: true,
  fsModule: fakeFs(),
});
assert.equal(healthy.status, 'healthy');
assert.equal(healthy.acceptsDurableWrites, true);
assert.equal(healthy.usage.databaseBytes, 130);
assert.equal(healthy.usage.ordinaryAttachmentBytes, 1200);
assert.equal(healthy.usage.encryptedAttachmentBytes, 3400);
assert.equal(healthy.usage.backupBytes, 700);

const warning = readStorageCapacity({
  db: fakeDb(),
  dbPath: '/data/yappa.db',
  dataRoot: '/data',
  warningFreeBytes: 4096,
  criticalFreeBytes: 1024,
  incomingBytes: 1,
  fsModule: fakeFs(),
});
assert.equal(warning.status, 'warning');
assert.equal(warning.acceptsDurableWrites, true);

const critical = readStorageCapacity({
  db: fakeDb(),
  dbPath: '/data/yappa.db',
  dataRoot: '/data',
  warningFreeBytes: 4096,
  criticalFreeBytes: 1024,
  incomingBytes: 3500,
  fsModule: fakeFs(),
});
assert.equal(critical.status, 'critical');
assert.equal(critical.acceptsDurableWrites, false);
assert.equal(critical.filesystem.availableAfterWriteBytes, 596);

const unavailable = readStorageCapacity({
  db: fakeDb(),
  dbPath: '/data/yappa.db',
  dataRoot: '/data',
  warningFreeBytes: 4096,
  criticalFreeBytes: 1024,
  fsModule: fakeFs({ fail: true }),
});
assert.equal(unavailable.status, 'unavailable');
assert.equal(unavailable.acceptsDurableWrites, false);
assert.equal(unavailable.filesystem, null);

process.stdout.write('Durable storage capacity test passed.\n');
