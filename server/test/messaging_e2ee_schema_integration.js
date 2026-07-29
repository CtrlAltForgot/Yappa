const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const Database = require('better-sqlite3');
const { createDb, CURRENT_SCHEMA_VERSION } = require('../src/db');

const testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'yappa-mls-schema-test-'));
const dbPath = path.join(testDir, 'legacy.db');

function columns(db, table) {
  return db
    .prepare(`PRAGMA table_info(${table})`)
    .all()
    .map((column) => column.name);
}

try {
  const legacy = new Database(dbPath);
  legacy.exec(`
    CREATE TABLE channels (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL UNIQUE,
      type TEXT NOT NULL,
      position INTEGER NOT NULL,
      glyph TEXT,
      created_at TEXT
    );
    CREATE TABLE messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      channel_id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      content TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
    INSERT INTO channels (id, name, type, position, created_at)
    VALUES (1, 'legacy-general', 'text', 1, '2026-07-24T00:00:00.000Z');
    INSERT INTO messages (channel_id, user_id, content, created_at)
    VALUES (1, 1, 'honestly retained legacy plaintext',
      '2026-07-24T00:00:00.000Z');
  `);
  legacy.close();

  const db = createDb(dbPath, {
    serverName: 'MLS schema test',
    serverDescription: 'Schema migration test',
  });

  const migrated = db
    .prepare(
      'SELECT encryption_mode, encryption_version FROM channels WHERE id = 1',
    )
    .get();
  assert.deepEqual(migrated, {
    encryption_mode: 'legacy',
    encryption_version: 0,
  });
  assert.equal(
    db.prepare('SELECT content FROM messages WHERE id = 1').get().content,
    'honestly retained legacy plaintext',
  );

  const requiredTables = [
    'schema_migrations',
    'mls_key_packages',
    'mls_channel_state',
    'mls_delivery_messages',
    'mls_device_cursors',
    'encrypted_message_events',
    'encrypted_attachments',
  ];
  const tableNames = new Set(
    db
      .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
      .all()
      .map((row) => row.name),
  );
  for (const table of requiredTables) {
    assert.equal(tableNames.has(table), true, `Missing ${table}`);
  }
  assert.equal(
    db
      .prepare('SELECT MAX(version) AS version FROM schema_migrations')
      .get().version,
    CURRENT_SCHEMA_VERSION,
  );

  const eventColumns = columns(db, 'encrypted_message_events');
  const attachmentColumns = columns(db, 'encrypted_attachments');
  for (const forbidden of [
    'content',
    'body',
    'plaintext',
    'original_name',
    'mime_type',
    'plaintext_size_bytes',
  ]) {
    assert.equal(
      eventColumns.includes(forbidden),
      false,
      `Encrypted events must not store ${forbidden}`,
    );
    assert.equal(
      attachmentColumns.includes(forbidden),
      false,
      `Encrypted attachments must not store ${forbidden}`,
    );
  }
  assert.equal(eventColumns.includes('delivery_message_id'), true);
  assert.equal(
    columns(db, 'mls_delivery_messages').includes('recipient_device_id'),
    true,
  );
  assert.equal(
    columns(db, 'mls_delivery_messages').includes('client_operation_id'),
    true,
  );
  assert.equal(
    db
      .prepare(`
        SELECT COUNT(*) AS count
        FROM sqlite_master
        WHERE type = 'index'
        AND name = 'idx_mls_delivery_device_operation'
      `)
      .get().count,
    1,
  );
  assert.equal(
    db
      .prepare(`
        SELECT COUNT(*) AS count
        FROM sqlite_master
        WHERE type = 'index'
        AND name = 'idx_messages_channel_id_id'
      `)
      .get().count,
    1,
  );
  const historyQueryPlan = db
    .prepare(`
      EXPLAIN QUERY PLAN
      SELECT id
      FROM messages
      WHERE channel_id = ? AND id < ?
      ORDER BY id DESC
      LIMIT ?
    `)
    .all(1, Number.MAX_SAFE_INTEGER, 50)
    .map((row) => row.detail)
    .join('\n');
  assert.match(
    historyQueryPlan,
    /idx_messages_channel_id_id \(channel_id=\? AND id<\?\)/,
  );
  assert.equal(attachmentColumns.includes('ciphertext_sha256'), true);
  assert.equal(attachmentColumns.includes('secretstream_header'), true);

  db.prepare(`
    UPDATE channels
    SET encryption_mode = 'e2ee', encryption_version = 1
    WHERE id = 1
  `).run();
  assert.throws(
    () =>
      db.prepare(`
        UPDATE channels
        SET encryption_mode = 'legacy', encryption_version = 0
        WHERE id = 1
      `).run(),
    /channel encryption downgrade forbidden/,
  );
  assert.throws(
    () =>
      db.prepare(`
        UPDATE channels
        SET encryption_mode = 'e2ee', encryption_version = 0
        WHERE id = 1
      `).run(),
    /channel encryption downgrade forbidden/,
  );

  const triggerNames = new Set(
    db
      .prepare("SELECT name FROM sqlite_master WHERE type = 'trigger'")
      .all()
      .map((row) => row.name),
  );
  assert.equal(triggerNames.has('channels_encryption_mode_insert_guard'), true);
  assert.equal(triggerNames.has('channels_encryption_mode_update_guard'), true);

  db.close();

  const versionOnePath = path.join(testDir, 'version-one.db');
  const versionOne = new Database(versionOnePath);
  versionOne.exec(`
    CREATE TABLE schema_migrations (
      version INTEGER PRIMARY KEY CHECK (version > 0),
      applied_at TEXT NOT NULL
    );
    INSERT INTO schema_migrations (version, applied_at)
    VALUES (1, '2026-07-24T00:00:00.000Z');
    CREATE TABLE mls_delivery_messages (
      id TEXT PRIMARY KEY,
      channel_id INTEGER NOT NULL,
      server_sequence INTEGER NOT NULL,
      message_class TEXT NOT NULL,
      accepted_epoch INTEGER NOT NULL,
      parent_epoch INTEGER,
      uploader_user_id INTEGER NOT NULL,
      uploader_device_id TEXT NOT NULL,
      recipient_device_id TEXT,
      wire_message BLOB NOT NULL,
      created_at TEXT NOT NULL,
      UNIQUE (channel_id, server_sequence)
    );
    INSERT INTO mls_delivery_messages (
      id, channel_id, server_sequence, message_class, accepted_epoch,
      parent_epoch, uploader_user_id, uploader_device_id,
      recipient_device_id, wire_message, created_at
    ) VALUES (
      'mls_existing-version-one', 42, 1, 'application', 0,
      NULL, 7, 'device_BBBBBBBBBBBBBBBBBBBBBBBB',
      NULL, X'010203', '2026-07-24T00:00:00.000Z'
    );
  `);
  versionOne.close();
  const upgraded = createDb(versionOnePath, {
    serverName: 'Version one upgrade',
    serverDescription: 'Preserve existing opaque delivery rows',
  });
  assert.equal(
    upgraded
      .prepare('SELECT MAX(version) AS version FROM schema_migrations')
      .get().version,
    CURRENT_SCHEMA_VERSION,
  );
  assert.equal(
    columns(upgraded, 'mls_delivery_messages').includes(
      'client_operation_id',
    ),
    true,
  );
  assert.deepEqual(
    upgraded
      .prepare(`
        SELECT id, hex(wire_message) AS wire, client_operation_id
        FROM mls_delivery_messages
        WHERE id = 'mls_existing-version-one'
      `)
      .get(),
    {
      id: 'mls_existing-version-one',
      wire: '010203',
      client_operation_id: null,
    },
  );
  upgraded.close();

  const versionTwoPath = path.join(testDir, 'version-two.db');
  const versionTwo = createDb(versionTwoPath, {
    serverName: 'Version two upgrade',
    serverDescription: 'Backfill MLS credential directory',
  });
  const createdAt = '2026-07-24T01:00:00.000Z';
  const userId = versionTwo.prepare(`
    INSERT INTO users (
      username, password_hash, created_at, username_normalized, role,
      yuid, yuid_public_key
    )
    VALUES ('credential-user', 'unused', ?, 'credential-user', 'member',
            'YUIDCREDENTIALTEST01', ?)
  `).run(createdAt, Buffer.alloc(32, 1).toString('base64url')).lastInsertRowid;
  const deviceId = `device_${'C'.repeat(24)}`;
  const signaturePublicKey = Buffer.alloc(32, 2).toString('base64url');
  const bindingSignature = Buffer.alloc(64, 3).toString('base64url');
  versionTwo.prepare(`
    INSERT INTO media_devices (
      id, user_id, public_key, yuid_authorization_signature,
      authorization_nonce, authorized_username, created_at, last_seen_at
    )
    VALUES (?, ?, ?, ?, 'nonce', 'credential-user', ?, ?)
  `).run(
    deviceId,
    userId,
    Buffer.alloc(32, 4).toString('base64url'),
    Buffer.alloc(64, 5).toString('base64url'),
    createdAt,
    createdAt,
  );
  versionTwo.prepare(`
    INSERT INTO mls_key_packages (
      id, device_id, ciphersuite, signature_public_key,
      identity_binding_signature, key_package, key_package_hash,
      created_at, expires_at
    )
    VALUES ('kp_version-two-backfill', ?, 1, ?, ?, X'010203',
            ?, ?, '2026-07-25T01:00:00.000Z')
  `).run(
    deviceId,
    signaturePublicKey,
    bindingSignature,
    crypto.createHash('sha256').update(Buffer.from([1, 2, 3])).digest('hex'),
    createdAt,
  );
  versionTwo.exec(`
    DROP TABLE mls_device_credentials;
    DELETE FROM schema_migrations;
    INSERT INTO schema_migrations (version, applied_at)
    VALUES (2, '2026-07-24T01:00:00.000Z');
  `);
  versionTwo.close();
  const versionThree = createDb(versionTwoPath, {
    serverName: 'Version two upgrade',
    serverDescription: 'Backfill MLS credential directory',
  });
  assert.deepEqual(
    versionThree
      .prepare(`
        SELECT device_id, signature_public_key, identity_binding_signature
        FROM mls_device_credentials
      `)
      .get(),
    {
      device_id: deviceId,
      signature_public_key: signaturePublicKey,
      identity_binding_signature: bindingSignature,
    },
  );
  versionThree.close();

  const futurePath = path.join(testDir, 'future.db');
  const future = new Database(futurePath);
  future.exec(`
    CREATE TABLE schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at TEXT NOT NULL
    );
    CREATE TABLE future_only_marker (id INTEGER PRIMARY KEY);
  `);
  future
    .prepare(
      'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
    )
    .run(CURRENT_SCHEMA_VERSION + 1, '2026-07-24T00:00:00.000Z');
  future.close();
  assert.throws(
    () =>
      createDb(futurePath, {
        serverName: 'Unsupported future schema',
        serverDescription: 'Must not be mutated',
      }),
    /newer than supported/,
  );
  const futureCheck = new Database(futurePath);
  assert.equal(
    futureCheck
      .prepare(
        "SELECT COUNT(*) AS count FROM sqlite_master WHERE type = 'table' AND name = 'users'",
      )
      .get().count,
    0,
  );
  assert.equal(
    futureCheck
      .prepare('SELECT MAX(version) AS version FROM schema_migrations')
      .get().version,
    CURRENT_SCHEMA_VERSION + 1,
  );
  futureCheck.close();

  const failingPath = path.join(testDir, 'failing.db');
  const failing = new Database(failingPath);
  failing.exec(`
    CREATE TABLE users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT NOT NULL,
      password_hash TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
    INSERT INTO users (username, password_hash, created_at)
    VALUES
      ('Duplicate', 'hash-one', '2026-07-24T00:00:00.000Z'),
      ('duplicate', 'hash-two', '2026-07-24T00:00:00.000Z');
  `);
  failing.close();
  assert.throws(
    () =>
      createDb(failingPath, {
        serverName: 'Atomic failure schema',
        serverDescription: 'Must roll back',
      }),
    /UNIQUE constraint failed/,
  );
  const failingCheck = new Database(failingPath);
  assert.equal(columns(failingCheck, 'users').includes('username_normalized'), false);
  assert.equal(
    failingCheck
      .prepare(
        "SELECT COUNT(*) AS count FROM sqlite_master WHERE type = 'table' AND name = 'schema_migrations'",
      )
      .get().count,
    0,
  );
  assert.equal(
    failingCheck.prepare('SELECT COUNT(*) AS count FROM users').get().count,
    2,
  );
  failingCheck.close();

  process.stdout.write('Messaging E2EE schema integration test passed.\n');
} finally {
  fs.rmSync(testDir, { recursive: true, force: true });
}
