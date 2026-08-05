const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const Database = require('better-sqlite3');

const CURRENT_SCHEMA_VERSION = 6;

function ensureDirForFile(filePath) {
  const dir = path.dirname(filePath);
  fs.mkdirSync(dir, { recursive: true });
}

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function nowIso() {
  return new Date().toISOString();
}

function randomId(prefix) {
  return `${prefix}_${crypto.randomBytes(8).toString('hex')}`;
}

function hashSessionToken(token) {
  return crypto
    .createHash('sha256')
    .update(String(token || ''), 'utf8')
    .digest('hex');
}

function sessionTokenStorageValue(token) {
  return `sha256:${hashSessionToken(token)}`;
}

function hasColumn(db, tableName, columnName) {
  const columns = db.prepare(`PRAGMA table_info(${tableName})`).all();
  return columns.some((column) => column.name === columnName);
}

function readSchemaVersion(db) {
  const table = db
    .prepare(`
      SELECT name
      FROM sqlite_master
      WHERE type = 'table' AND name = 'schema_migrations'
    `)
    .get();
  if (!table) return 0;
  return Number(
    db
      .prepare('SELECT COALESCE(MAX(version), 0) AS version FROM schema_migrations')
      .get().version,
  );
}

function unsupportedSchemaVersion(version) {
  const error = new Error(
    `Database schema version ${version} is newer than supported ` +
      `version ${CURRENT_SCHEMA_VERSION}. Refusing to open it.`,
  );
  error.code = 'unsupported_schema_version';
  return error;
}

function createBaseTables(db) {
  db.exec(`
  CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY CHECK (version > 0),
    applied_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS server_config (
    id INTEGER PRIMARY KEY CHECK (id = 1),
                                            server_id TEXT NOT NULL UNIQUE,
                                            name TEXT NOT NULL,
                                            description TEXT NOT NULL,
                                            branding_json TEXT NOT NULL DEFAULT '{}',
                                            owner_user_id INTEGER,
                                            created_at TEXT NOT NULL,
                                            updated_at TEXT NOT NULL,
                                            FOREIGN KEY (owner_user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TEXT NOT NULL,
    username_normalized TEXT,
    role TEXT NOT NULL DEFAULT 'member',
    display_name TEXT,
    avatar_url TEXT,
    last_login_at TEXT,
    yuid TEXT,
    yuid_public_key TEXT,
    yuid_bound_at TEXT,
    yuid_last_seen_at TEXT
  );

  CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    token TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    expires_at TEXT,
    idle_expires_at TEXT,
    device_name TEXT,
    media_device_id TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS media_devices (
    id TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL,
    public_key TEXT NOT NULL UNIQUE,
    yuid_authorization_signature TEXT NOT NULL,
    authorization_nonce TEXT NOT NULL,
    authorized_username TEXT NOT NULL,
    created_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    revoked_at TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS history_recovery_device_keys (
    device_id TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL,
    public_key TEXT NOT NULL UNIQUE,
    yuid_authorization_signature TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (device_id) REFERENCES media_devices(id),
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS history_recovery_transfers (
    id TEXT PRIMARY KEY,
    channel_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL,
    source_device_id TEXT NOT NULL,
    destination_device_id TEXT NOT NULL,
    first_server_sequence INTEGER NOT NULL CHECK (first_server_sequence >= 1),
    last_server_sequence INTEGER NOT NULL CHECK (
      last_server_sequence >= first_server_sequence
    ),
    event_count INTEGER NOT NULL CHECK (event_count >= 1),
    chunk_count INTEGER NOT NULL CHECK (chunk_count BETWEEN 1 AND 1024),
    total_bytes INTEGER NOT NULL CHECK (
      total_bytes BETWEEN 1 AND 268435456
    ),
    manifest BLOB NOT NULL,
    manifest_sha256 TEXT NOT NULL,
    yuid_signature TEXT NOT NULL,
    state TEXT NOT NULL CHECK (
      state IN ('uploading', 'ready', 'consumed', 'canceled', 'expired')
    ),
    uploaded_chunks INTEGER NOT NULL DEFAULT 0,
    uploaded_bytes INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    ready_at TEXT,
    consumed_at TEXT,
    canceled_at TEXT,
    expires_at TEXT NOT NULL,
    FOREIGN KEY (channel_id) REFERENCES channels(id),
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (source_device_id) REFERENCES media_devices(id),
    FOREIGN KEY (destination_device_id) REFERENCES media_devices(id)
  );

  CREATE TABLE IF NOT EXISTS history_recovery_transfer_chunks (
    transfer_id TEXT NOT NULL,
    chunk_index INTEGER NOT NULL CHECK (chunk_index >= 0),
    ciphertext BLOB NOT NULL,
    ciphertext_sha256 TEXT NOT NULL,
    size_bytes INTEGER NOT NULL CHECK (
      size_bytes BETWEEN 1 AND 262144
    ),
    created_at TEXT NOT NULL,
    PRIMARY KEY (transfer_id, chunk_index),
    FOREIGN KEY (transfer_id) REFERENCES history_recovery_transfers(id)
      ON DELETE CASCADE
  );

  CREATE TABLE IF NOT EXISTS channels (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    type TEXT NOT NULL,
    position INTEGER NOT NULL,
    glyph TEXT,
    created_at TEXT,
    encryption_mode TEXT NOT NULL DEFAULT 'legacy',
    encryption_version INTEGER NOT NULL DEFAULT 0
  );

  CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL,
    content TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT,
    FOREIGN KEY (channel_id) REFERENCES channels(id),
                                       FOREIGN KEY (user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS server_settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
                                              attachment_retention_days INTEGER NOT NULL DEFAULT 0,
                                              attachment_max_bytes INTEGER NOT NULL DEFAULT 26214400,
                                              attachment_allowed_types_json TEXT NOT NULL DEFAULT '["image/","video/","audio/","text/","application/pdf","application/zip","application/json"]',
                                              file_storage_enabled INTEGER NOT NULL DEFAULT 1,
                                              file_storage_max_total_bytes INTEGER NOT NULL DEFAULT 2147483648,
                                              file_storage_max_file_bytes INTEGER NOT NULL DEFAULT 262144000,
                                              file_storage_allowed_types_json TEXT NOT NULL DEFAULT '["*"]',
                                              inline_media_previews_enabled INTEGER NOT NULL DEFAULT 1,
                                              created_at TEXT NOT NULL,
                                              updated_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS attachments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id TEXT NOT NULL,
    channel_id INTEGER NOT NULL,
    message_id INTEGER,
    uploader_user_id INTEGER NOT NULL,
    kind TEXT NOT NULL,
    original_name TEXT NOT NULL,
    stored_name TEXT NOT NULL,
    relative_path TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    expires_at TEXT,
    deleted_at TEXT,
    FOREIGN KEY (channel_id) REFERENCES channels(id),
                                          FOREIGN KEY (message_id) REFERENCES messages(id),
                                          FOREIGN KEY (uploader_user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS bans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER,
    yuid TEXT,
    username_snapshot TEXT,
    reason TEXT,
    created_by_user_id INTEGER,
    created_at TEXT NOT NULL,
    revoked_at TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (created_by_user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS mls_key_packages (
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    ciphersuite INTEGER NOT NULL CHECK (ciphersuite > 0),
    signature_public_key TEXT NOT NULL,
    identity_binding_signature TEXT NOT NULL,
    key_package BLOB NOT NULL,
    key_package_hash TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    claimed_at TEXT,
    claimed_by_device_id TEXT,
    FOREIGN KEY (device_id) REFERENCES media_devices(id),
    FOREIGN KEY (claimed_by_device_id) REFERENCES media_devices(id)
  );

  CREATE TABLE IF NOT EXISTS mls_device_credentials (
    device_id TEXT NOT NULL,
    signature_public_key TEXT NOT NULL,
    identity_binding_signature TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (device_id, signature_public_key),
    FOREIGN KEY (device_id) REFERENCES media_devices(id)
  );

  CREATE TABLE IF NOT EXISTS mls_delivery_messages (
    id TEXT PRIMARY KEY,
    client_operation_id TEXT NOT NULL,
    channel_id INTEGER NOT NULL,
    server_sequence INTEGER NOT NULL,
    message_class TEXT NOT NULL CHECK (
      message_class IN ('proposal', 'commit', 'welcome', 'application')
    ),
    accepted_epoch INTEGER NOT NULL CHECK (accepted_epoch >= 0),
    parent_epoch INTEGER CHECK (parent_epoch IS NULL OR parent_epoch >= 0),
    uploader_user_id INTEGER NOT NULL,
    uploader_device_id TEXT NOT NULL,
    recipient_device_id TEXT,
    wire_message BLOB NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (channel_id) REFERENCES channels(id),
    FOREIGN KEY (uploader_user_id) REFERENCES users(id),
    FOREIGN KEY (uploader_device_id) REFERENCES media_devices(id),
    FOREIGN KEY (recipient_device_id) REFERENCES media_devices(id),
    UNIQUE (channel_id, server_sequence),
    UNIQUE (uploader_device_id, client_operation_id)
  );

  CREATE TABLE IF NOT EXISTS mls_channel_state (
    channel_id INTEGER PRIMARY KEY,
    group_id TEXT NOT NULL UNIQUE,
    current_epoch INTEGER NOT NULL DEFAULT 0 CHECK (current_epoch >= 0),
    next_sequence INTEGER NOT NULL DEFAULT 1 CHECK (next_sequence >= 1),
    initialized_by_device_id TEXT NOT NULL,
    initialized_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (channel_id) REFERENCES channels(id),
    FOREIGN KEY (initialized_by_device_id) REFERENCES media_devices(id)
  );

  CREATE TABLE IF NOT EXISTS mls_device_cursors (
    channel_id INTEGER NOT NULL,
    device_id TEXT NOT NULL,
    delivered_sequence INTEGER NOT NULL DEFAULT 0
      CHECK (delivered_sequence >= 0),
    acknowledged_sequence INTEGER NOT NULL DEFAULT 0
      CHECK (acknowledged_sequence >= 0
        AND acknowledged_sequence <= delivered_sequence),
    acknowledged_epoch INTEGER NOT NULL DEFAULT 0
      CHECK (acknowledged_epoch >= 0),
    updated_at TEXT NOT NULL,
    PRIMARY KEY (channel_id, device_id),
    FOREIGN KEY (channel_id) REFERENCES channels(id),
    FOREIGN KEY (device_id) REFERENCES media_devices(id)
  );

  CREATE TABLE IF NOT EXISTS encrypted_message_events (
    event_id TEXT PRIMARY KEY,
    channel_id INTEGER NOT NULL,
    delivery_message_id TEXT NOT NULL UNIQUE,
    server_sequence INTEGER NOT NULL,
    sender_user_id INTEGER NOT NULL,
    sender_device_id TEXT NOT NULL,
    event_kind TEXT NOT NULL CHECK (
      event_kind IN ('message', 'edit', 'delete', 'reaction', 'attachment')
    ),
    target_event_id TEXT,
    accepted_epoch INTEGER NOT NULL CHECK (accepted_epoch >= 0),
    created_at TEXT NOT NULL,
    FOREIGN KEY (channel_id) REFERENCES channels(id),
    FOREIGN KEY (delivery_message_id) REFERENCES mls_delivery_messages(id),
    FOREIGN KEY (sender_user_id) REFERENCES users(id),
    FOREIGN KEY (sender_device_id) REFERENCES media_devices(id),
    FOREIGN KEY (target_event_id) REFERENCES encrypted_message_events(event_id),
    UNIQUE (channel_id, server_sequence)
  );

  CREATE TABLE IF NOT EXISTS encrypted_attachments (
    id TEXT PRIMARY KEY,
    channel_id INTEGER NOT NULL,
    event_id TEXT,
    uploader_user_id INTEGER NOT NULL,
    uploader_device_id TEXT NOT NULL,
    relative_path TEXT NOT NULL UNIQUE,
    secretstream_header BLOB NOT NULL,
    ciphertext_size_bytes INTEGER NOT NULL CHECK (ciphertext_size_bytes > 0),
    ciphertext_sha256 TEXT NOT NULL,
    chunk_count INTEGER NOT NULL CHECK (chunk_count > 0),
    created_at TEXT NOT NULL,
    expires_at TEXT,
    deleted_at TEXT,
    FOREIGN KEY (channel_id) REFERENCES channels(id),
    FOREIGN KEY (event_id) REFERENCES encrypted_message_events(event_id),
    FOREIGN KEY (uploader_user_id) REFERENCES users(id),
    FOREIGN KEY (uploader_device_id) REFERENCES media_devices(id)
  );
  `);
}

function runMigrations(db) {
  if (!hasColumn(db, 'users', 'username_normalized')) {
    db.exec('ALTER TABLE users ADD COLUMN username_normalized TEXT');
  }
  if (!hasColumn(db, 'users', 'role')) {
    db.exec("ALTER TABLE users ADD COLUMN role TEXT NOT NULL DEFAULT 'member'");
  }
  if (!hasColumn(db, 'users', 'display_name')) {
    db.exec('ALTER TABLE users ADD COLUMN display_name TEXT');
  }
  if (!hasColumn(db, 'users', 'avatar_url')) {
    db.exec('ALTER TABLE users ADD COLUMN avatar_url TEXT');
  }
  if (!hasColumn(db, 'users', 'last_login_at')) {
    db.exec('ALTER TABLE users ADD COLUMN last_login_at TEXT');
  }
  if (!hasColumn(db, 'users', 'yuid')) {
    db.exec('ALTER TABLE users ADD COLUMN yuid TEXT');
  }
  if (!hasColumn(db, 'users', 'yuid_public_key')) {
    db.exec('ALTER TABLE users ADD COLUMN yuid_public_key TEXT');
  }
  if (!hasColumn(db, 'users', 'yuid_bound_at')) {
    db.exec('ALTER TABLE users ADD COLUMN yuid_bound_at TEXT');
  }
  if (!hasColumn(db, 'users', 'yuid_last_seen_at')) {
    db.exec('ALTER TABLE users ADD COLUMN yuid_last_seen_at TEXT');
  }

  if (!hasColumn(db, 'channels', 'glyph')) {
    db.exec('ALTER TABLE channels ADD COLUMN glyph TEXT');
  }
  if (!hasColumn(db, 'channels', 'created_at')) {
    db.exec('ALTER TABLE channels ADD COLUMN created_at TEXT');
  }
  if (!hasColumn(db, 'channels', 'encryption_mode')) {
    db.exec(
      "ALTER TABLE channels ADD COLUMN encryption_mode TEXT NOT NULL DEFAULT 'legacy'",
    );
  }
  if (!hasColumn(db, 'channels', 'encryption_version')) {
    db.exec(
      'ALTER TABLE channels ADD COLUMN encryption_version INTEGER NOT NULL DEFAULT 0',
    );
  }
  if (!hasColumn(db, 'messages', 'updated_at')) {
    db.exec('ALTER TABLE messages ADD COLUMN updated_at TEXT');
  }
  if (!hasColumn(db, 'sessions', 'expires_at')) {
    db.exec('ALTER TABLE sessions ADD COLUMN expires_at TEXT');
  }
  if (!hasColumn(db, 'sessions', 'idle_expires_at')) {
    db.exec('ALTER TABLE sessions ADD COLUMN idle_expires_at TEXT');
  }
  if (!hasColumn(db, 'sessions', 'device_name')) {
    db.exec('ALTER TABLE sessions ADD COLUMN device_name TEXT');
  }
  if (!hasColumn(db, 'sessions', 'media_device_id')) {
    db.exec('ALTER TABLE sessions ADD COLUMN media_device_id TEXT');
  }
  if (!hasColumn(db, 'mls_key_packages', 'signature_public_key')) {
    db.exec(
      'ALTER TABLE mls_key_packages ADD COLUMN signature_public_key TEXT',
    );
  }
  if (!hasColumn(db, 'mls_key_packages', 'identity_binding_signature')) {
    db.exec(
      'ALTER TABLE mls_key_packages ADD COLUMN identity_binding_signature TEXT',
    );
  }
  if (!hasColumn(db, 'mls_delivery_messages', 'recipient_device_id')) {
    db.exec(
      'ALTER TABLE mls_delivery_messages ADD COLUMN recipient_device_id TEXT',
    );
  }
  if (!hasColumn(db, 'mls_delivery_messages', 'client_operation_id')) {
    db.exec(
      'ALTER TABLE mls_delivery_messages ADD COLUMN client_operation_id TEXT',
    );
  }
  db.exec(`
  CREATE TABLE IF NOT EXISTS history_recovery_device_keys (
    device_id TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL,
    public_key TEXT NOT NULL UNIQUE,
    yuid_authorization_signature TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (device_id) REFERENCES media_devices(id),
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS history_recovery_transfers (
    id TEXT PRIMARY KEY,
    channel_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL,
    source_device_id TEXT NOT NULL,
    destination_device_id TEXT NOT NULL,
    first_server_sequence INTEGER NOT NULL CHECK (first_server_sequence >= 1),
    last_server_sequence INTEGER NOT NULL CHECK (
      last_server_sequence >= first_server_sequence
    ),
    event_count INTEGER NOT NULL CHECK (event_count >= 1),
    chunk_count INTEGER NOT NULL CHECK (chunk_count BETWEEN 1 AND 1024),
    total_bytes INTEGER NOT NULL CHECK (
      total_bytes BETWEEN 1 AND 268435456
    ),
    manifest BLOB NOT NULL,
    manifest_sha256 TEXT NOT NULL,
    yuid_signature TEXT NOT NULL,
    state TEXT NOT NULL CHECK (
      state IN ('uploading', 'ready', 'consumed', 'canceled', 'expired')
    ),
    uploaded_chunks INTEGER NOT NULL DEFAULT 0,
    uploaded_bytes INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    ready_at TEXT,
    consumed_at TEXT,
    canceled_at TEXT,
    expires_at TEXT NOT NULL,
    FOREIGN KEY (channel_id) REFERENCES channels(id),
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (source_device_id) REFERENCES media_devices(id),
    FOREIGN KEY (destination_device_id) REFERENCES media_devices(id)
  );

  CREATE TABLE IF NOT EXISTS history_recovery_transfer_chunks (
    transfer_id TEXT NOT NULL,
    chunk_index INTEGER NOT NULL CHECK (chunk_index >= 0),
    ciphertext BLOB NOT NULL,
    ciphertext_sha256 TEXT NOT NULL,
    size_bytes INTEGER NOT NULL CHECK (
      size_bytes BETWEEN 1 AND 262144
    ),
    created_at TEXT NOT NULL,
    PRIMARY KEY (transfer_id, chunk_index),
    FOREIGN KEY (transfer_id) REFERENCES history_recovery_transfers(id)
      ON DELETE CASCADE
  );

  CREATE TABLE IF NOT EXISTS mls_device_credentials (
    device_id TEXT NOT NULL,
    signature_public_key TEXT NOT NULL,
    identity_binding_signature TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (device_id, signature_public_key),
    FOREIGN KEY (device_id) REFERENCES media_devices(id)
  );

  INSERT OR IGNORE INTO mls_device_credentials (
    device_id, signature_public_key, identity_binding_signature, created_at
  )
  SELECT device_id, signature_public_key, identity_binding_signature,
         MIN(created_at)
  FROM mls_key_packages
  WHERE signature_public_key IS NOT NULL
    AND signature_public_key != ''
    AND identity_binding_signature IS NOT NULL
    AND identity_binding_signature != ''
  GROUP BY device_id, signature_public_key, identity_binding_signature;

  CREATE UNIQUE INDEX IF NOT EXISTS idx_mls_delivery_device_operation
  ON mls_delivery_messages (uploader_device_id, client_operation_id)
  WHERE client_operation_id IS NOT NULL;

  UPDATE sessions
  SET expires_at = datetime(created_at, '+30 days')
  WHERE expires_at IS NULL OR expires_at = '';

  UPDATE sessions
  SET idle_expires_at = datetime(last_seen_at, '+7 days')
  WHERE idle_expires_at IS NULL OR idle_expires_at = '';

  UPDATE sessions
  SET device_name = 'Existing Yappa client'
  WHERE device_name IS NULL OR device_name = '';

  UPDATE server_settings
  SET attachment_retention_days = 0,
      updated_at = datetime('now')
  WHERE attachment_retention_days != 0;

  UPDATE attachments
  SET expires_at = NULL
  WHERE deleted_at IS NULL;

  UPDATE encrypted_attachments
  SET expires_at = NULL
  WHERE deleted_at IS NULL;
  `);

  db.prepare(`
  UPDATE users
  SET username_normalized = lower(username)
  WHERE username_normalized IS NULL OR username_normalized = ''
  `).run();

  db.prepare(`
  UPDATE channels
  SET created_at = ?
  WHERE created_at IS NULL OR created_at = ''
  `).run(nowIso());

  db.exec(`
  CREATE UNIQUE INDEX IF NOT EXISTS idx_users_username_normalized
  ON users (username_normalized);

  CREATE UNIQUE INDEX IF NOT EXISTS idx_users_yuid
  ON users (yuid)
  WHERE yuid IS NOT NULL AND yuid != '';

  CREATE UNIQUE INDEX IF NOT EXISTS idx_users_yuid_public_key
  ON users (yuid_public_key)
  WHERE yuid_public_key IS NOT NULL AND yuid_public_key != '';

  CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON sessions (user_id);
  CREATE INDEX IF NOT EXISTS idx_sessions_media_device_id
  ON sessions (media_device_id);
  CREATE INDEX IF NOT EXISTS idx_media_devices_user_id
  ON media_devices (user_id);
  CREATE INDEX IF NOT EXISTS idx_media_devices_active
  ON media_devices (revoked_at);
  CREATE INDEX IF NOT EXISTS idx_history_recovery_keys_user
  ON history_recovery_device_keys (user_id, device_id);
  CREATE INDEX IF NOT EXISTS idx_history_recovery_transfer_destination
  ON history_recovery_transfers (
    destination_device_id, state, channel_id, created_at
  );
  CREATE INDEX IF NOT EXISTS idx_history_recovery_transfer_source
  ON history_recovery_transfers (source_device_id, state, created_at);
  CREATE INDEX IF NOT EXISTS idx_history_recovery_transfer_expiry
  ON history_recovery_transfers (state, expires_at);
  DROP INDEX IF EXISTS idx_messages_channel_id;
  CREATE INDEX IF NOT EXISTS idx_messages_channel_id_id
  ON messages (channel_id, id);
  CREATE INDEX IF NOT EXISTS idx_channels_position ON channels (position);
  CREATE INDEX IF NOT EXISTS idx_attachments_channel_id ON attachments (channel_id);
  CREATE INDEX IF NOT EXISTS idx_attachments_message_id ON attachments (message_id);
  CREATE INDEX IF NOT EXISTS idx_attachments_expires_at ON attachments (expires_at);
  CREATE INDEX IF NOT EXISTS idx_bans_user_id ON bans (user_id);
  CREATE INDEX IF NOT EXISTS idx_bans_yuid ON bans (yuid);
  CREATE INDEX IF NOT EXISTS idx_bans_revoked_at ON bans (revoked_at);
  CREATE INDEX IF NOT EXISTS idx_mls_key_packages_device
  ON mls_key_packages (device_id, claimed_at, expires_at);
  CREATE INDEX IF NOT EXISTS idx_mls_device_credentials_device
  ON mls_device_credentials (device_id);
  CREATE INDEX IF NOT EXISTS idx_mls_delivery_channel_sequence
  ON mls_delivery_messages (channel_id, server_sequence);
  CREATE INDEX IF NOT EXISTS idx_mls_delivery_epoch
  ON mls_delivery_messages (channel_id, accepted_epoch);
  CREATE INDEX IF NOT EXISTS idx_mls_delivery_recipient
  ON mls_delivery_messages (channel_id, recipient_device_id, server_sequence);
  CREATE INDEX IF NOT EXISTS idx_encrypted_events_channel_sequence
  ON encrypted_message_events (channel_id, server_sequence);
  CREATE INDEX IF NOT EXISTS idx_encrypted_attachments_channel
  ON encrypted_attachments (channel_id);
  CREATE INDEX IF NOT EXISTS idx_encrypted_attachments_expires
  ON encrypted_attachments (expires_at);

  CREATE TRIGGER IF NOT EXISTS channels_encryption_mode_insert_guard
  BEFORE INSERT ON channels
  WHEN NEW.encryption_mode NOT IN ('legacy', 'e2ee')
    OR (NEW.encryption_mode = 'legacy' AND NEW.encryption_version != 0)
    OR (NEW.encryption_mode = 'e2ee' AND NEW.encryption_version < 1)
  BEGIN
    SELECT RAISE(ABORT, 'invalid channel encryption mode');
  END;

  CREATE TRIGGER IF NOT EXISTS channels_encryption_mode_update_guard
  BEFORE UPDATE OF encryption_mode, encryption_version ON channels
  WHEN NEW.encryption_mode NOT IN ('legacy', 'e2ee')
    OR (NEW.encryption_mode = 'legacy' AND NEW.encryption_version != 0)
    OR (NEW.encryption_mode = 'e2ee' AND NEW.encryption_version < 1)
    OR (OLD.encryption_mode = 'e2ee' AND NEW.encryption_mode != 'e2ee')
    OR (OLD.encryption_mode = 'e2ee'
        AND NEW.encryption_version < OLD.encryption_version)
  BEGIN
    SELECT RAISE(ABORT, 'channel encryption downgrade forbidden');
  END;
  `);
}

function ensureServerConfig(db, defaults) {
  const existing = db.prepare('SELECT * FROM server_config WHERE id = 1').get();
  if (existing) {
    return existing;
  }

  const createdAt = nowIso();
  const serverId = `srv_${crypto.randomBytes(16).toString('hex')}`;
  db.prepare(`
  INSERT INTO server_config (
    id,
    server_id,
    name,
    description,
    branding_json,
    owner_user_id,
    created_at,
    updated_at
  )
  VALUES (1, ?, ?, ?, ?, NULL, ?, ?)
  `).run(
    serverId,
    defaults.serverName,
    defaults.serverDescription,
    JSON.stringify({
      accentColor: '#8b0c14',
      iconUrl: null,
      bannerUrl: null,
    }),
    createdAt,
    createdAt,
  );

  return db.prepare('SELECT * FROM server_config WHERE id = 1').get();
}

function ensureServerSettings(db) {
  const existing = db.prepare('SELECT * FROM server_settings WHERE id = 1').get();
  if (existing) {
    return existing;
  }

  const createdAt = nowIso();
  db.prepare(`
  INSERT INTO server_settings (
    id,
    attachment_retention_days,
    attachment_max_bytes,
    attachment_allowed_types_json,
    file_storage_enabled,
    file_storage_max_total_bytes,
    file_storage_max_file_bytes,
    file_storage_allowed_types_json,
    inline_media_previews_enabled,
    created_at,
    updated_at
  )
  VALUES (1, 0, 26214400, ?, 1, 2147483648, 262144000, ?, 1, ?, ?)
  `).run(
    JSON.stringify(['image/', 'video/', 'audio/', 'text/', 'application/pdf', 'application/zip', 'application/json']),
         JSON.stringify(['*']),
         createdAt,
         createdAt,
  );

  return db.prepare('SELECT * FROM server_settings WHERE id = 1').get();
}

function seedDefaultChannels(db) {
  const existingCount = db.prepare('SELECT COUNT(*) AS count FROM channels').get().count;
  if (existingCount > 0) {
    return;
  }

  const insert = db.prepare('INSERT INTO channels (name, type, position, created_at) VALUES (?, ?, ?, ?)');
  const createdAt = nowIso();
  const defaults = [
    ['general', 'text', 1, createdAt],
    ['screenshots', 'text', 2, createdAt],
    ['ideas', 'text', 3, createdAt],
    ['Lobby', 'voice', 4, createdAt],
    ['Gaming', 'voice', 5, createdAt],
  ];

  const tx = db.transaction((rows) => {
    for (const row of rows) {
      insert.run(...row);
    }
  });

  tx(defaults);
}

function ensureOwnerAssigned(db) {
  const config = db.prepare('SELECT owner_user_id FROM server_config WHERE id = 1').get();
  if (config?.owner_user_id) {
    return;
  }

  const firstUser = db.prepare('SELECT id FROM users ORDER BY id ASC LIMIT 1').get();
  if (!firstUser) {
    return;
  }

  const updatedAt = nowIso();
  db.prepare("UPDATE users SET role = 'owner' WHERE id = ?").run(firstUser.id);
  db.prepare(`
  UPDATE server_config
  SET owner_user_id = ?, updated_at = ?
  WHERE id = 1
  `).run(firstUser.id, updatedAt);
}

function createDb(dbPath, defaults) {
  ensureDirForFile(dbPath);
  const db = new Database(dbPath);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  const existingVersion = readSchemaVersion(db);
  if (existingVersion > CURRENT_SCHEMA_VERSION) {
    db.close();
    throw unsupportedSchemaVersion(existingVersion);
  }

  try {
    db.transaction(() => {
      createBaseTables(db);
      const transactionVersion = readSchemaVersion(db);
      if (transactionVersion > CURRENT_SCHEMA_VERSION) {
        throw unsupportedSchemaVersion(transactionVersion);
      }
      if (transactionVersion < CURRENT_SCHEMA_VERSION) {
        runMigrations(db);
        db.prepare(`
          INSERT INTO schema_migrations (version, applied_at)
          VALUES (?, ?)
        `).run(CURRENT_SCHEMA_VERSION, nowIso());
      }
      ensureServerConfig(db, defaults);
      ensureServerSettings(db);
      seedDefaultChannels(db);
      ensureOwnerAssigned(db);
    })();
    return db;
  } catch (error) {
    db.close();
    throw error;
  }
}

function getServerConfig(db) {
  return db.prepare('SELECT * FROM server_config WHERE id = 1').get();
}

function getServerSettings(db) {
  return db.prepare('SELECT * FROM server_settings WHERE id = 1').get();
}

function updateServerSettings(db, patch) {
  const current = getServerSettings(db);
  const next = {
    attachment_retention_days: current.attachment_retention_days,
    attachment_max_bytes: current.attachment_max_bytes,
    attachment_allowed_types_json: current.attachment_allowed_types_json,
    file_storage_enabled: current.file_storage_enabled,
    file_storage_max_total_bytes: current.file_storage_max_total_bytes,
    file_storage_max_file_bytes: current.file_storage_max_file_bytes,
    file_storage_allowed_types_json: current.file_storage_allowed_types_json,
    inline_media_previews_enabled: current.inline_media_previews_enabled,
    ...patch,
    updated_at: nowIso(),
  };

  db.prepare(`
  UPDATE server_settings
  SET
  attachment_retention_days = ?,
  attachment_max_bytes = ?,
  attachment_allowed_types_json = ?,
  file_storage_enabled = ?,
  file_storage_max_total_bytes = ?,
  file_storage_max_file_bytes = ?,
  file_storage_allowed_types_json = ?,
  inline_media_previews_enabled = ?,
  updated_at = ?
  WHERE id = 1
  `).run(
    next.attachment_retention_days,
    next.attachment_max_bytes,
    next.attachment_allowed_types_json,
    next.file_storage_enabled,
    next.file_storage_max_total_bytes,
    next.file_storage_max_file_bytes,
    next.file_storage_allowed_types_json,
    next.inline_media_previews_enabled,
    next.updated_at,
  );

  return getServerSettings(db);
}

function getAllChannels(db) {
  return db.prepare(`
  SELECT id, name, type, position, glyph, created_at,
         encryption_mode, encryption_version
  FROM channels
  ORDER BY position ASC, id ASC
  `).all();
}

function createUserWithRole(db, { username, usernameNormalized, passwordHash, role, displayName = null, avatarUrl = null, yuid = null, yuidPublicKey = null, yuidBoundAt = null, yuidLastSeenAt = null }) {
  const createdAt = nowIso();
  const tx = db.transaction(() => {
    const userResult = db.prepare(`
    INSERT INTO users (
      username,
      username_normalized,
      password_hash,
      role,
      display_name,
      avatar_url,
      created_at,
      last_login_at,
      yuid,
      yuid_public_key,
      yuid_bound_at,
      yuid_last_seen_at
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      username,
      usernameNormalized,
      passwordHash,
      role,
      displayName,
      avatarUrl,
      createdAt,
      createdAt,
      yuid,
      yuidPublicKey,
      yuidBoundAt,
      yuidLastSeenAt,
    );

    const userId = Number(userResult.lastInsertRowid);

    if (role === 'owner') {
      db.prepare(`
      UPDATE server_config
      SET owner_user_id = ?, updated_at = ?
      WHERE id = 1
      `).run(userId, createdAt);
    }

    return db.prepare(`
    SELECT id, username, username_normalized, role, display_name, avatar_url, created_at, last_login_at, yuid, yuid_public_key, yuid_bound_at, yuid_last_seen_at
    FROM users
    WHERE id = ?
    `).get(userId);
  });

  return tx();
}


function getUserByYuid(db, yuid) {
  return db.prepare(`
  SELECT id, username, username_normalized, role, display_name, avatar_url, created_at, last_login_at, yuid, yuid_public_key, yuid_bound_at, yuid_last_seen_at
  FROM users
  WHERE yuid = ?
  `).get(yuid);
}

function bindUserYuid(db, userId, { yuid, yuidPublicKey, boundAt, lastSeenAt }) {
  db.prepare(`
  UPDATE users
  SET yuid = ?, yuid_public_key = ?, yuid_bound_at = ?, yuid_last_seen_at = ?
  WHERE id = ?
  `).run(yuid, yuidPublicKey, boundAt, lastSeenAt, userId);

  return db.prepare(`
  SELECT id, username, username_normalized, role, display_name, avatar_url, created_at, last_login_at, yuid, yuid_public_key, yuid_bound_at, yuid_last_seen_at
  FROM users
  WHERE id = ?
  `).get(userId);
}

function updateUserProfile(db, userId, { displayName, avatarUrl }) {
  const current = db.prepare(`
  SELECT id, username, username_normalized, role, display_name, avatar_url, created_at, last_login_at, yuid, yuid_public_key, yuid_bound_at, yuid_last_seen_at
  FROM users
  WHERE id = ?
  `).get(userId);

  if (!current) {
    return null;
  }

  const nextDisplayName = displayName === undefined ? current.display_name : displayName;
  const nextAvatarUrl = avatarUrl === undefined ? current.avatar_url : avatarUrl;

  db.prepare(`
  UPDATE users
  SET display_name = ?, avatar_url = ?
  WHERE id = ?
  `).run(nextDisplayName, nextAvatarUrl, userId);

  return db.prepare(`
  SELECT id, username, username_normalized, role, display_name, avatar_url, created_at, last_login_at, yuid, yuid_public_key, yuid_bound_at, yuid_last_seen_at
  FROM users
  WHERE id = ?
  `).get(userId);
}

function touchUserYuid(db, userId, at = nowIso()) {
  db.prepare('UPDATE users SET yuid_last_seen_at = ? WHERE id = ?').run(at, userId);
}

function touchUserLogin(db, userId) {
  db.prepare('UPDATE users SET last_login_at = ? WHERE id = ?').run(nowIso(), userId);
}

function touchSession(db, token, idleExpiresAt = null) {
  db.prepare(`
  UPDATE sessions
  SET last_seen_at = ?, idle_expires_at = COALESCE(?, idle_expires_at)
  WHERE token = ?
  `).run(
    nowIso(),
    idleExpiresAt,
    sessionTokenStorageValue(token),
  );
}

function revokeSession(db, token) {
  return db
    .prepare('DELETE FROM sessions WHERE token = ?')
    .run(sessionTokenStorageValue(token));
}

function getActiveBanByUserId(db, userId) {
  if (!Number.isInteger(Number(userId))) {
    return null;
  }

  return db.prepare(`
  SELECT *
  FROM bans
  WHERE user_id = ?
  AND revoked_at IS NULL
  ORDER BY id DESC
  LIMIT 1
  `).get(Number(userId));
}

function getActiveBanByYuid(db, yuid) {
  const normalized = String(yuid || '').trim();
  if (!normalized) {
    return null;
  }

  return db.prepare(`
  SELECT *
  FROM bans
  WHERE yuid = ?
  AND revoked_at IS NULL
  ORDER BY id DESC
  LIMIT 1
  `).get(normalized);
}

function getAllActiveBans(db) {
  return db.prepare(`
  SELECT bans.*, users.username AS target_username, users.display_name AS target_display_name
  FROM bans
  LEFT JOIN users ON users.id = bans.user_id
  WHERE bans.revoked_at IS NULL
  ORDER BY bans.created_at DESC, bans.id DESC
  `).all();
}

function createBan(db, { userId = null, yuid = null, usernameSnapshot = null, reason = null, createdByUserId = null }) {
  const createdAt = nowIso();
  const normalizedYuid = String(yuid || '').trim() || null;
  const normalizedUsername = String(usernameSnapshot || '').trim() || null;
  const normalizedReason = String(reason || '').trim() || null;
  const normalizedUserId =
    userId != null && Number.isInteger(Number(userId)) ? Number(userId) : null;
  const normalizedCreatedBy =
    createdByUserId != null && Number.isInteger(Number(createdByUserId))
      ? Number(createdByUserId)
      : null;

  const existing =
    (normalizedUserId != null ? getActiveBanByUserId(db, normalizedUserId) : null) ||
    (normalizedYuid ? getActiveBanByYuid(db, normalizedYuid) : null);
  if (existing) {
    return existing;
  }

  const result = db.prepare(`
  INSERT INTO bans (
    user_id,
    yuid,
    username_snapshot,
    reason,
    created_by_user_id,
    created_at,
    revoked_at
  )
  VALUES (?, ?, ?, ?, ?, ?, NULL)
  `).run(
    normalizedUserId,
    normalizedYuid,
    normalizedUsername,
    normalizedReason,
    normalizedCreatedBy,
    createdAt,
  );

  return db.prepare('SELECT * FROM bans WHERE id = ?').get(result.lastInsertRowid);
}

function revokeBan(db, banId) {
  const normalizedBanId = Number(banId);
  if (!Number.isInteger(normalizedBanId)) {
    return null;
  }

  const existing = db.prepare('SELECT * FROM bans WHERE id = ?').get(normalizedBanId);
  if (!existing || existing.revoked_at) {
    return existing || null;
  }

  db.prepare('UPDATE bans SET revoked_at = ? WHERE id = ?').run(nowIso(), normalizedBanId);
  return db.prepare('SELECT * FROM bans WHERE id = ?').get(normalizedBanId);
}

function createAttachment(db, input) {
  const result = db.prepare(`
  INSERT INTO attachments (
    server_id,
    channel_id,
    message_id,
    uploader_user_id,
    kind,
    original_name,
    stored_name,
    relative_path,
    mime_type,
    size_bytes,
    created_at,
    expires_at,
    deleted_at
  )
  VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
  `).run(
    input.serverId,
    input.channelId,
    input.uploaderUserId,
    input.kind,
    input.originalName,
    input.storedName,
    input.relativePath,
    input.mimeType,
    input.sizeBytes,
    input.createdAt,
    input.expiresAt,
  );

  return db.prepare('SELECT * FROM attachments WHERE id = ?').get(result.lastInsertRowid);
}

function linkAttachmentsToMessage(db, { attachmentIds, messageId, channelId, userId }) {
  if (!Array.isArray(attachmentIds) || attachmentIds.length === 0) {
    return [];
  }

  const placeholders = attachmentIds.map(() => '?').join(',');
  db.prepare(`
  UPDATE attachments
  SET message_id = ?
  WHERE id IN (${placeholders})
  AND message_id IS NULL
  AND channel_id = ?
  AND uploader_user_id = ?
  AND deleted_at IS NULL
  `).run(messageId, ...attachmentIds, channelId, userId);

  return getAttachmentsForMessageIds(db, [messageId]).get(Number(messageId)) || [];
}

function getAttachmentsForMessageIds(db, messageIds) {
  const map = new Map();
  if (!Array.isArray(messageIds) || messageIds.length === 0) {
    return map;
  }

  const placeholders = messageIds.map(() => '?').join(',');
  const rows = db.prepare(`
  SELECT *
  FROM attachments
  WHERE message_id IN (${placeholders})
  AND deleted_at IS NULL
  ORDER BY id ASC
  `).all(...messageIds);

  for (const row of rows) {
    const key = Number(row.message_id);
    if (!map.has(key)) {
      map.set(key, []);
    }
    map.get(key).push(row);
  }

  return map;
}

function getPendingAttachmentById(db, attachmentId) {
  return db.prepare(`
  SELECT *
  FROM attachments
  WHERE id = ?
  AND message_id IS NULL
  AND deleted_at IS NULL
  `).get(attachmentId);
}

function getAttachmentTotalBytes(db) {
  return db.prepare(`
  SELECT COALESCE(SUM(size_bytes), 0) AS total
  FROM attachments
  WHERE deleted_at IS NULL
  `).get().total;
}

function getExpiredAttachments(db, now) {
  return db.prepare(`
  SELECT *
  FROM attachments
  WHERE deleted_at IS NULL
  AND expires_at IS NOT NULL
  AND expires_at <= ?
  ORDER BY id ASC
  LIMIT 200
  `).all(now);
}

function markAttachmentDeleted(db, attachmentId, deletedAt) {
  db.prepare('UPDATE attachments SET deleted_at = ? WHERE id = ?').run(deletedAt, attachmentId);
}

module.exports = {
  CURRENT_SCHEMA_VERSION,
  bindUserYuid,
  createAttachment,
  createDb,
  createUserWithRole,
  ensureDir,
  getAllChannels,
  getUserByYuid,
  getAttachmentTotalBytes,
  getAttachmentsForMessageIds,
  getExpiredAttachments,
  getPendingAttachmentById,
  getServerConfig,
  getServerSettings,
  linkAttachmentsToMessage,
  markAttachmentDeleted,
  nowIso,
  randomId,
  revokeSession,
  sessionTokenStorageValue,
  touchSession,
  touchUserLogin,
  touchUserYuid,
  updateServerSettings,
  updateUserProfile,
  getActiveBanByUserId,
  getActiveBanByYuid,
  getAllActiveBans,
  createBan,
  revokeBan,
};
