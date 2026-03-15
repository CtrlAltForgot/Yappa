const { getActiveBanByUserId, getActiveBanByYuid, touchSession } = require('./db');

function getBearerToken(req) {
  const header = req.headers.authorization || '';
  if (!header.startsWith('Bearer ')) return null;
  return header.slice('Bearer '.length).trim();
}

function getSessionWithUser(db, token) {
  return db.prepare(`
  SELECT
  sessions.token,
  sessions.user_id,
  sessions.created_at AS session_created_at,
  sessions.last_seen_at,
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
  WHERE sessions.token = ?
  `).get(token);
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
      db.prepare('DELETE FROM sessions WHERE token = ?').run(token);
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

    touchSession(db, token);

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
        createdAt: row.session_created_at,
      },
    };

    next();
  };
}

module.exports = {
  buildAuthMiddleware,
  getBearerToken,
  getSessionWithUser,
};
