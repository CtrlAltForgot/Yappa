const {
  getActiveBanByUserId,
  getActiveBanByYuid,
  revokeSession,
  sessionTokenStorageValue,
  touchSession,
} = require('./db');
const { integerEnvironmentValue } = require('./config');

const SESSION_IDLE_TTL_MS = integerEnvironmentValue(
  'SESSION_IDLE_TTL_MS',
  7 * 24 * 60 * 60 * 1000,
  { min: 60 * 60 * 1000, max: 365 * 24 * 60 * 60 * 1000 },
);

function getBearerToken(req) {
  const header = req.headers.authorization || '';
  if (!header.startsWith('Bearer ')) return null;
  return header.slice('Bearer '.length).trim();
}

function getSessionWithUser(db, token) {
  const query = db.prepare(`
  SELECT
  sessions.id AS session_id,
  sessions.token,
  sessions.user_id,
  sessions.created_at AS session_created_at,
  sessions.last_seen_at,
  sessions.expires_at AS session_expires_at,
  sessions.idle_expires_at AS session_idle_expires_at,
  sessions.device_name AS session_device_name,
  sessions.media_device_id,
  media_devices.public_key AS media_device_public_key,
  media_devices.yuid_authorization_signature AS media_device_signature,
  media_devices.revoked_at AS media_device_revoked_at,
  users.username,
  users.role,
  users.display_name,
  users.avatar_url,
  users.created_at,
  users.last_login_at,
  users.yuid,
  users.yuid_public_key
  FROM sessions
  JOIN users ON users.id = sessions.user_id
  LEFT JOIN media_devices ON media_devices.id = sessions.media_device_id
  WHERE sessions.token = ?
  `);
  const storedToken = sessionTokenStorageValue(token);
  const hashedRow = query.get(storedToken);
  if (hashedRow) {
    if (sessionExpired(hashedRow)) {
      db.prepare('DELETE FROM sessions WHERE id = ?').run(hashedRow.session_id);
      return null;
    }
    return hashedRow;
  }

  // Upgrade a legacy raw-token row after its first successful use.
  const legacyRow = query.get(token);
  if (!legacyRow) {
    return null;
  }

  db.prepare('UPDATE sessions SET token = ? WHERE id = ?').run(
    storedToken,
    legacyRow.session_id,
  );
  const migratedRow = query.get(storedToken);
  if (sessionExpired(migratedRow)) {
    db.prepare('DELETE FROM sessions WHERE id = ?').run(migratedRow.session_id);
    return null;
  }
  return migratedRow;
}

function sessionExpired(row, now = Date.now()) {
  if (!row) return true;
  const absolute = Date.parse(row.session_expires_at || '');
  const idle = Date.parse(row.session_idle_expires_at || '');
  return (
    (Number.isFinite(absolute) && absolute <= now) ||
    (Number.isFinite(idle) && idle <= now)
  );
}

function nextIdleExpiry() {
  return new Date(Date.now() + SESSION_IDLE_TTL_MS).toISOString();
}

function buildAuthMiddleware(db) {
  return function authRequired(req, res, next) {
    const token = getBearerToken(req);
    if (!token) {
      return res.status(401).json({
        ok: false,
        error: {
          code: 'missing_bearer_token',
          message: 'Missing bearer token.',
        },
      });
    }

    const row = getSessionWithUser(db, token);
    if (!row) {
      return res.status(401).json({
        ok: false,
        error: {
          code: 'invalid_session_token',
          message: 'Invalid session token.',
        },
      });
    }

    const activeBan =
      getActiveBanByUserId(db, row.user_id) ||
      (row.yuid ? getActiveBanByYuid(db, row.yuid) : null);
    if (activeBan) {
      revokeSession(db, token);
      return res.status(403).json({
        ok: false,
        error: {
          code: 'account_banned',
          message: 'This account or YUID is banned from this server.',
          banId: String(activeBan.id),
          reason: activeBan.reason || null,
        },
      });
    }
    if (row.media_device_id && row.media_device_revoked_at) {
      revokeSession(db, token);
      return res.status(403).json({
        ok: false,
        error: {
          code: 'media_device_revoked',
          message: 'This device identity has been revoked.',
        },
      });
    }

    touchSession(db, token, nextIdleExpiry());

    req.auth = {
      token,
      user: {
        id: row.user_id,
        username: row.username,
        role: row.role,
        display_name: row.display_name || null,
        avatar_url: row.avatar_url || null,
        created_at: row.created_at || null,
        last_login_at: row.last_login_at || null,
        yuid: row.yuid || null,
        yuidVerified: Boolean(row.yuid && row.yuid_public_key),
      },
      session: {
        id: row.session_id,
        createdAt: row.session_created_at,
        expiresAt: row.session_expires_at || null,
        idleExpiresAt: row.session_idle_expires_at || null,
        deviceName: row.session_device_name || 'Yappa client',
        mediaDeviceId: row.media_device_id || null,
        mediaPublicKey: row.media_device_public_key || null,
        mediaDeviceSignature: row.media_device_signature || null,
      },
    };

    next();
  };
}

module.exports = {
  buildAuthMiddleware,
  getBearerToken,
  getSessionWithUser,
  nextIdleExpiry,
};
