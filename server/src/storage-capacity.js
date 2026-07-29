const fs = require('fs');
const path = require('path');

function safeByteNumber(value) {
  const numeric = typeof value === 'bigint' ? value : BigInt(value || 0);
  if (numeric <= 0n) return 0;
  const maximum = BigInt(Number.MAX_SAFE_INTEGER);
  return Number(numeric > maximum ? maximum : numeric);
}

function fileBytes(fsModule, filePath) {
  try {
    const stat = fsModule.statSync(filePath, { bigint: true });
    return stat.isFile() ? safeByteNumber(stat.size) : 0;
  } catch (error) {
    if (error?.code === 'ENOENT') return 0;
    throw error;
  }
}

function directoryBytes(fsModule, rootPath) {
  if (!rootPath) return null;
  let total = 0;
  const pending = [rootPath];
  while (pending.length > 0) {
    const current = pending.pop();
    let entries;
    try {
      entries = fsModule.readdirSync(current, { withFileTypes: true });
    } catch (error) {
      if (error?.code === 'ENOENT') return 0;
      throw error;
    }
    for (const entry of entries) {
      const entryPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        pending.push(entryPath);
      } else if (entry.isFile()) {
        total += fileBytes(fsModule, entryPath);
        if (total >= Number.MAX_SAFE_INTEGER) {
          return Number.MAX_SAFE_INTEGER;
        }
      }
    }
  }
  return total;
}

function readStorageCapacity({
  db,
  dbPath,
  dataRoot,
  backupRoot = '',
  warningFreeBytes,
  criticalFreeBytes,
  incomingBytes = 0,
  includeBackupSize = false,
  fsModule = fs,
}) {
  try {
    const filesystem = fsModule.statfsSync(dataRoot, { bigint: true });
    const availableBytes = safeByteNumber(
      filesystem.bavail * filesystem.bsize,
    );
    const totalBytes = safeByteNumber(filesystem.blocks * filesystem.bsize);
    const expectedBytes = Math.max(
      0,
      Math.min(Number.MAX_SAFE_INTEGER, Number(incomingBytes) || 0),
    );
    const availableAfterWriteBytes = Math.max(
      0,
      availableBytes - expectedBytes,
    );
    const databaseBytes = [dbPath, `${dbPath}-wal`, `${dbPath}-shm`]
      .map((item) => fileBytes(fsModule, item))
      .reduce((sum, value) => sum + value, 0);
    const attachmentSizes = db.prepare(`
      SELECT
        (SELECT COALESCE(SUM(size_bytes), 0)
         FROM attachments
         WHERE deleted_at IS NULL) AS ordinary_bytes,
        (SELECT COALESCE(SUM(ciphertext_size_bytes), 0)
         FROM encrypted_attachments
         WHERE deleted_at IS NULL) AS encrypted_bytes
    `).get();
    const ordinaryAttachmentBytes = safeByteNumber(
      attachmentSizes.ordinary_bytes,
    );
    const encryptedAttachmentBytes = safeByteNumber(
      attachmentSizes.encrypted_bytes,
    );
    const backupBytes = includeBackupSize
      ? directoryBytes(fsModule, backupRoot)
      : null;

    let status = 'healthy';
    if (availableAfterWriteBytes < criticalFreeBytes) {
      status = 'critical';
    } else if (availableAfterWriteBytes < warningFreeBytes) {
      status = 'warning';
    }

    return {
      available: true,
      status,
      acceptsDurableWrites: status !== 'critical',
      filesystem: {
        availableBytes,
        availableAfterWriteBytes,
        totalBytes,
      },
      thresholds: {
        warningFreeBytes,
        criticalFreeBytes,
      },
      usage: {
        databaseBytes,
        ordinaryAttachmentBytes,
        encryptedAttachmentBytes,
        backupBytes,
        backupMonitoringEnabled: Boolean(backupRoot),
      },
    };
  } catch (_) {
    return {
      available: false,
      status: 'unavailable',
      acceptsDurableWrites: false,
      filesystem: null,
      thresholds: {
        warningFreeBytes,
        criticalFreeBytes,
      },
      usage: null,
    };
  }
}

module.exports = {
  readStorageCapacity,
};
