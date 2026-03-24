const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const Database = require('better-sqlite3');

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

function hasColumn(db, tableName, columnName) {
  const columns = db.prepare(`PRAGMA table_info(${tableName})`).all();
  return columns.some((column) => column.name === columnName);
}

function createBaseTables(db) {
  db.exec(`
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
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS channels (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    type TEXT NOT NULL,
    position INTEGER NOT NULL,
    created_at TEXT
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
                                              attachment_retention_days INTEGER NOT NULL DEFAULT 30,
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

  if (!hasColumn(db, 'channels', 'created_at')) {
    db.exec('ALTER TABLE channels ADD COLUMN created_at TEXT');
  }
  if (!hasColumn(db, 'messages', 'updated_at')) {
    db.exec('ALTER TABLE messages ADD COLUMN updated_at TEXT');
  }

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
  CREATE INDEX IF NOT EXISTS idx_messages_channel_id ON messages (channel_id);
  CREATE INDEX IF NOT EXISTS idx_channels_position ON channels (position);
  CREATE INDEX IF NOT EXISTS idx_attachments_channel_id ON attachments (channel_id);
  CREATE INDEX IF NOT EXISTS idx_attachments_message_id ON attachments (message_id);
  CREATE INDEX IF NOT EXISTS idx_attachments_expires_at ON attachments (expires_at);
  CREATE INDEX IF NOT EXISTS idx_bans_user_id ON bans (user_id);
  CREATE INDEX IF NOT EXISTS idx_bans_yuid ON bans (yuid);
  CREATE INDEX IF NOT EXISTS idx_bans_revoked_at ON bans (revoked_at);
  `);
}

function ensureServerConfig(db, defaults) {
  const existing = db.prepare('SELECT * FROM server_config WHERE id = 1').get();
  if (existing) {
    return existing;
  }

  const createdAt = nowIso();
  const serverId = randomId('node');
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
  VALUES (1, 30, 26214400, ?, 1, 2147483648, 262144000, ?, 1, ?, ?)
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

  createBaseTables(db);
  runMigrations(db);
  ensureServerConfig(db, defaults);
  ensureServerSettings(db);
  seedDefaultChannels(db);
  ensureOwnerAssigned(db);

  return db;
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
  SELECT id, name, type, position, created_at
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

function touchSession(db, token) {
  db.prepare('UPDATE sessions SET last_seen_at = ? WHERE token = ?').run(nowIso(), token);
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
  const normalizedUserId = Number.isInteger(Number(userId)) ? Number(userId) : null;
  const normalizedCreatedBy = Number.isInteger(Number(createdByUserId)) ? Number(createdByUserId) : null;

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
