require('dotenv').config();

const crypto = require('crypto');
const dgram = require('dgram');
const dns = require('dns');
const fs = require('fs');
const http = require('http');
const https = require('https');
const net = require('net');
const path = require('path');
const express = require('express');
const cors = require('cors');
const bcrypt = require('bcryptjs');
const multer = require('multer');
const mime = require('mime-types');
const { Server } = require('socket.io');
const { createPinnedLookup } = require('./safe-preview-lookup');
const { readStorageCapacity } = require('./storage-capacity');
const nacl = require('tweetnacl');
const { AccessToken } = require('livekit-server-sdk');
const {
  bindUserYuid,
  createAttachment,
  createBan,
  createDb,
  createUserWithRole,
  ensureDir,
  getActiveBanByUserId,
  getActiveBanByYuid,
  getAllActiveBans,
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
  revokeBan,
  revokeSession,
  sessionTokenStorageValue,
  touchSession,
  touchUserLogin,
  touchUserYuid,
  updateServerSettings,
  updateUserProfile,
} = require('./db');
const {
  buildAuthMiddleware,
  getSessionWithUser,
  nextIdleExpiry,
} = require('./auth');
const {
  integerEnvironmentValue,
  optionalSecretEnvironmentValue,
} = require('./config');

const PORT = integerEnvironmentValue('PORT', 4100, { max: 65535 });
const LISTEN_HOST = String(process.env.LISTEN_HOST || '127.0.0.1').trim();
if (!net.isIP(LISTEN_HOST)) {
  console.error('[server] startup refused (code=invalid_configuration).');
  process.exit(1);
}
const DEFAULT_SERVER_NAME = process.env.SERVER_NAME || 'Night Wire';
const DEFAULT_SERVER_DESCRIPTION =
process.env.SERVER_DESCRIPTION || 'quiet grid for testing strange ideas';
const DB_PATH =
process.env.DB_PATH || path.join(process.cwd(), 'data', 'newchat.db');
const DATA_ROOT =
process.env.DATA_ROOT || path.join(path.dirname(DB_PATH), 'servers');
const CORS_ORIGIN = process.env.CORS_ORIGIN ?? '';
const TRUST_PROXY = String(process.env.TRUST_PROXY || '').toLowerCase() === 'true';
const JSON_BODY_LIMIT = process.env.JSON_BODY_LIMIT || '256kb';
const AUTH_RATE_LIMIT_WINDOW_MS = integerEnvironmentValue(
  'AUTH_RATE_LIMIT_WINDOW_MS',
  15 * 60 * 1000,
);
const AUTH_RATE_LIMIT_MAX = integerEnvironmentValue('AUTH_RATE_LIMIT_MAX', 10);
const AUTH_BACKOFF_FREE_FAILURES = integerEnvironmentValue(
  'AUTH_BACKOFF_FREE_FAILURES',
  3,
  { max: 20 },
);
const AUTH_BACKOFF_BASE_MS = integerEnvironmentValue(
  'AUTH_BACKOFF_BASE_MS',
  1000,
  { min: 50, max: 60 * 1000 },
);
const AUTH_BACKOFF_MAX_MS = integerEnvironmentValue(
  'AUTH_BACKOFF_MAX_MS',
  30000,
  { min: AUTH_BACKOFF_BASE_MS, max: 15 * 60 * 1000 },
);
const AUTH_BACKOFF_RESET_MS = integerEnvironmentValue(
  'AUTH_BACKOFF_RESET_MS',
  30 * 60 * 1000,
  { min: AUTH_BACKOFF_MAX_MS, max: 24 * 60 * 60 * 1000 },
);
const BCRYPT_COST = integerEnvironmentValue('BCRYPT_COST', 12, {
  min: 10,
  max: 15,
});
const NEW_ACCOUNT_PASSWORD_MIN_LENGTH = integerEnvironmentValue(
  'NEW_ACCOUNT_PASSWORD_MIN_LENGTH',
  10,
  { min: 10, max: 64 },
);
const CHALLENGE_RATE_LIMIT_WINDOW_MS = integerEnvironmentValue(
  'CHALLENGE_RATE_LIMIT_WINDOW_MS',
  60 * 1000,
);
const CHALLENGE_RATE_LIMIT_MAX = integerEnvironmentValue(
  'CHALLENGE_RATE_LIMIT_MAX',
  30,
);
const CONTENT_MUTATION_RATE_LIMIT_WINDOW_MS = integerEnvironmentValue(
  'CONTENT_MUTATION_RATE_LIMIT_WINDOW_MS',
  60 * 1000,
);
const CONTENT_MUTATION_RATE_LIMIT_MAX = integerEnvironmentValue(
  'CONTENT_MUTATION_RATE_LIMIT_MAX',
  120,
);
const EXPENSIVE_OPERATION_RATE_LIMIT_WINDOW_MS = integerEnvironmentValue(
  'EXPENSIVE_OPERATION_RATE_LIMIT_WINDOW_MS',
  60 * 1000,
);
const EXPENSIVE_OPERATION_RATE_LIMIT_MAX = integerEnvironmentValue(
  'EXPENSIVE_OPERATION_RATE_LIMIT_MAX',
  30,
);
const UPLOAD_RATE_LIMIT_WINDOW_MS = integerEnvironmentValue(
  'UPLOAD_RATE_LIMIT_WINDOW_MS',
  10 * 60 * 1000,
);
const UPLOAD_RATE_LIMIT_MAX = integerEnvironmentValue(
  'UPLOAD_RATE_LIMIT_MAX',
  20,
);
const ACCOUNT_MUTATION_RATE_LIMIT_WINDOW_MS = integerEnvironmentValue(
  'ACCOUNT_MUTATION_RATE_LIMIT_WINDOW_MS',
  60 * 1000,
);
const ACCOUNT_MUTATION_RATE_LIMIT_MAX = integerEnvironmentValue(
  'ACCOUNT_MUTATION_RATE_LIMIT_MAX',
  30,
);
const ATTACHMENT_DOWNLOAD_RATE_LIMIT_WINDOW_MS = integerEnvironmentValue(
  'ATTACHMENT_DOWNLOAD_RATE_LIMIT_WINDOW_MS',
  60 * 1000,
);
const ATTACHMENT_DOWNLOAD_RATE_LIMIT_MAX = integerEnvironmentValue(
  'ATTACHMENT_DOWNLOAD_RATE_LIMIT_MAX',
  300,
);
const SOCKET_CONTROL_RATE_LIMIT_WINDOW_MS = integerEnvironmentValue(
  'SOCKET_CONTROL_RATE_LIMIT_WINDOW_MS',
  60 * 1000,
);
const SOCKET_CONTROL_RATE_LIMIT_MAX = integerEnvironmentValue(
  'SOCKET_CONTROL_RATE_LIMIT_MAX',
  240,
);
const SOCKET_SIGNAL_RATE_LIMIT_WINDOW_MS = integerEnvironmentValue(
  'SOCKET_SIGNAL_RATE_LIMIT_WINDOW_MS',
  60 * 1000,
);
const SOCKET_SIGNAL_RATE_LIMIT_MAX = integerEnvironmentValue(
  'SOCKET_SIGNAL_RATE_LIMIT_MAX',
  1200,
);
const MEDIA_ENVELOPE_RATE_LIMIT_WINDOW_MS = integerEnvironmentValue(
  'MEDIA_ENVELOPE_RATE_LIMIT_WINDOW_MS',
  60 * 1000,
);
const MEDIA_ENVELOPE_RATE_LIMIT_MAX = integerEnvironmentValue(
  'MEDIA_ENVELOPE_RATE_LIMIT_MAX',
  240,
);
const SOCKET_CONNECTION_RATE_LIMIT_WINDOW_MS = integerEnvironmentValue(
  'SOCKET_CONNECTION_RATE_LIMIT_WINDOW_MS',
  60 * 1000,
);
const SOCKET_CONNECTION_RATE_LIMIT_MAX = integerEnvironmentValue(
  'SOCKET_CONNECTION_RATE_LIMIT_MAX',
  120,
);
const ATTACHMENT_URL_TTL_SECONDS = integerEnvironmentValue(
  'ATTACHMENT_URL_TTL_SECONDS',
  15 * 60,
  { min: 60, max: 3600 },
);
const DURABLE_STORAGE_CRITICAL_FREE_BYTES = integerEnvironmentValue(
  'DURABLE_STORAGE_CRITICAL_FREE_BYTES',
  512 * 1024 * 1024,
  { min: 16 * 1024 * 1024 },
);
const DURABLE_STORAGE_WARNING_FREE_BYTES = integerEnvironmentValue(
  'DURABLE_STORAGE_WARNING_FREE_BYTES',
  2 * 1024 * 1024 * 1024,
  { min: 16 * 1024 * 1024 },
);
if (
  DURABLE_STORAGE_WARNING_FREE_BYTES <=
  DURABLE_STORAGE_CRITICAL_FREE_BYTES
) {
  console.error('[server] startup refused (code=invalid_configuration).');
  process.exit(1);
}
const BACKUP_ROOT = String(process.env.YAPPA_BACKUP_ROOT || '').trim();
const configuredAttachmentSigningSecret = optionalSecretEnvironmentValue(
  'ATTACHMENT_SIGNING_SECRET',
);
const ATTACHMENT_SIGNING_SECRET =
  configuredAttachmentSigningSecret || crypto.randomBytes(32).toString('hex');
const LIVEKIT_URL = (process.env.LIVEKIT_URL || '').trim();
const LIVEKIT_PUBLIC_HOST = (process.env.LIVEKIT_PUBLIC_HOST || '').trim();
const LIVEKIT_PUBLIC_SCHEME = (process.env.LIVEKIT_PUBLIC_SCHEME || '').trim();
const LIVEKIT_SIGNAL_PORT = integerEnvironmentValue(
  'LIVEKIT_SIGNAL_PORT',
  7880,
  { max: 65535 },
);
const LIVEKIT_API_KEY = (process.env.LIVEKIT_API_KEY || '').trim();
const LIVEKIT_API_SECRET = optionalSecretEnvironmentValue(
  'LIVEKIT_API_SECRET',
);
const LIVEKIT_TOKEN_TTL = process.env.LIVEKIT_TOKEN_TTL || '12h';
const LAN_DISCOVERY_ENABLED =
  String(process.env.LAN_DISCOVERY_ENABLED || 'true').toLowerCase() === 'true';
const LAN_DISCOVERY_PORT = 41200;
const LAN_DISCOVERY_TLS_PORT = integerEnvironmentValue(
  'YAPPA_HTTPS_PORT',
  443,
  { max: 65535 },
);
const YAPPA_ADVERTISED_ADDRESS = String(
  process.env.YAPPA_ADVERTISED_ADDRESS || '',
).trim();
const YUID_CHALLENGE_TTL_MS = integerEnvironmentValue(
  'YUID_CHALLENGE_TTL_MS',
  5 * 60 * 1000,
);
const SESSION_ABSOLUTE_TTL_MS = integerEnvironmentValue(
  'SESSION_ABSOLUTE_TTL_MS',
  30 * 24 * 60 * 60 * 1000,
  { min: 24 * 60 * 60 * 1000, max: 365 * 24 * 60 * 60 * 1000 },
);

let db;
try {
  db = createDb(DB_PATH, {
    serverName: DEFAULT_SERVER_NAME,
    serverDescription: DEFAULT_SERVER_DESCRIPTION,
  });
} catch (error) {
  const code = String(error?.code || error?.name || 'unknown')
    .replace(/[^a-zA-Z0-9_.-]/g, '')
    .slice(0, 80);
  console.error(
    `[server] database initialization refused (code=${code || 'unknown'}).`,
  );
  process.exit(1);
}
const app = express();
app.disable('x-powered-by');
app.set('trust proxy', TRUST_PROXY);
const httpServer = http.createServer(app);
const configuredCorsOrigins = CORS_ORIGIN.split(',')
  .map((origin) => origin.trim())
  .filter(Boolean);
const allowAnyCorsOrigin = configuredCorsOrigins.includes('*');

function corsOriginAllowed(origin, callback) {
  if (!origin || allowAnyCorsOrigin || configuredCorsOrigins.includes(origin)) {
    callback(null, true);
    return;
  }

  const error = new Error('Origin is not allowed by this Yappa node.');
  error.code = 'cors_origin_denied';
  callback(error);
}

const io = new Server(httpServer, {
  cors: {
    origin: corsOriginAllowed,
    credentials: false,
  },
});

app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  res.setHeader('Content-Security-Policy', "default-src 'none'; frame-ancestors 'none'");
  if (req.secure) {
    res.setHeader(
      'Strict-Transport-Security',
      'max-age=31536000; includeSubDomains',
    );
  }
  next();
});
app.use(cors({ origin: corsOriginAllowed }));
app.use(express.json({ limit: JSON_BODY_LIMIT }));

function createRateLimiter({ windowMs, max, code, message, keyFor }) {
  const attempts = new Map();

  return (req, res, next) => {
    const now = Date.now();
    const key =
      keyFor?.(req) || req.ip || req.socket.remoteAddress || 'unknown';
    const current = attempts.get(key);
    const entry =
      !current || current.resetAt <= now
        ? { count: 0, resetAt: now + windowMs }
        : current;

    entry.count += 1;
    attempts.set(key, entry);

    const remaining = Math.max(0, max - entry.count);
    res.setHeader('RateLimit-Limit', String(max));
    res.setHeader('RateLimit-Remaining', String(remaining));
    res.setHeader(
      'RateLimit-Reset',
      String(Math.max(0, Math.ceil((entry.resetAt - now) / 1000))),
    );

    if (entry.count > max) {
      const retryAfter = Math.max(
        1,
        Math.ceil((entry.resetAt - now) / 1000),
      );
      res.setHeader('Retry-After', String(retryAfter));
      return apiError(res, 429, code, message, { retryAfter });
    }

    if (attempts.size > 10000) {
      for (const [storedKey, storedEntry] of attempts.entries()) {
        if (storedEntry.resetAt <= now) {
          attempts.delete(storedKey);
        }
      }
    }

    return next();
  };
}

function safeOperationalErrorCode(error) {
  const value = String(error?.code || error?.name || 'unknown');
  return value.replace(/[^a-zA-Z0-9_.-]/g, '').slice(0, 80) || 'unknown';
}

function logOperationalFailure(event, error) {
  console.error(
    `[server] ${event} failed (code=${safeOperationalErrorCode(error)}).`,
  );
}

const authRateLimit = createRateLimiter({
  windowMs: AUTH_RATE_LIMIT_WINDOW_MS,
  max: AUTH_RATE_LIMIT_MAX,
  code: 'auth_rate_limited',
  message: 'Too many sign-in attempts. Wait before trying again.',
});
const challengeRateLimit = createRateLimiter({
  windowMs: CHALLENGE_RATE_LIMIT_WINDOW_MS,
  max: CHALLENGE_RATE_LIMIT_MAX,
  code: 'challenge_rate_limited',
  message: 'Too many identity challenge requests. Try again shortly.',
});
const authenticatedRateLimitKey = (req) =>
  req.auth?.user?.id != null
    ? `user:${req.auth.user.id}`
    : `ip:${req.ip || req.socket.remoteAddress || 'unknown'}`;
const contentMutationRateLimit = createRateLimiter({
  windowMs: CONTENT_MUTATION_RATE_LIMIT_WINDOW_MS,
  max: CONTENT_MUTATION_RATE_LIMIT_MAX,
  code: 'content_rate_limited',
  message: 'Too many content changes. Wait briefly before trying again.',
  keyFor: authenticatedRateLimitKey,
});
const expensiveOperationRateLimit = createRateLimiter({
  windowMs: EXPENSIVE_OPERATION_RATE_LIMIT_WINDOW_MS,
  max: EXPENSIVE_OPERATION_RATE_LIMIT_MAX,
  code: 'operation_rate_limited',
  message: 'Too many resource-intensive requests. Try again shortly.',
  keyFor: authenticatedRateLimitKey,
});
const uploadRateLimit = createRateLimiter({
  windowMs: UPLOAD_RATE_LIMIT_WINDOW_MS,
  max: UPLOAD_RATE_LIMIT_MAX,
  code: 'upload_rate_limited',
  message: 'Too many attachment uploads. Try again later.',
  keyFor: authenticatedRateLimitKey,
});
const accountMutationRateLimit = createRateLimiter({
  windowMs: ACCOUNT_MUTATION_RATE_LIMIT_WINDOW_MS,
  max: ACCOUNT_MUTATION_RATE_LIMIT_MAX,
  code: 'account_rate_limited',
  message: 'Too many account or device changes. Try again shortly.',
  keyFor: authenticatedRateLimitKey,
});
const attachmentDownloadRateLimit = createRateLimiter({
  windowMs: ATTACHMENT_DOWNLOAD_RATE_LIMIT_WINDOW_MS,
  max: ATTACHMENT_DOWNLOAD_RATE_LIMIT_MAX,
  code: 'attachment_download_rate_limited',
  message: 'Too many attachment downloads. Try again shortly.',
});

const socketEventAttempts = new Map();
const socketConnectionAttempts = new Map();

function allowSocketConnection(socket) {
  const now = Date.now();
  const address =
    socket.handshake.address ||
    socket.request?.socket?.remoteAddress ||
    'unknown';
  const current = socketConnectionAttempts.get(address);
  const entry =
    !current || current.resetAt <= now
      ? {
          count: 0,
          resetAt: now + SOCKET_CONNECTION_RATE_LIMIT_WINDOW_MS,
        }
      : current;
  entry.count += 1;
  socketConnectionAttempts.set(address, entry);
  if (entry.count <= SOCKET_CONNECTION_RATE_LIMIT_MAX) return true;

  if (socketConnectionAttempts.size > 10000) {
    for (const [storedKey, storedEntry] of socketConnectionAttempts.entries()) {
      if (storedEntry.resetAt <= now) {
        socketConnectionAttempts.delete(storedKey);
      }
    }
  }
  return false;
}

function allowSocketEvent(socket, category, { windowMs, max }, ack) {
  const now = Date.now();
  const key = `${socket.user?.id ?? socket.id}:${category}`;
  const current = socketEventAttempts.get(key);
  const entry =
    !current || current.resetAt <= now
      ? { count: 0, resetAt: now + windowMs }
      : current;
  entry.count += 1;
  socketEventAttempts.set(key, entry);

  if (entry.count <= max) {
    return true;
  }

  const retryAfter = Math.max(
    1,
    Math.ceil((entry.resetAt - now) / 1000),
  );
  ack?.({
    ok: false,
    error: {
      code: 'socket_rate_limited',
      message: 'Too many realtime requests. Try again shortly.',
      retryAfter,
    },
  });

  if (socketEventAttempts.size > 10000) {
    for (const [storedKey, storedEntry] of socketEventAttempts.entries()) {
      if (storedEntry.resetAt <= now) {
        socketEventAttempts.delete(storedKey);
      }
    }
  }
  return false;
}

const socketControlLimit = {
  windowMs: SOCKET_CONTROL_RATE_LIMIT_WINDOW_MS,
  max: SOCKET_CONTROL_RATE_LIMIT_MAX,
};
const socketSignalLimit = {
  windowMs: SOCKET_SIGNAL_RATE_LIMIT_WINDOW_MS,
  max: SOCKET_SIGNAL_RATE_LIMIT_MAX,
};
const mediaEnvelopeLimit = {
  windowMs: MEDIA_ENVELOPE_RATE_LIMIT_WINDOW_MS,
  max: MEDIA_ENVELOPE_RATE_LIMIT_MAX,
};

const authFailuresByUserId = new Map();

function getAuthBackoff(userId) {
  const key = Number(userId);
  const now = Date.now();
  const entry = authFailuresByUserId.get(key);
  if (!entry) return null;
  if (entry.lastFailureAt + AUTH_BACKOFF_RESET_MS <= now) {
    authFailuresByUserId.delete(key);
    return null;
  }
  if (entry.blockedUntil <= now) return null;
  return {
    retryAfter: Math.max(1, Math.ceil((entry.blockedUntil - now) / 1000)),
  };
}

function recordAuthFailure(userId) {
  const key = Number(userId);
  const now = Date.now();
  const existing = authFailuresByUserId.get(key);
  const failures =
    !existing || existing.lastFailureAt + AUTH_BACKOFF_RESET_MS <= now
      ? 1
      : existing.failures + 1;
  const exponent = Math.max(0, failures - AUTH_BACKOFF_FREE_FAILURES);
  const delayMs =
    exponent === 0
      ? 0
      : Math.min(AUTH_BACKOFF_MAX_MS, AUTH_BACKOFF_BASE_MS * 2 ** (exponent - 1));
  const entry = {
    failures,
    lastFailureAt: now,
    blockedUntil: now + delayMs,
  };
  authFailuresByUserId.set(key, entry);

  if (authFailuresByUserId.size > 10000) {
    for (const [storedKey, storedEntry] of authFailuresByUserId.entries()) {
      if (storedEntry.lastFailureAt + AUTH_BACKOFF_RESET_MS <= now) {
        authFailuresByUserId.delete(storedKey);
      }
    }
  }

  return delayMs > 0
    ? { retryAfter: Math.max(1, Math.ceil(delayMs / 1000)) }
    : null;
}

function clearAuthFailures(userId) {
  authFailuresByUserId.delete(Number(userId));
}

function authBackoffError(res, backoff) {
  res.setHeader('Retry-After', String(backoff.retryAfter));
  return apiError(
    res,
    429,
    'auth_temporarily_locked',
    'Too many incorrect password attempts. Wait before trying again.',
    { retryAfter: backoff.retryAfter },
  );
}


const linkPreviewCache = new Map();
const LINK_PREVIEW_TTL_MS = Number(process.env.LINK_PREVIEW_TTL_MS || 10 * 60 * 1000);
const LINK_PREVIEW_TIMEOUT_MS = Number(process.env.LINK_PREVIEW_TIMEOUT_MS || 8000);

function cleanupLinkPreviewCache() {
  const now = Date.now();
  for (const [key, entry] of linkPreviewCache.entries()) {
    if (!entry || entry.expiresAt <= now) {
      linkPreviewCache.delete(key);
    }
  }
}

function getCachedLinkPreview(url) {
  cleanupLinkPreviewCache();
  const entry = linkPreviewCache.get(url);
  if (!entry || entry.expiresAt <= Date.now()) {
    linkPreviewCache.delete(url);
    return null;
  }
  return entry.value;
}

function setCachedLinkPreview(url, value) {
  linkPreviewCache.set(url, {
    value,
    expiresAt: Date.now() + LINK_PREVIEW_TTL_MS,
  });
}

function normalizePreviewUrl(raw) {
  const text = String(raw || '').trim();
  if (!text) return null;
  const normalized = /^www\./i.test(text) ? `https://${text}` : text;

  let parsed;
  try {
    parsed = new URL(normalized);
  } catch {
    return null;
  }

  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    return null;
  }

  return parsed.toString();
}

function resolveAbsoluteUrl(baseUrl, candidate) {
  const value = String(candidate || '').trim();
  if (!value) return null;
  try {
    return new URL(value, baseUrl).toString();
  } catch {
    return null;
  }
}

function decodeHtmlEntities(value) {
  const text = String(value || '');
  return text
    .replace(/&#(\d+);/g, (_match, code) => {
      const parsed = Number(code);
      return Number.isFinite(parsed) ? String.fromCodePoint(parsed) : _match;
    })
    .replace(/&#x([0-9a-f]+);/gi, (_match, code) => {
      const parsed = parseInt(code, 16);
      return Number.isFinite(parsed) ? String.fromCodePoint(parsed) : _match;
    })
    .replace(/&amp;/gi, '&')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/&apos;/gi, "'")
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&nbsp;/gi, ' ');
}

function stripHtml(value) {
  return decodeHtmlEntities(String(value || '').replace(/<[^>]+>/g, ' '))
    .replace(/\s+/g, ' ')
    .trim();
}

function parseHtmlAttributes(tag) {
  const attrs = {};
  const regex = /([a-zA-Z_:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/g;
  let match;
  while ((match = regex.exec(tag)) !== null) {
    const key = String(match[1] || '').toLowerCase();
    const value = match[2] ?? match[3] ?? match[4] ?? '';
    attrs[key] = value;
  }
  return attrs;
}

function extractMetaContent(html, keys) {
  const desired = new Set(keys.map((key) => String(key).toLowerCase()));
  const regex = /<meta\b[^>]*>/gi;
  let match;
  while ((match = regex.exec(html)) !== null) {
    const attrs = parseHtmlAttributes(match[0]);
    const key = String(attrs.property || attrs.name || attrs.itemprop || '').toLowerCase();
    const content = attrs.content;
    if (desired.has(key) && content) {
      const cleaned = stripHtml(content);
      if (cleaned) {
        return cleaned;
      }
    }
  }
  return null;
}

function extractLinkHref(html, relValues) {
  const desired = relValues.map((value) => String(value).toLowerCase());
  const regex = /<link\b[^>]*>/gi;
  let match;
  while ((match = regex.exec(html)) !== null) {
    const attrs = parseHtmlAttributes(match[0]);
    const rel = String(attrs.rel || '').toLowerCase();
    const href = attrs.href;
    if (!href) continue;
    if (desired.some((value) => rel.includes(value))) {
      return href;
    }
  }
  return null;
}

function extractFirstImageSource(html) {
  const regex = /<img\b[^>]*src\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))[^>]*>/i;
  const match = regex.exec(html);
  if (!match) return null;
  return match[1] || match[2] || match[3] || null;
}

function extractTitle(html) {
  const titleMatch = /<title\b[^>]*>([\s\S]*?)<\/title>/i.exec(html);
  if (!titleMatch) return null;
  return stripHtml(titleMatch[1]);
}

function extractFirstUsefulParagraph(html) {
  const withoutNonContent = String(html || '').replace(
    /<(?:script|style|noscript|svg|nav|header|footer)\b[\s\S]*?<\/(?:script|style|noscript|svg|nav|header|footer)>/gi,
    ' ',
  );
  const paragraphPattern = /<p\b[^>]*>([\s\S]*?)<\/p>/gi;
  let match;
  while ((match = paragraphPattern.exec(withoutNonContent)) !== null) {
    const paragraph = stripHtml(match[1]);
    if (paragraph.length >= 40) {
      return paragraph;
    }
  }
  return null;
}

function truncateText(value, maxLength) {
  const text = String(value || '').trim();
  if (!text) return '';
  return text.length > maxLength ? `${text.slice(0, maxLength - 1)}…` : text;
}

function recognizedVideoEmbed(url) {
  const parsed = new URL(url);
  const host = parsed.hostname.toLowerCase().replace(/^www\./, '');

  if (host === 'youtu.be') {
    const videoId = parsed.pathname.split('/').filter(Boolean)[0] || '';
    if (/^[a-zA-Z0-9_-]{6,20}$/.test(videoId)) {
      return {
        mediaUrl: `https://www.youtube.com/embed/${videoId}?feature=oembed&autoplay=1`,
        imageUrl: `https://i.ytimg.com/vi/${videoId}/hqdefault.jpg`,
        mediaAspectRatio: 16 / 9,
      };
    }
  }
  if (host === 'youtube.com' || host === 'm.youtube.com') {
    const parts = parsed.pathname.split('/').filter(Boolean);
    const videoId =
      parsed.pathname === '/watch'
        ? parsed.searchParams.get('v') || ''
        : ['shorts', 'embed', 'live'].includes(parts[0])
          ? parts[1] || ''
          : '';
    if (/^[a-zA-Z0-9_-]{6,20}$/.test(videoId)) {
      return {
        mediaUrl: `https://www.youtube.com/embed/${videoId}?feature=oembed&autoplay=1`,
        imageUrl: `https://i.ytimg.com/vi/${videoId}/hqdefault.jpg`,
        mediaAspectRatio: 16 / 9,
      };
    }
  }
  if (host === 'vimeo.com' || host === 'player.vimeo.com') {
    const videoId = parsed.pathname.split('/').filter(Boolean).find((part) =>
      /^\d+$/.test(part),
    );
    if (videoId) {
      return {
        mediaUrl: `https://player.vimeo.com/video/${videoId}?autoplay=1`,
        imageUrl: null,
        mediaAspectRatio: 16 / 9,
      };
    }
  }
  if (host === 'tiktok.com' || host === 'm.tiktok.com') {
    const match = /\/video\/(\d+)/.exec(parsed.pathname);
    if (match) {
      return {
        mediaUrl: `https://www.tiktok.com/player/v1/${match[1]}?autoplay=1`,
        imageUrl: null,
        mediaAspectRatio: 9 / 16,
      };
    }
  }
  return null;
}

function isNonPublicPreviewAddress(address) {
  const normalized = String(address || '').toLowerCase();
  const family = net.isIP(normalized);
  if (family === 4) {
    const bytes = normalized.split('.').map(Number);
    return (
      bytes[0] === 0 ||
      bytes[0] === 10 ||
      (bytes[0] === 100 && bytes[1] >= 64 && bytes[1] <= 127) ||
      bytes[0] === 127 ||
      (bytes[0] === 169 && bytes[1] === 254) ||
      (bytes[0] === 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
      (bytes[0] === 192 &&
        ((bytes[1] === 0 && (bytes[2] === 0 || bytes[2] === 2)) ||
          bytes[1] === 168)) ||
      (bytes[0] === 198 &&
        (bytes[1] === 18 || bytes[1] === 19 || bytes[1] === 51)) ||
      (bytes[0] === 203 && bytes[1] === 0 && bytes[2] === 113) ||
      bytes[0] >= 224
    );
  }
  if (family === 6) {
    if (normalized.startsWith('::ffff:')) {
      return isNonPublicPreviewAddress(normalized.slice('::ffff:'.length));
    }
    return (
      normalized === '::' ||
      normalized === '::1' ||
      normalized.startsWith('fc') ||
      normalized.startsWith('fd') ||
      /^fe[89ab]/.test(normalized) ||
      normalized.startsWith('ff')
    );
  }
  return true;
}

async function resolvePublicPreviewTarget(url) {
  const parsed = new URL(url);
  if (parsed.username || parsed.password) {
    throw new Error('Preview URLs cannot include credentials.');
  }

  const literalFamily = net.isIP(parsed.hostname);
  const addresses = literalFamily
    ? [{ address: parsed.hostname, family: literalFamily }]
    : await dns.promises.lookup(parsed.hostname, {
        all: true,
        verbatim: true,
      });
  if (
    addresses.length === 0 ||
    addresses.some((entry) => isNonPublicPreviewAddress(entry.address))
  ) {
    throw new Error('Preview target is not a public internet address.');
  }
  return { parsed, target: addresses[0] };
}

async function requestPreviewResource(url, redirectCount = 0) {
  if (redirectCount > 5) {
    throw new Error('Preview redirected too many times.');
  }
  const { parsed, target } = await resolvePublicPreviewTarget(url);
  const transport = parsed.protocol === 'https:' ? https : http;

  const response = await new Promise((resolve, reject) => {
    const request = transport.request(
      parsed,
      {
        headers: {
          'user-agent':
            'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ' +
            'Chrome/124 Safari/537.36 YappaLinkPreview/1.0',
          accept:
            'text/html,application/xhtml+xml,image/avif,image/webp,' +
            'image/apng,*/*;q=0.8',
          'accept-language': 'en-US,en;q=0.9',
        },
        servername: parsed.hostname,
        lookup: createPinnedLookup(target),
      },
      (incoming) => resolve(incoming),
    );
    request.setTimeout(LINK_PREVIEW_TIMEOUT_MS, () => {
      request.destroy(new Error('Preview request timed out.'));
    });
    request.on('error', reject);
    request.end();
  });

  const statusCode = Number(response.statusCode || 0);
  if (statusCode >= 300 && statusCode < 400 && response.headers.location) {
    response.resume();
    const redirectUrl = new URL(response.headers.location, parsed).toString();
    return requestPreviewResource(redirectUrl, redirectCount + 1);
  }
  if (statusCode < 200 || statusCode >= 300) {
    response.resume();
    throw new Error(`Preview target returned HTTP ${statusCode}.`);
  }

  const contentType = String(response.headers['content-type'] || '').toLowerCase();
  if (contentType.startsWith('image/')) {
    response.destroy();
    return {
      finalUrl: parsed.toString(),
      contentType,
      body: '',
    };
  }

  const chunks = [];
  let receivedBytes = 0;
  for await (const chunk of response) {
    receivedBytes += chunk.length;
    if (receivedBytes > 600000) {
      response.destroy();
      break;
    }
    chunks.push(chunk);
  }
  return {
    finalUrl: parsed.toString(),
    contentType,
    body: Buffer.concat(chunks).toString('utf8'),
  };
}

async function loadLinkPreview(url) {
  const cached = getCachedLinkPreview(url);
  if (cached) {
    return cached;
  }

  const response = await requestPreviewResource(url);
  const finalUrl = response.finalUrl || url;
  const parsedUrl = new URL(finalUrl);
  const contentType = response.contentType;

  if (contentType.startsWith('image/')) {
    const preview = {
      url,
      finalUrl,
      hostname: parsedUrl.hostname,
      siteName: parsedUrl.hostname,
      title: path.basename(parsedUrl.pathname) || parsedUrl.hostname,
      description: null,
      imageUrl: finalUrl,
      iconUrl: null,
      mediaUrl: null,
      mediaAspectRatio: null,
      kind: 'image',
      contentType,
    };
    setCachedLinkPreview(url, preview);
    return preview;
  }

  const html = response.body.slice(0, 600000);

  const title = truncateText(
    extractMetaContent(html, ['og:title', 'twitter:title']) ||
      extractTitle(html) ||
      parsedUrl.hostname,
    180,
  );
  const description =
    truncateText(
      extractMetaContent(html, [
        'og:description',
        'twitter:description',
        'description',
      ]) ||
        extractFirstUsefulParagraph(html) ||
        '',
      280,
    ) || null;
  const siteName = truncateText(
    extractMetaContent(html, ['og:site_name', 'application-name']) ||
      parsedUrl.hostname,
    80,
  );

  const recognizedVideo = recognizedVideoEmbed(finalUrl);
  const imageCandidate =
    recognizedVideo?.imageUrl ||
    extractMetaContent(html, [
      'og:image',
      'og:image:url',
      'og:image:secure_url',
      'twitter:image',
      'twitter:image:src',
      'image',
    ]) ||
    extractLinkHref(html, ['image_src']) ||
    extractFirstImageSource(html);
  const faviconCandidate = extractLinkHref(html, ['icon']) || '/favicon.ico';

  const preview = {
    url,
    finalUrl,
    hostname: parsedUrl.hostname,
    siteName,
    title,
    description,
    imageUrl: resolveAbsoluteUrl(finalUrl, imageCandidate),
    iconUrl: resolveAbsoluteUrl(finalUrl, faviconCandidate),
    mediaUrl: recognizedVideo?.mediaUrl || null,
    mediaAspectRatio: recognizedVideo?.mediaAspectRatio || null,
    kind: recognizedVideo ? 'video' : 'link',
    contentType,
  };

  setCachedLinkPreview(url, preview);
  return preview;
}

async function loadSafeLinkPreviewFallback(url) {
  const { parsed } = await resolvePublicPreviewTarget(url);
  const finalUrl = parsed.toString();
  const video = recognizedVideoEmbed(finalUrl);
  const preview = {
    url,
    finalUrl,
    hostname: parsed.hostname,
    siteName: parsed.hostname,
    title: parsed.hostname,
    description: null,
    imageUrl: video?.imageUrl || null,
    iconUrl: new URL('/favicon.ico', parsed).toString(),
    mediaUrl: video?.mediaUrl || null,
    mediaAspectRatio: video?.mediaAspectRatio || null,
    kind: video ? 'video' : 'link',
    contentType: '',
  };
  setCachedLinkPreview(url, preview);
  return preview;
}

const authRequired = buildAuthMiddleware(db);
const socketPresence = new Map();
const onlineUsersById = new Map();
const mediaRoomStates = new Map();
const yuidChallenges = new Map();
const serverId = getServerConfig(db).server_id;
const serverRoot = path.join(DATA_ROOT, serverId);
const attachmentsRoot = path.join(serverRoot, 'attachments');
const encryptedAttachmentsRoot = path.join(
  serverRoot,
  'encrypted-attachments',
);
const sharedStorageRoot = path.join(serverRoot, 'storage', 'root');
const brandingRoot = path.join(serverRoot, 'branding');
const brandingIconRoot = path.join(brandingRoot, 'icon');
const brandingBannerRoot = path.join(brandingRoot, 'banner');

ensureDir(attachmentsRoot);
ensureDir(encryptedAttachmentsRoot);
ensureDir(sharedStorageRoot);
ensureDir(brandingIconRoot);
ensureDir(brandingBannerRoot);

function currentStorageCapacity({
  incomingBytes = 0,
  includeBackupSize = false,
} = {}) {
  return readStorageCapacity({
    db,
    dbPath: path.resolve(DB_PATH),
    dataRoot: path.resolve(DATA_ROOT),
    backupRoot: BACKUP_ROOT ? path.resolve(BACKUP_ROOT) : '',
    warningFreeBytes: DURABLE_STORAGE_WARNING_FREE_BYTES,
    criticalFreeBytes: DURABLE_STORAGE_CRITICAL_FREE_BYTES,
    incomingBytes,
    includeBackupSize,
  });
}

function expectedRequestBytes(req) {
  const raw = String(req.headers['content-length'] || '');
  if (!/^[0-9]+$/.test(raw)) return 0;
  const value = Number(raw);
  return Number.isSafeInteger(value) ? value : Number.MAX_SAFE_INTEGER;
}

function requireDurableStorage(
  req,
  res,
  { uploadedFile, incomingBytes: incomingBytesOverride } = {},
) {
  const incomingBytes = incomingBytesOverride == null
    ? Math.max(
        expectedRequestBytes(req),
        Number(uploadedFile?.size || 0),
      )
    : incomingBytesOverride;
  const capacity = currentStorageCapacity({ incomingBytes });
  if (capacity.acceptsDurableWrites) {
    return true;
  }
  if (uploadedFile?.path) {
    fs.unlink(uploadedFile.path, () => {});
  }
  res.setHeader('Retry-After', '60');
  apiError(
    res,
    507,
    'durable_storage_unavailable',
    'The server cannot safely store another durable message right now.',
    {
      retryable: true,
      storageStatus: capacity.status,
    },
  );
  return false;
}

function durableStorageRequired(req, res, next) {
  if (!requireDurableStorage(req, res)) {
    return;
  }
  next();
}

const serverIdentityPath = path.join(serverRoot, 'server-identity.json');

function loadOrCreateServerIdentity() {
  if (fs.existsSync(serverIdentityPath)) {
    const stored = JSON.parse(fs.readFileSync(serverIdentityPath, 'utf8'));
    const privateKey = crypto.createPrivateKey(stored.privateKeyPem);
    const publicKey = crypto.createPublicKey(privateKey);
    const publicJwk = publicKey.export({ format: 'jwk' });
    if (
      stored.algorithm !== 'Ed25519' ||
      typeof stored.publicKey !== 'string' ||
      stored.publicKey !== publicJwk.x
    ) {
      throw new Error('Invalid persisted server identity.');
    }
    return {
      algorithm: stored.algorithm,
      publicKey: stored.publicKey,
      privateKey,
    };
  }

  const generated = crypto.generateKeyPairSync('ed25519');
  const publicJwk = generated.publicKey.export({ format: 'jwk' });
  const record = {
    version: 1,
    algorithm: 'Ed25519',
    publicKey: publicJwk.x,
    privateKeyPem: generated.privateKey.export({
      format: 'pem',
      type: 'pkcs8',
    }),
    createdAt: nowIso(),
  };
  const temporaryPath = `${serverIdentityPath}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(temporaryPath, `${JSON.stringify(record, null, 2)}\n`, {
    mode: 0o600,
    flag: 'wx',
  });
  fs.renameSync(temporaryPath, serverIdentityPath);
  fs.chmodSync(serverIdentityPath, 0o600);
  return {
    algorithm: record.algorithm,
    publicKey: record.publicKey,
    privateKey: generated.privateKey,
  };
}

const serverIdentity = loadOrCreateServerIdentity();

function activeMediaRoomMembers(channelId) {
  const byDeviceId = new Map();
  for (const [socketId, presence] of socketPresence.entries()) {
    if (
      toId(presence.voiceChannelId) !== toId(channelId) ||
      !presence.mediaDeviceId
    ) {
      continue;
    }
    const existing = byDeviceId.get(presence.mediaDeviceId);
    if (!existing || socketId < existing.socketId) {
      byDeviceId.set(presence.mediaDeviceId, {
        socketId,
        deviceId: presence.mediaDeviceId,
        userId: toId(presence.userId),
      });
    }
  }

  const members = [];
  for (const active of byDeviceId.values()) {
    const row = db
      .prepare(`
        SELECT media_devices.*, users.username, users.yuid,
               users.yuid_public_key
        FROM media_devices
        JOIN users ON users.id = media_devices.user_id
        WHERE media_devices.id = ?
          AND media_devices.revoked_at IS NULL
          AND NOT EXISTS (
            SELECT 1
            FROM bans
            WHERE bans.revoked_at IS NULL
              AND (
                bans.user_id = users.id
                OR (
                  bans.yuid IS NOT NULL
                  AND users.yuid IS NOT NULL
                  AND bans.yuid = users.yuid
                )
              )
          )
      `)
      .get(active.deviceId);
    if (!row) continue;
    members.push({
      socketId: active.socketId,
      device: {
        ...serializeMediaDevice(row),
        username: row.username,
        yuid: row.yuid,
        yuidPublicKey: row.yuid_public_key,
      },
    });
  }
  // Device ids are restricted to ASCII base64url characters. Compare their
  // UTF-16/code-point values directly so every JavaScript and Dart client
  // elects the same leader regardless of host locale.
  members.sort((first, second) =>
    first.device.id < second.device.id
      ? -1
      : first.device.id > second.device.id
        ? 1
        : 0,
  );
  return members;
}

function emitMediaRoomState(channelId, { forceRotation = false } = {}) {
  if (channelId == null || channelId === '') return null;
  const roomKey = toId(channelId);
  const previous = mediaRoomStates.get(roomKey);
  const members = activeMediaRoomMembers(roomKey);
  if (members.length === 0) {
    mediaRoomStates.delete(roomKey);
    return null;
  }

  const deviceIds = members.map((member) => member.device.id);
  const previousIds = previous?.deviceIds || [];
  const membershipChanged =
    previousIds.length !== deviceIds.length ||
    previousIds.some((deviceId, index) => deviceId !== deviceIds[index]);
  const removedMember = previousIds.some(
    (deviceId) => !deviceIds.includes(deviceId),
  );
  const leaderDeviceId = deviceIds[0];
  const leaderChanged =
    previous != null && previous.leaderDeviceId !== leaderDeviceId;
  const shouldRotate =
    previous == null || forceRotation || removedMember || leaderChanged;
  const state = {
    channelId: roomKey,
    epoch: previous == null
      ? 1
      : previous.epoch + (shouldRotate ? 1 : 0),
    membershipSequence:
      (previous?.membershipSequence || 0) + (membershipChanged ? 1 : 0),
    leaderDeviceId,
    deviceIds,
    lastEnvelopeSequenceBySender:
      shouldRotate
        ? new Map()
        : (previous?.lastEnvelopeSequenceBySender || new Map()),
  };
  mediaRoomStates.set(roomKey, state);

  const payload = {
    protocol: 'yappa-media-room-v1',
    serverId,
    channelId: roomKey,
    epoch: state.epoch,
    membershipSequence: state.membershipSequence,
    leaderDeviceId,
    devices: members.map((member) => member.device),
  };
  for (const member of members) {
    io.to(member.socketId).emit('media:e2ee:state', payload);
  }
  return state;
}

function validateMediaEnvelopePayload(envelope) {
  if (!envelope || typeof envelope !== 'object' || Array.isArray(envelope)) {
    return false;
  }
  if (
    envelope.protocol !== 'yappa-media-envelope-v1' ||
    envelope.serverId !== serverId ||
    !/^\d+$/.test(String(envelope.channelId || '')) ||
    !Number.isSafeInteger(envelope.epoch) ||
    envelope.epoch < 1 ||
    !Number.isSafeInteger(envelope.messageSequence) ||
    envelope.messageSequence < 1 ||
    !/^device_[A-Za-z0-9_-]{24}$/.test(envelope.senderDeviceId || '') ||
    !/^device_[A-Za-z0-9_-]{24}$/.test(envelope.recipientDeviceId || '')
  ) {
    return false;
  }
  const encodedLengths = {
    ephemeralPublicKey: 43,
    nonce: 16,
    authenticationTag: 22,
    signature: 86,
  };
  for (const [field, exactLength] of Object.entries(encodedLengths)) {
    const value = envelope[field];
    if (
      typeof value !== 'string' ||
      value.length !== exactLength ||
      !/^[A-Za-z0-9_-]+$/.test(value)
    ) {
      return false;
    }
  }
  return (
    typeof envelope.ciphertext === 'string' &&
    envelope.ciphertext.length === 59 &&
    /^[A-Za-z0-9_-]+$/.test(envelope.ciphertext)
  );
}

function encodeMediaEnvelopeFields(values) {
  const fields = [];
  for (const value of values) {
    const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value, 'utf8');
    const length = Buffer.allocUnsafe(4);
    length.writeUInt32BE(bytes.length);
    fields.push(length, bytes);
  }
  return Buffer.concat(fields);
}

function verifyRelayedMediaEnvelope(envelope, senderDevice) {
  try {
    const ephemeralPublicKey = Buffer.from(
      envelope.ephemeralPublicKey,
      'base64url',
    );
    const nonce = Buffer.from(envelope.nonce, 'base64url');
    const ciphertext = Buffer.from(envelope.ciphertext, 'base64url');
    const authenticationTag = Buffer.from(
      envelope.authenticationTag,
      'base64url',
    );
    const signature = Buffer.from(envelope.signature, 'base64url');
    const yuidPublicKey = Buffer.from(
      senderDevice.yuidPublicKey,
      'base64url',
    );
    if (
      ephemeralPublicKey.length !== 32 ||
      nonce.length !== 12 ||
      ciphertext.length !== 44 ||
      authenticationTag.length !== 16 ||
      signature.length !== 64 ||
      yuidPublicKey.length !== 32
    ) {
      return false;
    }
    const associatedData = encodeMediaEnvelopeFields([
      'yappa-media-envelope-v1',
      envelope.serverId,
      toId(envelope.channelId),
      String(envelope.epoch),
      envelope.senderDeviceId,
      envelope.recipientDeviceId,
      ephemeralPublicKey,
    ]);
    const signedPayload = encodeMediaEnvelopeFields([
      associatedData,
      nonce,
      ciphertext,
      authenticationTag,
      String(envelope.messageSequence),
    ]);
    return nacl.sign.detached.verify(
      new Uint8Array(signedPayload),
      new Uint8Array(signature),
      new Uint8Array(yuidPublicKey),
    );
  } catch {
    return false;
  }
}

function startLanDiscovery() {
  if (!LAN_DISCOVERY_ENABLED) return;
  const requestCounts = new Map();
  const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });
  socket.on('message', (message, remote) => {
    if (message.length > 512) return;
    let request;
    try {
      request = JSON.parse(message.toString('utf8'));
    } catch {
      return;
    }
    const nonce = String(request?.nonce || '').trim();
    if (
      request?.protocol !== 'yappa-lan-discovery-v1' ||
      !/^[A-Za-z0-9_-]{22,128}$/.test(nonce)
    ) {
      return;
    }

    const now = Date.now();
    const normalizedRemoteAddress = remote.address.replace(/^::ffff:/, '');
    const relayClientAddress = String(
      request?.relayClientAddress || '',
    ).trim();
    const trustedRelay =
      (normalizedRemoteAddress === '127.0.0.1' ||
        normalizedRemoteAddress === '::1') &&
      /^(10\.|127\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)/.test(
        relayClientAddress,
      );
    const rateAddress = trustedRelay
      ? relayClientAddress
      : normalizedRemoteAddress;
    const previous = requestCounts.get(rateAddress);
    const rate =
      !previous || previous.resetAt <= now
        ? { count: 0, resetAt: now + 60_000 }
        : previous;
    rate.count += 1;
    requestCounts.set(rateAddress, rate);
    if (rate.count > 30) return;
    if (requestCounts.size > 1000) {
      for (const [address, entry] of requestCounts.entries()) {
        if (entry.resetAt <= now) requestCounts.delete(address);
      }
    }

    const proof =
      `yappa-lan-discovery-v1|${serverId}|${nonce}|` +
      `${LAN_DISCOVERY_TLS_PORT}|${YAPPA_ADVERTISED_ADDRESS}`;
    const response = Buffer.from(
      JSON.stringify({
        protocol: 'yappa-lan-discovery-v1',
        serverId,
        algorithm: serverIdentity.algorithm,
        publicKey: serverIdentity.publicKey,
        nonce,
        tlsPort: LAN_DISCOVERY_TLS_PORT,
        advertisedAddress: YAPPA_ADVERTISED_ADDRESS,
        signature: crypto
          .sign(null, Buffer.from(proof, 'utf8'), serverIdentity.privateKey)
          .toString('base64url'),
      }),
      'utf8',
    );
    socket.send(response, remote.port, remote.address);
  });
  socket.on('error', (error) => {
    logOperationalFailure('LAN discovery', error);
  });
  socket.bind(LAN_DISCOVERY_PORT, '0.0.0.0');
}

startLanDiscovery();

app.use(
  `/uploads/${serverId}/branding`,
  express.static(brandingRoot, {
    fallthrough: false,
    maxAge: '1h',
  }),
);

function toId(value) {
  return String(value);
}

function serializeSession(row, currentSessionId = null) {
  return {
    id: toId(row.id),
    deviceName: row.device_name || 'Yappa client',
    createdAt: row.created_at,
    lastSeenAt: row.last_seen_at,
    expiresAt: row.expires_at || null,
    idleExpiresAt: row.idle_expires_at || null,
    current: Number(row.id) === Number(currentSessionId),
  };
}

function safeJsonParse(value, fallback) {
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

function apiError(res, status, code, message, extra = {}) {
  return res.status(status).json({
    ok: false,
    error: {
      code,
      message,
      ...extra,
    },
  });
}

function initialsFromName(name) {
  return (
    String(name || '')
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0]?.toUpperCase() || '')
    .join('') || 'NC'
  );
}

function isOwner(user) {
  return user?.role === 'owner';
}

function serializeServerConfig(row) {
  const branding = safeJsonParse(row.branding_json, {});
  return {
    id: row.server_id,
    name: row.name,
    shortName: initialsFromName(row.name),
    description: row.description,
    tagline: row.description,
    branding: {
      accentColor: branding.accentColor || '#8b0c14',
      iconUrl: branding.iconUrl || null,
      bannerUrl: branding.bannerUrl || null,
    },
    ownerUserId: row.owner_user_id ? toId(row.owner_user_id) : null,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function serializeServerSettings(row) {
  return {
    attachmentRetentionDays: Number(row.attachment_retention_days),
    attachmentMaxBytes: Number(row.attachment_max_bytes),
    attachmentAllowedTypes: safeJsonParse(
      row.attachment_allowed_types_json,
      [],
    ),
    fileStorageEnabled: Boolean(row.file_storage_enabled),
    fileStorageMaxTotalBytes: Number(row.file_storage_max_total_bytes),
    fileStorageMaxFileBytes: Number(row.file_storage_max_file_bytes),
    fileStorageAllowedTypes: safeJsonParse(
      row.file_storage_allowed_types_json,
      ['*'],
    ),
    inlineMediaPreviewsEnabled: Boolean(row.inline_media_previews_enabled),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function buildVoiceRoomName(channelId) {
  return `${serverId}:voice:${toId(channelId)}`;
}

function ensureLiveKitConfigured() {
  return Boolean(LIVEKIT_API_KEY && LIVEKIT_API_SECRET);
}

function stripPortFromHost(host) {
  const value = String(host || '').trim();
  if (!value) return '';

  if (value.startsWith('[')) {
    const closingBracket = value.indexOf(']');
    return closingBracket >= 0 ? value.slice(0, closingBracket + 1) : value;
  }

  const firstColon = value.indexOf(':');
  const lastColon = value.lastIndexOf(':');
  if (firstColon >= 0 && firstColon === lastColon) {
    return value.slice(0, firstColon);
  }

  return value;
}

function isPrivateOrDevelopmentHost(input) {
  const host = String(input || '')
    .trim()
    .toLowerCase()
    .replace(/^\[|\]$/g, '');
  if (
    host === 'localhost' ||
    host.endsWith('.localhost') ||
    host.endsWith('.local') ||
    host.endsWith('.internal') ||
    !host.includes('.')
  ) {
    return true;
  }

  const family = net.isIP(host);
  if (family === 4) {
    const bytes = host.split('.').map(Number);
    return (
      bytes[0] === 10 ||
      bytes[0] === 127 ||
      (bytes[0] === 169 && bytes[1] === 254) ||
      (bytes[0] === 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
      (bytes[0] === 192 && bytes[1] === 168)
    );
  }
  if (family === 6) {
    return (
      host === '::1' ||
      host.startsWith('fc') ||
      host.startsWith('fd') ||
      /^fe[89ab]/.test(host)
    );
  }
  return false;
}

function resolveLiveKitWebSocketUrl(req) {
  const rawHost = String(req.get('x-forwarded-host') || req.get('host') || '')
    .split(',')[0]
    .trim();
  const host = stripPortFromHost(rawHost) || '127.0.0.1';

  if (isPrivateOrDevelopmentHost(host)) {
    return `ws://${host}:${LIVEKIT_SIGNAL_PORT}`;
  }

  if (LIVEKIT_URL) {
    return LIVEKIT_URL;
  }

  if (LIVEKIT_PUBLIC_HOST) {
    if (/^wss?:\/\//i.test(LIVEKIT_PUBLIC_HOST)) {
      return LIVEKIT_PUBLIC_HOST;
    }

    const scheme = LIVEKIT_PUBLIC_SCHEME || 'ws';
    return `${scheme}://${LIVEKIT_PUBLIC_HOST}:${LIVEKIT_SIGNAL_PORT}`;
  }

  const forwardedProto = String(
    req.get('x-forwarded-proto') || req.protocol || 'http',
  )
    .split(',')[0]
    .trim()
    .toLowerCase();
  const scheme = forwardedProto === 'https' ? 'wss' : 'ws';

  return `${scheme}://${host}:${LIVEKIT_SIGNAL_PORT}`;
}

function cleanupExpiredYuidChallenges() {
  const now = Date.now();
  for (const [nonce, value] of yuidChallenges.entries()) {
    if (!value || value.expiresAtMs <= now) {
      yuidChallenges.delete(nonce);
    }
  }
}

function issueYuidChallenge() {
  cleanupExpiredYuidChallenges();
  const now = new Date();
  const expiresAt = new Date(now.getTime() + YUID_CHALLENGE_TTL_MS);
  const nonce = crypto.randomBytes(24).toString('base64url');
  yuidChallenges.set(nonce, {
    issuedAtMs: now.getTime(),
    expiresAtMs: expiresAt.getTime(),
  });
  return {
    serverId,
    nonce,
    issuedAt: now.toISOString(),
    expiresAt: expiresAt.toISOString(),
  };
}

function consumeYuidChallenge(nonce) {
  cleanupExpiredYuidChallenges();
  const normalized = String(nonce || '').trim();
  if (!normalized) return null;
  const challenge = yuidChallenges.get(normalized) || null;
  if (challenge) {
    yuidChallenges.delete(normalized);
  }
  return challenge;
}

function decodeBase64Url(value) {
  const normalized = String(value || '').trim();
  if (!normalized) return null;
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
  return Buffer.from(padded, 'base64url');
}

function buildYuidAuthMessage({ usernameNormalized, nonce }) {
  return Buffer.from(
    `yappa-auth-v1|${serverId}|${usernameNormalized}|${nonce}`,
    'utf8',
  );
}

function buildYuidFromPublicKey(publicKeyBytes) {
  return crypto
    .createHash('sha256')
    .update(publicKeyBytes)
    .digest('base64url')
    .slice(0, 20);
}

function migrateStoredYuids() {
  const rows = db
    .prepare(`
    SELECT id, yuid, yuid_public_key
    FROM users
    WHERE yuid_public_key IS NOT NULL
    AND trim(yuid_public_key) != ''
    ORDER BY id ASC
    `)
    .all();

  if (rows.length === 0) {
    return;
  }

  const update = db.prepare(`
  UPDATE users
  SET yuid = ?
  WHERE id = ?
  `);

  const migrate = db.transaction(() => {
    let changed = 0;

    for (const row of rows) {
      const publicKeyBytes = decodeBase64Url(row.yuid_public_key);
      if (!publicKeyBytes || publicKeyBytes.length !== 32) {
        continue;
      }

      const canonicalYuid = buildYuidFromPublicKey(publicKeyBytes);
      if (row.yuid === canonicalYuid) {
        continue;
      }

      update.run(canonicalYuid, row.id);
      changed += 1;
    }

    return changed;
  });

  const changed = migrate();
  if (changed > 0) {
    console.log(`Migrated ${changed} YUID(s) to the 20-character format.`);
  }
}

function verifyYuidProof({ usernameNormalized, yuidPublicKey, yuidSignature, yuidNonce }) {
  const challenge = consumeYuidChallenge(yuidNonce);
  if (!challenge) {
    return { ok: false, status: 401, code: 'invalid_yuid_challenge', message: 'YUID challenge expired or is invalid.' };
  }

  const publicKeyBytes = decodeBase64Url(yuidPublicKey);
  const signatureBytes = decodeBase64Url(yuidSignature);

  if (!publicKeyBytes || publicKeyBytes.length !== 32) {
    return { ok: false, status: 400, code: 'invalid_yuid_public_key', message: 'Invalid YUID public key.' };
  }
  if (!signatureBytes || signatureBytes.length !== 64) {
    return { ok: false, status: 400, code: 'invalid_yuid_signature', message: 'Invalid YUID signature.' };
  }

  const message = buildYuidAuthMessage({ usernameNormalized, nonce: yuidNonce });
  const verified = nacl.sign.detached.verify(
    new Uint8Array(message),
    new Uint8Array(signatureBytes),
    new Uint8Array(publicKeyBytes),
  );
  if (!verified) {
    return { ok: false, status: 401, code: 'invalid_yuid_signature', message: 'This YUID proof could not be verified.' };
  }

  return {
    ok: true,
    yuid: buildYuidFromPublicKey(publicKeyBytes),
    yuidPublicKey: Buffer.from(publicKeyBytes).toString('base64url'),
  };
}

function verifyMediaDeviceProof({
  usernameNormalized,
  yuidPublicKey,
  yuidNonce,
  mediaDeviceId,
  mediaPublicKey,
  mediaDeviceSignature,
}) {
  if (!/^device_[A-Za-z0-9_-]{24}$/.test(mediaDeviceId)) {
    return {
      ok: false,
      status: 400,
      code: 'invalid_media_device_id',
      message: 'Invalid media device identifier.',
    };
  }
  const yuidPublicKeyBytes = decodeBase64Url(yuidPublicKey);
  const mediaPublicKeyBytes = decodeBase64Url(mediaPublicKey);
  const signatureBytes = decodeBase64Url(mediaDeviceSignature);
  if (!mediaPublicKeyBytes || mediaPublicKeyBytes.length !== 32) {
    return {
      ok: false,
      status: 400,
      code: 'invalid_media_public_key',
      message: 'Invalid media device public key.',
    };
  }
  if (
    !yuidPublicKeyBytes ||
    yuidPublicKeyBytes.length !== 32 ||
    !signatureBytes ||
    signatureBytes.length !== 64
  ) {
    return {
      ok: false,
      status: 400,
      code: 'invalid_media_device_signature',
      message: 'Invalid media device authorization signature.',
    };
  }
  const message = Buffer.from(
    `yappa-media-device-v1|${serverId}|${usernameNormalized}|${yuidNonce}|` +
      `${Buffer.from(mediaPublicKeyBytes).toString('base64url')}|${mediaDeviceId}`,
    'utf8',
  );
  const verified = nacl.sign.detached.verify(
    new Uint8Array(message),
    new Uint8Array(signatureBytes),
    new Uint8Array(yuidPublicKeyBytes),
  );
  if (!verified) {
    return {
      ok: false,
      status: 401,
      code: 'invalid_media_device_signature',
      message: 'This media device authorization could not be verified.',
    };
  }
  return {
    ok: true,
    deviceId: mediaDeviceId,
    publicKey: Buffer.from(mediaPublicKeyBytes).toString('base64url'),
    signature: Buffer.from(signatureBytes).toString('base64url'),
    authorizationNonce: yuidNonce,
    authorizedUsername: usernameNormalized,
  };
}

function verifyMlsCredentialBinding({
  yuid,
  yuidPublicKey,
  deviceId,
  signaturePublicKey,
  identityBindingSignature,
}) {
  if (!/^device_[A-Za-z0-9_-]{24}$/.test(String(deviceId || ''))) {
    return { ok: false, code: 'invalid_mls_device_id' };
  }
  if (
    !/^[A-Za-z0-9_-]{43}$/.test(String(signaturePublicKey || '')) ||
    !/^[A-Za-z0-9_-]{86}$/.test(String(identityBindingSignature || ''))
  ) {
    return { ok: false, code: 'invalid_mls_credential_binding' };
  }
  const yuidPublicKeyBytes = decodeBase64Url(yuidPublicKey);
  const signaturePublicKeyBytes = decodeBase64Url(signaturePublicKey);
  const bindingSignatureBytes = decodeBase64Url(identityBindingSignature);
  if (
    !yuidPublicKeyBytes ||
    yuidPublicKeyBytes.length !== 32 ||
    !signaturePublicKeyBytes ||
    signaturePublicKeyBytes.length !== 32 ||
    !bindingSignatureBytes ||
    bindingSignatureBytes.length !== 64
  ) {
    return { ok: false, code: 'invalid_mls_credential_binding' };
  }
  const canonicalSignaturePublicKey =
    Buffer.from(signaturePublicKeyBytes).toString('base64url');
  const message = Buffer.from(
    `yappa-mls-credential-v1|${serverId}|${yuid}|${deviceId}|` +
      canonicalSignaturePublicKey,
    'utf8',
  );
  if (
    !nacl.sign.detached.verify(
      new Uint8Array(message),
      new Uint8Array(bindingSignatureBytes),
      new Uint8Array(yuidPublicKeyBytes),
    )
  ) {
    return { ok: false, code: 'invalid_mls_credential_binding' };
  }
  return {
    ok: true,
    signaturePublicKey: canonicalSignaturePublicKey,
    identityBindingSignature:
      Buffer.from(bindingSignatureBytes).toString('base64url'),
  };
}

function compactExpiredMlsKeyPackages(now = nowIso()) {
  db.prepare(`
    UPDATE mls_key_packages
    SET key_package = X'',
        claimed_at = COALESCE(claimed_at, expires_at)
    WHERE expires_at <= ?
    AND length(key_package) > 0
  `).run(now);
}

function activeMlsDevice(deviceId) {
  return db.prepare(`
    SELECT media_devices.id, media_devices.user_id, users.username,
           users.yuid, users.yuid_public_key
    FROM media_devices
    JOIN users ON users.id = media_devices.user_id
    WHERE media_devices.id = ?
    AND media_devices.revoked_at IS NULL
    AND NOT EXISTS (
      SELECT 1 FROM bans
      WHERE bans.revoked_at IS NULL
      AND (
        bans.user_id = users.id
        OR (bans.yuid IS NOT NULL AND bans.yuid = users.yuid)
      )
    )
  `).get(deviceId);
}

function serializeMlsDeliveryMessage(row) {
  const encryptedAttachmentIds =
    row.event_id == null
      ? []
      : db
          .prepare(`
            SELECT id
            FROM encrypted_attachments
            WHERE event_id = ?
            AND deleted_at IS NULL
            ORDER BY id ASC
          `)
          .all(row.event_id)
          .map((attachment) => attachment.id);
  return {
    id: row.id,
    clientOperationId: row.client_operation_id,
    channelId: toId(row.channel_id),
    serverSequence: Number(row.server_sequence),
    messageClass: row.message_class,
    acceptedEpoch: Number(row.accepted_epoch),
    parentEpoch:
      row.parent_epoch == null ? null : Number(row.parent_epoch),
    uploaderUserId: toId(row.uploader_user_id),
    uploaderDeviceId: row.uploader_device_id,
    recipientDeviceId: row.recipient_device_id || null,
    wireMessage: Buffer.from(row.wire_message).toString('base64url'),
    createdAt: row.created_at,
    event:
      row.event_id == null
        ? null
        : {
            eventId: row.event_id,
            kind: row.event_kind,
            targetEventId: row.target_event_id || null,
            encryptedAttachmentIds,
          },
  };
}

function registerMediaDevice(userId, proof) {
  const existing = db
    .prepare('SELECT * FROM media_devices WHERE id = ?')
    .get(proof.deviceId);
  if (existing) {
    if (Number(existing.user_id) !== Number(userId)) {
      return {
        ok: false,
        status: 409,
        code: 'media_device_already_bound',
        message: 'This media device is already bound to another account.',
      };
    }
    if (existing.public_key !== proof.publicKey) {
      return {
        ok: false,
        status: 409,
        code: 'media_device_key_changed',
        message: 'This media device identifier has a different public key.',
      };
    }
    if (existing.revoked_at) {
      return {
        ok: false,
        status: 403,
        code: 'media_device_revoked',
        message: 'This media device identity has been revoked.',
      };
    }
    db.prepare(`
      UPDATE media_devices
      SET yuid_authorization_signature = ?,
          authorization_nonce = ?,
          authorized_username = ?,
          last_seen_at = ?
      WHERE id = ?
    `).run(
      proof.signature,
      proof.authorizationNonce,
      proof.authorizedUsername,
      nowIso(),
      proof.deviceId,
    );
    return { ok: true, device: db.prepare('SELECT * FROM media_devices WHERE id = ?').get(proof.deviceId) };
  }

  const conflictingKey = db
    .prepare('SELECT id FROM media_devices WHERE public_key = ?')
    .get(proof.publicKey);
  if (conflictingKey) {
    return {
      ok: false,
      status: 409,
      code: 'media_device_key_already_bound',
      message: 'This media public key is already registered.',
    };
  }
  const createdAt = nowIso();
  db.prepare(`
    INSERT INTO media_devices (
      id, user_id, public_key, yuid_authorization_signature,
      authorization_nonce, authorized_username, created_at, last_seen_at,
      revoked_at
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
  `).run(
    proof.deviceId,
    userId,
    proof.publicKey,
    proof.signature,
    proof.authorizationNonce,
    proof.authorizedUsername,
    createdAt,
    createdAt,
  );
  return { ok: true, device: db.prepare('SELECT * FROM media_devices WHERE id = ?').get(proof.deviceId) };
}

function serializeMediaDevice(row) {
  if (!row) return null;
  return {
    id: row.id,
    userId: toId(row.user_id),
    publicKey: row.public_key,
    yuidAuthorizationSignature: row.yuid_authorization_signature,
    authorizationNonce: row.authorization_nonce,
    authorizedUsername: row.authorized_username,
    createdAt: row.created_at,
    lastSeenAt: row.last_seen_at,
    revokedAt: row.revoked_at || null,
  };
}

migrateStoredYuids();

function serializeChannel(row, currentServerId) {
  return {
    id: toId(row.id),
    serverId: currentServerId,
    name: row.name,
    type: row.type,
    position: row.position,
    glyph: row.glyph || null,
    createdAt: row.created_at,
    encryptionMode: row.encryption_mode || 'legacy',
    encryptionVersion: Number(row.encryption_version || 0),
  };
}

function normalizeChannelGlyph(value) {
  if (value === undefined) {
    return { ok: true, present: false, value: undefined };
  }

  if (value === null) {
    return { ok: true, present: true, value: null };
  }

  const normalized = String(value).trim();
  if (!normalized) {
    return { ok: true, present: true, value: null };
  }

  if (normalized.length > 64) {
    return {
      ok: false,
      status: 400,
      code: 'invalid_channel_glyph',
      message: 'Channel icon or emoji must be 64 characters or fewer.',
    };
  }

  if (normalized.startsWith('icon:')) {
    const iconKey = normalized.slice(5);
    if (!iconKey || !/^[a-z0-9_]+$/i.test(iconKey)) {
      return {
        ok: false,
        status: 400,
        code: 'invalid_channel_glyph',
        message: 'Channel icon keys must use letters, numbers, or underscores.',
      };
    }

    return { ok: true, present: true, value: normalized };
  }

  if (normalized.startsWith('emoji:')) {
    const emojiValue = normalized.slice(6).trim();
    if (!emojiValue) {
      return {
        ok: false,
        status: 400,
        code: 'invalid_channel_glyph',
        message: 'Channel emoji selections cannot be empty.',
      };
    }

    return { ok: true, present: true, value: `emoji:${emojiValue}` };
  }

  return {
    ok: false,
    status: 400,
    code: 'invalid_channel_glyph',
    message: 'Channel icon or emoji must start with icon: or emoji:.',
  };
}

function sanitizeVoiceMediaState(value = {}) {
  return {
    micMuted: Boolean(value.micMuted),
    audioMuted: Boolean(value.audioMuted),
    cameraEnabled: Boolean(value.cameraEnabled),
    screenShareEnabled: Boolean(value.screenShareEnabled),
    speaking: Boolean(value.speaking),
  };
}

function mergeVoiceMediaState(current = {}, patch = {}) {
  const next = { ...sanitizeVoiceMediaState(current) };
  for (const key of [
    'micMuted',
    'audioMuted',
    'cameraEnabled',
    'screenShareEnabled',
    'speaking',
  ]) {
    if (typeof patch[key] === 'boolean') {
      next[key] = patch[key];
    }
  }
  return next;
}

function voiceMediaStateChanged(current = {}, next = {}) {
  return (
    Boolean(current.micMuted) !== Boolean(next.micMuted) ||
    Boolean(current.audioMuted) !== Boolean(next.audioMuted) ||
    Boolean(current.cameraEnabled) !== Boolean(next.cameraEnabled) ||
    Boolean(current.screenShareEnabled) !== Boolean(next.screenShareEnabled) ||
    Boolean(current.speaking) !== Boolean(next.speaking)
  );
}

function serializeUser(
  row,
  {
    isOnline = false,
    status,
    voiceChannelId = null,
    voiceJoinedAt = null,
    voiceState = {},
  } = {},
) {
  const resolvedStatus =
  status ||
  (voiceChannelId ? 'voice_connected' : isOnline ? 'online' : 'offline');
  const resolvedVoiceState = sanitizeVoiceMediaState(voiceState);

  return {
    id: toId(row.id ?? row.user_id),
    username: row.username,
    name: row.display_name || row.username,
    avatarUrl: row.avatar_url || null,
    role: row.role,
    yuid: row.yuid || null,
    yuidVerified: Boolean(row.yuidVerified || (row.yuid && row.yuid_public_key)),
    isOnline,
    status: resolvedStatus,
    voiceChannelId: voiceChannelId ? toId(voiceChannelId) : null,
    voiceJoinedAt: voiceJoinedAt || null,
    voiceState: resolvedVoiceState,
    createdAt: row.created_at || null,
    lastLoginAt: row.last_login_at || null,
  };
}

function attachmentUrlFromRelativePath(relativePath) {
  return `/uploads/${relativePath.replaceAll(path.sep, '/')}`;
}

function isLocalBrandingPath(value) {
  const normalized = String(value || '').trim();
  if (!normalized.startsWith('/uploads/')) {
    return false;
  }
  return normalized.includes(`/${serverId}/branding/`);
}

function absolutePathFromUploadUrl(value) {
  const normalized = String(value || '').trim();
  if (!normalized.startsWith('/uploads/')) {
    return null;
  }
  const relativePath = normalized
  .replace(/^\/uploads\//, '')
  .replaceAll('/', path.sep);
  return path.join(DATA_ROOT, relativePath);
}

function cleanupPreviousBrandingAsset(previousUrl) {
  if (!isLocalBrandingPath(previousUrl)) {
    return;
  }

  const absolutePath = absolutePathFromUploadUrl(previousUrl);
  if (!absolutePath) {
    return;
  }

  try {
    if (fs.existsSync(absolutePath)) {
      fs.unlinkSync(absolutePath);
    }
  } catch (error) {
    logOperationalFailure('branding cleanup', error);
  }
}

function persistBrandingAsset(slot, uploadedFile) {
  const current = getServerConfig(db);
  const currentBranding = safeJsonParse(current.branding_json, {});
  const relativePath = path.relative(DATA_ROOT, uploadedFile.path);
  const assetUrl = attachmentUrlFromRelativePath(relativePath);

  const nextBranding = {
    ...currentBranding,
    ...(slot === 'icon' ? { iconUrl: assetUrl } : { bannerUrl: assetUrl }),
  };

  db.prepare(`
  UPDATE server_config
  SET branding_json = ?, updated_at = ?
  WHERE id = 1
  `).run(JSON.stringify(nextBranding), nowIso());

  if (slot === 'icon') {
    cleanupPreviousBrandingAsset(currentBranding.iconUrl);
  } else {
    cleanupPreviousBrandingAsset(currentBranding.bannerUrl);
  }

  return {
    server: currentServer(),
    assetUrl,
  };
}

function attachmentGrantSignature({ attachmentId, userId, expires }) {
  return crypto
    .createHmac('sha256', ATTACHMENT_SIGNING_SECRET)
    .update(`${attachmentId}.${userId}.${expires}`, 'utf8')
    .digest('base64url');
}

const HISTORY_CURSOR_VERSION = 1;

function historyCursorSignature(encodedPayload) {
  return crypto
    .createHmac('sha256', ATTACHMENT_SIGNING_SECRET)
    .update(`yappa-history-cursor-v1.${encodedPayload}`, 'utf8')
    .digest('base64url');
}

function encodeHistoryCursor({
  channelId,
  messageId,
  userId,
  direction,
}) {
  if (direction !== 'before' && direction !== 'after') {
    throw new TypeError('Invalid history cursor direction.');
  }
  const encodedPayload = Buffer.from(
    JSON.stringify({
      v: HISTORY_CURSOR_VERSION,
      s: serverId,
      c: toId(channelId),
      m: toId(messageId),
      u: toId(userId),
      d: direction,
    }),
    'utf8',
  ).toString('base64url');
  return `${encodedPayload}.${historyCursorSignature(encodedPayload)}`;
}

function decodeHistoryCursor(cursor, { channelId, userId }) {
  if (
    typeof cursor !== 'string' ||
    cursor.length < 32 ||
    cursor.length > 1024 ||
    !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(cursor)
  ) {
    return null;
  }

  const [encodedPayload, providedSignature] = cursor.split('.');
  const expectedSignature = historyCursorSignature(encodedPayload);
  const providedBytes = Buffer.from(providedSignature, 'utf8');
  const expectedBytes = Buffer.from(expectedSignature, 'utf8');
  if (
    providedBytes.length !== expectedBytes.length ||
    !crypto.timingSafeEqual(providedBytes, expectedBytes)
  ) {
    return null;
  }

  let payload;
  try {
    payload = JSON.parse(Buffer.from(encodedPayload, 'base64url').toString('utf8'));
  } catch (_) {
    return null;
  }

  const messageId = Number(payload?.m);
  if (
    payload?.v !== HISTORY_CURSOR_VERSION ||
    payload?.s !== serverId ||
    payload?.c !== toId(channelId) ||
    payload?.u !== toId(userId) ||
    (payload?.d !== 'before' && payload?.d !== 'after') ||
    !Number.isSafeInteger(messageId) ||
    messageId <= 0 ||
    payload.m !== toId(messageId)
  ) {
    return null;
  }
  return {
    messageId,
    direction: payload.d,
  };
}

function signedAttachmentUrl(row, viewerUserId) {
  const attachmentId = toId(row.id);
  const userId = toId(viewerUserId);
  const expires = Math.floor(Date.now() / 1000) + ATTACHMENT_URL_TTL_SECONDS;
  const signature = attachmentGrantSignature({
    attachmentId,
    userId,
    expires,
  });
  const query = new URLSearchParams({
    user: userId,
    expires: String(expires),
    signature,
  });
  return `/api/attachments/${attachmentId}/content?${query.toString()}`;
}

function serializeAttachment(row, viewerUserId) {
  return {
    id: toId(row.id),
    serverId: row.server_id,
    channelId: toId(row.channel_id),
    messageId: row.message_id ? toId(row.message_id) : null,
    kind: row.kind,
    name: row.original_name,
    originalName: row.original_name,
    storedName: row.stored_name,
    mimeType: row.mime_type,
    sizeBytes: Number(row.size_bytes),
    url: signedAttachmentUrl(row, viewerUserId),
    createdAt: row.created_at,
    expiresAt: row.expires_at,
    deletedAt: row.deleted_at,
  };
}

function serializeMessage(row, attachments = [], viewerUserId) {
  return {
    id: toId(row.id),
    channelId: toId(row.channel_id),
    content: row.content,
    createdAt: row.created_at,
    updatedAt: row.updated_at || null,
    author: {
      id: toId(row.user_id),
      username: row.username,
      name: row.username,
      role: row.role,
    yuid: row.yuid || null,
    yuidVerified: Boolean(row.yuidVerified || (row.yuid && row.yuid_public_key)),
    },
    attachments: attachments.map((attachment) =>
      serializeAttachment(attachment, viewerUserId),
    ),
  };
}

function getMessageRowById(messageId) {
  return db.prepare(`
  SELECT
  messages.id,
  messages.channel_id,
  messages.user_id,
  messages.content,
  messages.created_at,
  messages.updated_at,
  users.username,
  users.role,
  users.yuid,
  users.yuid_public_key
  FROM messages
  JOIN users ON users.id = messages.user_id
  WHERE messages.id = ?
  `).get(messageId);
}

function buildSerializedMessage(messageId, viewerUserId) {
  const row = getMessageRowById(messageId);
  if (!row) {
    return null;
  }

  const attachmentsMap = getAttachmentsForMessageIds(db, [messageId]);
  return serializeMessage(
    row,
    attachmentsMap.get(Number(messageId)) || [],
    viewerUserId,
  );
}

function removeAttachmentFile(relativePath) {
  if (!relativePath) {
    return;
  }

  const absolutePath = path.join(DATA_ROOT, relativePath);
  try {
    if (fs.existsSync(absolutePath)) {
      fs.unlinkSync(absolutePath);
    }
  } catch (error) {
    logOperationalFailure('attachment cleanup', error);
  }
}

function currentServer() {
  return serializeServerConfig(getServerConfig(db));
}

function currentChannels() {
  const server = currentServer();
  return getAllChannels(db).map((row) => serializeChannel(row, server.id));
}

function currentSettings() {
  return serializeServerSettings(getServerSettings(db));
}

function getActiveBanForIdentity({ userId = null, yuid = null }) {
  const byUserId = Number.isInteger(Number(userId))
    ? getActiveBanByUserId(db, Number(userId))
    : null;
  if (byUserId) {
    return byUserId;
  }

  const normalizedYuid = String(yuid || '').trim();
  if (normalizedYuid) {
    return getActiveBanByYuid(db, normalizedYuid);
  }

  return null;
}

function serializeBan(row) {
  return {
    id: toId(row.id),
    userId: row.user_id ? toId(row.user_id) : null,
    yuid: row.yuid || null,
    username: row.target_username || row.username_snapshot || null,
    displayName: row.target_display_name || null,
    usernameSnapshot: row.username_snapshot || null,
    reason: row.reason || null,
    createdByUserId: row.created_by_user_id ? toId(row.created_by_user_id) : null,
    createdAt: row.created_at,
    revokedAt: row.revoked_at || null,
  };
}

function currentBans() {
  return getAllActiveBans(db).map(serializeBan);
}

function clearSessionsForUser(userId) {
  db.prepare('DELETE FROM sessions WHERE user_id = ?').run(Number(userId));
}

function disconnectUserSockets(userId) {
  const normalizedUserId = Number(userId);
  for (const [socketId, presence] of socketPresence.entries()) {
    if (Number(presence.userId) !== normalizedUserId) {
      continue;
    }

    const liveSocket = io.sockets.sockets.get(socketId);
    if (liveSocket) {
      liveSocket.disconnect(true);
    }
    socketPresence.delete(socketId);
  }

  onlineUsersById.delete(toId(normalizedUserId));
}

function getSocketsForUser(userId) {
  const matches = [];
  for (const value of socketPresence.values()) {
    if (Number(value.userId) === Number(userId)) {
      matches.push(value);
    }
  }
  return matches;
}

function getVoicePresenceForUser(userId) {
  const matches = getSocketsForUser(userId).filter(
    (value) => Number.isInteger(value.voiceChannelId),
  );

  if (matches.length === 0) {
    return null;
  }

  matches.sort((a, b) => {
    const left = String(a.voiceJoinedAt || '');
    const right = String(b.voiceJoinedAt || '');
    return left.localeCompare(right);
  });

  return matches[0];
}

function getVoiceMediaStateForUser(userId) {
  const matches = getSocketsForUser(userId);

  if (matches.length === 0) {
    return sanitizeVoiceMediaState();
  }

  const connectedPresence = matches.find((value) =>
  Number.isInteger(value.voiceChannelId),
  );

  return sanitizeVoiceMediaState(
    connectedPresence?.voiceState || matches[0]?.voiceState || {},
  );
}

function getOnlineUserIds() {
  const ids = new Set();
  for (const value of socketPresence.values()) {
    ids.add(Number(value.userId));
  }
  return ids;
}

function getVoiceDeckActivity() {
  const activity = new Map();

  for (const value of socketPresence.values()) {
    if (!Number.isInteger(value.voiceChannelId) || !value.voiceJoinedAt) {
      continue;
    }

    const channelId = Number(value.voiceChannelId);
    const current = activity.get(channelId);
    if (!current) {
      activity.set(channelId, {
        count: 1,
        activeSince: value.voiceJoinedAt,
      });
      continue;
    }

    current.count += 1;
    if (
      String(value.voiceJoinedAt).localeCompare(String(current.activeSince)) < 0
    ) {
      current.activeSince = value.voiceJoinedAt;
    }
  }

  return activity;
}

function getVoiceState() {
  const voiceChannels = getAllChannels(db).filter((row) => row.type === 'voice');
  const activity = getVoiceDeckActivity();

  return voiceChannels.map((row) => {
    const current = activity.get(Number(row.id));
    return {
      channelId: toId(row.id),
                           channelName: row.name,
                           occupancy: current?.count || 0,
                           activeSince: current?.activeSince || null,
    };
  });
}

function getMemberList() {
  const activeBans = getAllActiveBans(db);
  const bannedUserIds = new Set(
    activeBans
      .map((row) => Number(row.user_id))
      .filter((value) => Number.isInteger(value)),
  );
  const bannedYuids = new Set(
    activeBans
      .map((row) => String(row.yuid || '').trim())
      .filter(Boolean),
  );

  const rows = db
  .prepare(`
  SELECT id, username, role, display_name, avatar_url, created_at, last_login_at, yuid, yuid_public_key
  FROM users
  ORDER BY lower(COALESCE(display_name, username)) ASC, lower(username) ASC
  `)
  .all()
  .filter((row) => {
    if (bannedUserIds.has(Number(row.id))) {
      return false;
    }
    const userYuid = String(row.yuid || '').trim();
    return !userYuid || !bannedYuids.has(userYuid);
  });

  return rows.map((row) => {
    const onlineSockets = getSocketsForUser(row.id);
    const voicePresence = getVoicePresenceForUser(row.id);
    const isOnline = onlineSockets.length > 0;
    const voiceState = getVoiceMediaStateForUser(row.id);

    return serializeUser(row, {
      isOnline,
      status: voicePresence
      ? 'voice_connected'
      : isOnline
      ? 'online'
      : 'offline',
      voiceChannelId: voicePresence?.voiceChannelId || null,
      voiceJoinedAt: voicePresence?.voiceJoinedAt || null,
      voiceState,
    });
  });
}

function emitPresence() {
  io.emit('presence:update', {
    members: getMemberList(),
          voice: getVoiceState(),
  });
}

function emitServerUpdated() {
  io.emit('server:update', {
    server: currentServer(),
          channels: currentChannels(),
          settings: currentSettings(),
          voice: getVoiceState(),
  });
}

function ownerOnly(req, res, next) {
  if (!isOwner(req.auth?.user)) {
    return apiError(
      res,
      403,
      'owner_required',
      'Only the server owner can do that.',
    );
  }
  next();
}

function classifyAttachmentKind(mimeType) {
  if (mimeType.startsWith('image/')) return 'image';
  if (mimeType.startsWith('video/')) return 'video';
  if (mimeType.startsWith('audio/')) return 'audio';
  return 'file';
}

function normalizeAllowedTypes(input, fallback) {
  if (!Array.isArray(input)) return fallback;
  const values = input
  .map((value) => String(value || '').trim())
  .filter(Boolean)
  .slice(0, 64);
  return values.length > 0 ? values : fallback;
}

function isAllowedMimeType(mimeType, allowedPatterns) {
  if (allowedPatterns.includes('*')) return true;
  return allowedPatterns.some((pattern) => {
    if (pattern.endsWith('/')) {
      return mimeType.startsWith(pattern);
    }
    return mimeType === pattern;
  });
}

function computeExpiresAt(retentionDays) {
  const days = Number(retentionDays);
  if (!Number.isFinite(days) || days <= 0) {
    return null;
  }
  return new Date(
    Date.now() + days * 24 * 60 * 60 * 1000,
  ).toISOString();
}

async function sha256File(filePath) {
  const digest = crypto.createHash('sha256');
  const stream = fs.createReadStream(filePath);
  for await (const chunk of stream) {
    digest.update(chunk);
  }
  return digest.digest('hex');
}

function rejectPlaintextForEncryptedChannel(res, channel) {
  if (
    String(channel?.encryption_mode || 'legacy') === 'legacy' &&
    Number(channel?.encryption_version || 0) === 0
  ) {
    return false;
  }
  apiError(
    res,
    409,
    'encrypted_channel_requires_e2ee',
    'This channel requires end-to-end encrypted messaging. Plaintext was rejected.',
  );
  return true;
}

function inferMimeType(uploadedFile) {
  const originalName = uploadedFile.originalname || '';
  const byExtension = mime.lookup(originalName);
  const rawMime = String(uploadedFile.mimetype || '').trim();

  if (rawMime && rawMime !== 'application/octet-stream') {
    return rawMime;
  }

  if (byExtension) {
    return String(byExtension);
  }

  return 'application/octet-stream';
}

const storage = multer.diskStorage({
  destination(req, _file, cb) {
    const channelId = Number(req.body?.channelId);
    const destination = path.join(
      attachmentsRoot,
      Number.isInteger(channelId) ? String(channelId) : 'misc',
    );
    ensureDir(destination);
    cb(null, destination);
  },
  filename(_req, file, cb) {
    const ext = path.extname(file.originalname || '').slice(0, 16);
    cb(null, `${Date.now()}_${randomId('att')}${ext}`);
  },
});

function uploadSingleAttachment(req, res, next) {
  const maxBytes = Math.max(
    1,
    Number(getServerSettings(db).attachment_max_bytes),
  );
  return multer({
    storage,
    limits: {
      fileSize: maxBytes,
      files: 1,
      fields: 4,
      fieldSize: 16 * 1024,
    },
  }).single('file')(req, res, next);
}

const encryptedAttachmentStorage = multer.diskStorage({
  destination(_req, _file, cb) {
    cb(null, encryptedAttachmentsRoot);
  },
  filename(_req, _file, cb) {
    cb(null, `${Date.now()}_${randomId('eatt')}.bin`);
  },
});

function uploadSingleEncryptedAttachment(req, res, next) {
  const maxBytes =
    Math.max(1, Number(getServerSettings(db).attachment_max_bytes)) +
    1024 * 1024;
  return multer({
    storage: encryptedAttachmentStorage,
    limits: {
      fileSize: maxBytes,
      files: 1,
      fields: 8,
      fieldSize: 16 * 1024,
    },
  }).single('ciphertext')(req, res, next);
}

const brandingStorage = multer.diskStorage({
  destination(req, _file, cb) {
    const slot = req.params?.slot === 'banner' ? 'banner' : 'icon';
    cb(null, slot === 'banner' ? brandingBannerRoot : brandingIconRoot);
  },
  filename(req, file, cb) {
    const slot = req.params?.slot === 'banner' ? 'banner' : 'icon';
    const ext = path.extname(file.originalname || '').slice(0, 16);
    cb(null, `${slot}_${Date.now()}_${randomId('brand')}${ext}`);
  },
});

const brandingUpload = multer({
  storage: brandingStorage,
  limits: { fileSize: 10 * 1024 * 1024 },
});

app.get(
  '/api/attachments/:attachmentId/content',
  attachmentDownloadRateLimit,
  (req, res) => {
  const attachmentId = Number(req.params.attachmentId);
  const userId = Number(req.query.user);
  const expires = Number(req.query.expires);
  const providedSignature = String(req.query.signature || '');

  if (
    !Number.isInteger(attachmentId) ||
    !Number.isInteger(userId) ||
    !Number.isInteger(expires) ||
    !/^[A-Za-z0-9_-]{43}$/.test(providedSignature)
  ) {
    return apiError(
      res,
      403,
      'invalid_attachment_grant',
      'This attachment link is invalid.',
    );
  }

  if (expires < Math.floor(Date.now() / 1000)) {
    return apiError(
      res,
      403,
      'attachment_grant_expired',
      'This attachment link has expired.',
    );
  }

  const expectedSignature = attachmentGrantSignature({
    attachmentId: toId(attachmentId),
    userId: toId(userId),
    expires,
  });
  const providedBytes = Buffer.from(providedSignature, 'utf8');
  const expectedBytes = Buffer.from(expectedSignature, 'utf8');
  if (
    providedBytes.length !== expectedBytes.length ||
    !crypto.timingSafeEqual(providedBytes, expectedBytes)
  ) {
    return apiError(
      res,
      403,
      'invalid_attachment_grant',
      'This attachment link is invalid.',
    );
  }

  const user = db
    .prepare('SELECT id, yuid FROM users WHERE id = ?')
    .get(userId);
  if (
    !user ||
    getActiveBanForIdentity({ userId: user.id, yuid: user.yuid || null })
  ) {
    return apiError(
      res,
      403,
      'attachment_access_denied',
      'This attachment is not available to that account.',
    );
  }

  const attachment = db
    .prepare(`
    SELECT *
    FROM attachments
    WHERE id = ?
    AND deleted_at IS NULL
    `)
    .get(attachmentId);
  if (!attachment) {
    return apiError(
      res,
      404,
      'attachment_not_found',
      'Attachment not found.',
    );
  }

  const channel = db
    .prepare('SELECT id FROM channels WHERE id = ?')
    .get(attachment.channel_id);
  if (!channel) {
    return apiError(
      res,
      403,
      'attachment_access_denied',
      'The attachment channel is no longer available.',
    );
  }

  const absolutePath = path.resolve(DATA_ROOT, attachment.relative_path);
  const resolvedAttachmentsRoot = path.resolve(attachmentsRoot);
  if (
    absolutePath !== resolvedAttachmentsRoot &&
    !absolutePath.startsWith(`${resolvedAttachmentsRoot}${path.sep}`)
  ) {
    return apiError(
      res,
      403,
      'attachment_path_invalid',
      'The attachment path is invalid.',
    );
  }

  res.setHeader('Content-Type', attachment.mime_type);
  res.setHeader(
    'Content-Disposition',
    `inline; filename*=UTF-8''${encodeURIComponent(attachment.original_name)}`,
  );
  res.setHeader(
    'Cache-Control',
    `private, max-age=${Math.max(
      0,
      Math.min(
        ATTACHMENT_URL_TTL_SECONDS,
        expires - Math.floor(Date.now() / 1000),
      ),
    )}`,
  );
  return res.sendFile(absolutePath);
  },
);

app.get('/health', (_req, res) => {
  res.json({
    ok: true,
    time: nowIso(),
  });
});

app.get('/api/server/identity', challengeRateLimit, (req, res) => {
  const nonce = String(req.query?.nonce || '').trim();
  if (!/^[A-Za-z0-9_-]{22,128}$/.test(nonce)) {
    return apiError(
      res,
      400,
      'invalid_identity_nonce',
      'A valid identity challenge nonce is required.',
    );
  }
  const proof = `yappa-server-proof-v1|${serverId}|${nonce}`;
  const signature = crypto
    .sign(null, Buffer.from(proof, 'utf8'), serverIdentity.privateKey)
    .toString('base64url');
  return res.json({
    ok: true,
    identity: {
      serverId,
      algorithm: serverIdentity.algorithm,
      publicKey: serverIdentity.publicKey,
      nonce,
      signature,
    },
  });
});


app.get(
  '/api/link-preview',
  authRequired,
  expensiveOperationRateLimit,
  async (req, res) => {
  const channelId = Number(req.query?.channelId);
  if (!Number.isInteger(channelId)) {
    return apiError(
      res,
      400,
      'invalid_channel_id',
      'A valid text channel is required for link previews.',
    );
  }
  const channel = db.prepare(`
    SELECT id, type, encryption_mode, encryption_version
    FROM channels
    WHERE id = ?
  `).get(channelId);
  if (!channel || channel.type !== 'text') {
    return apiError(
      res,
      404,
      'text_channel_not_found',
      'That text channel does not exist.',
    );
  }
  if (rejectPlaintextForEncryptedChannel(res, channel)) {
    return;
  }
  const url = normalizePreviewUrl(req.query?.url);
  if (!url) {
    return apiError(res, 400, 'invalid_url', 'A valid http or https URL is required.');
  }

  try {
    const preview = await loadLinkPreview(url);
    return res.json({ ok: true, preview });
  } catch (error) {
    logOperationalFailure('link preview', error);
    try {
      const fallback = await loadSafeLinkPreviewFallback(url);
      return res.json({ ok: true, preview: fallback });
    } catch {
      // Private, malformed, or unresolvable targets remain fail-closed.
    }
    return apiError(
      res,
      502,
      'link_preview_failed',
      'Could not load link preview.',
    );
  }
  },
);

app.post(
  '/api/voice/token',
  authRequired,
  expensiveOperationRateLimit,
  async (req, res) => {
  if (!ensureLiveKitConfigured()) {
    return apiError(
      res,
      503,
      'voice_transport_unavailable',
      'Voice transport is not configured on this Yappa node.',
    );
  }
  if (
    !req.auth.session.mediaDeviceId ||
    !req.auth.session.mediaPublicKey
  ) {
    return apiError(
      res,
      409,
      'media_device_required',
      'This session must register its media device before joining voice.',
    );
  }

  const channelId = Number(req.body?.channelId);
  if (!Number.isInteger(channelId)) {
    return apiError(res, 400, 'invalid_channel_id', 'Invalid voice channel id.');
  }

  const channel = db
    .prepare('SELECT id, name, type FROM channels WHERE id = ?')
    .get(channelId);

  if (!channel || channel.type !== 'voice') {
    return apiError(
      res,
      404,
      'voice_channel_not_found',
      'That voice deck does not exist.',
    );
  }

  const roomName = buildVoiceRoomName(channelId);
  const token = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
    identity: req.auth.session.mediaDeviceId,
    name: req.auth.user.username,
    ttl: LIVEKIT_TOKEN_TTL,
    metadata: JSON.stringify({
      userId: toId(req.auth.user.id),
      deviceId: req.auth.session.mediaDeviceId,
      username: req.auth.user.username,
      role: req.auth.user.role,
      serverId,
      channelId: toId(channelId),
    }),
  });

  token.addGrant({
    roomJoin: true,
    room: roomName,
    canPublish: true,
    canSubscribe: true,
    canPublishData: true,
  });

  try {
    const jwt = await token.toJwt();
    res.json({
      ok: true,
      url: resolveLiveKitWebSocketUrl(req),
      token: jwt,
      roomName,
      channelId: toId(channelId),
      channelName: channel.name,
    });
  } catch (error) {
    logOperationalFailure('voice token creation', error);
    return apiError(
      res,
      500,
      'voice_token_failed',
      'Could not create voice token.',
    );
  }
  },
);

app.get('/api/server', (_req, res) => {
  res.json({
    ok: true,
    server: currentServer(),
  });
});

app.get('/api/server/settings', authRequired, (req, res) => {
  if (!isOwner(req.auth.user)) {
    return apiError(
      res,
      403,
      'owner_required',
      'Only the server owner can do that.',
    );
  }
  res.json({ ok: true, settings: currentSettings() });
});

app.get('/api/server/storage', authRequired, ownerOnly, (_req, res) => {
  const storage = currentStorageCapacity({ includeBackupSize: true });
  if (!storage.available) {
    return apiError(
      res,
      503,
      'storage_status_unavailable',
      'Storage capacity could not be inspected safely.',
      { retryable: true },
    );
  }
  return res.json({ ok: true, storage });
});

app.patch(
  '/api/server/settings',
  authRequired,
  ownerOnly,
  accountMutationRateLimit,
  (req, res) => {
  const current = getServerSettings(db);

  const attachmentRetentionDays = req.body?.attachmentRetentionDays;
  const attachmentMaxBytes = req.body?.attachmentMaxBytes;
  const fileStorageEnabled = req.body?.fileStorageEnabled;
  const fileStorageMaxTotalBytes = req.body?.fileStorageMaxTotalBytes;
  const fileStorageMaxFileBytes = req.body?.fileStorageMaxFileBytes;
  const inlineMediaPreviewsEnabled = req.body?.inlineMediaPreviewsEnabled;
  const attachmentAllowedTypes = req.body?.attachmentAllowedTypes;
  const fileStorageAllowedTypes = req.body?.fileStorageAllowedTypes;

  const patch = {
    attachment_retention_days: current.attachment_retention_days,
    attachment_max_bytes: current.attachment_max_bytes,
    attachment_allowed_types_json: current.attachment_allowed_types_json,
    file_storage_enabled: current.file_storage_enabled,
    file_storage_max_total_bytes: current.file_storage_max_total_bytes,
    file_storage_max_file_bytes: current.file_storage_max_file_bytes,
    file_storage_allowed_types_json: current.file_storage_allowed_types_json,
    inline_media_previews_enabled: current.inline_media_previews_enabled,
  };

  if (attachmentRetentionDays !== undefined) {
    const value = Number(attachmentRetentionDays);
    if (!Number.isInteger(value) || value !== 0) {
      return apiError(
        res,
        400,
        'invalid_attachment_retention_days',
        'Public-release chat attachments must use indefinite retention (0).',
      );
    }
    patch.attachment_retention_days = value;
  }

  if (attachmentMaxBytes !== undefined) {
    const value = Number(attachmentMaxBytes);
    if (
      !Number.isInteger(value) ||
      value < 1024 ||
      value > 1024 * 1024 * 1024
    ) {
      return apiError(
        res,
        400,
        'invalid_attachment_max_bytes',
        'attachmentMaxBytes must be between 1024 and 1073741824.',
      );
    }
    patch.attachment_max_bytes = value;
  }

  if (fileStorageEnabled !== undefined) {
    patch.file_storage_enabled = fileStorageEnabled ? 1 : 0;
  }

  if (fileStorageMaxTotalBytes !== undefined) {
    const value = Number(fileStorageMaxTotalBytes);
    if (
      !Number.isInteger(value) ||
      value < 1024 * 1024 ||
      value > 1024 * 1024 * 1024 * 1024
    ) {
      return apiError(
        res,
        400,
        'invalid_file_storage_max_total_bytes',
        'fileStorageMaxTotalBytes is out of range.',
      );
    }
    patch.file_storage_max_total_bytes = value;
  }

  if (fileStorageMaxFileBytes !== undefined) {
    const value = Number(fileStorageMaxFileBytes);
    if (
      !Number.isInteger(value) ||
      value < 1024 ||
      value > 1024 * 1024 * 1024
    ) {
      return apiError(
        res,
        400,
        'invalid_file_storage_max_file_bytes',
        'fileStorageMaxFileBytes is out of range.',
      );
    }
    patch.file_storage_max_file_bytes = value;
  }

  if (inlineMediaPreviewsEnabled !== undefined) {
    patch.inline_media_previews_enabled = inlineMediaPreviewsEnabled ? 1 : 0;
  }

  if (attachmentAllowedTypes !== undefined) {
    patch.attachment_allowed_types_json = JSON.stringify(
      normalizeAllowedTypes(
        attachmentAllowedTypes,
        safeJsonParse(current.attachment_allowed_types_json, []),
      ),
    );
  }

  if (fileStorageAllowedTypes !== undefined) {
    patch.file_storage_allowed_types_json = JSON.stringify(
      normalizeAllowedTypes(
        fileStorageAllowedTypes,
        safeJsonParse(current.file_storage_allowed_types_json, ['*']),
      ),
    );
  }

  const updated = updateServerSettings(db, patch);
  emitServerUpdated();
  res.json({ ok: true, settings: serializeServerSettings(updated) });
  },
);

app.get('/api/auth/yuid/challenge', challengeRateLimit, (_req, res) => {
  res.json({
    ok: true,
    challenge: issueYuidChallenge(),
  });
});

app.post('/api/auth/session', authRateLimit, async (req, res) => {
  const username = String(req.body?.username || '').trim();
  const password = String(req.body?.password || '');
  const usernameNormalized = username.toLowerCase();
  const yuidClaim = String(req.body?.yuid || '').trim();
  const yuidPublicKey = String(req.body?.yuidPublicKey || '').trim();
  const yuidSignature = String(req.body?.yuidSignature || '').trim();
  const yuidNonce = String(req.body?.yuidNonce || '').trim();
  const mediaDeviceId = String(req.body?.mediaDeviceId || '').trim();
  const mediaPublicKey = String(req.body?.mediaPublicKey || '').trim();
  const mediaDeviceSignature = String(
    req.body?.mediaDeviceSignature || '',
  ).trim();
  const deviceName =
    String(req.body?.deviceName || 'Yappa client').trim().slice(0, 80) ||
    'Yappa client';


if (!yuidPublicKey || !yuidSignature || !yuidNonce) {
  return apiError(
    res,
    400,
    'missing_yuid_proof',
    'This Yappa client must present a valid YUID proof.',
  );
}

const yuidVerification = verifyYuidProof({
  usernameNormalized,
  yuidPublicKey,
  yuidSignature,
  yuidNonce,
});

if (!yuidVerification.ok) {
  return apiError(
    res,
    yuidVerification.status,
    yuidVerification.code,
    yuidVerification.message,
  );
}

if (yuidClaim && yuidClaim !== yuidVerification.yuid) {
  return apiError(
    res,
    400,
    'yuid_claim_mismatch',
    'The claimed YUID does not match the signed YUID proof.',
  );
}

  if (!mediaDeviceId || !mediaPublicKey || !mediaDeviceSignature) {
    return apiError(
      res,
      400,
      'missing_media_device_proof',
      'This Yappa client must authorize its media encryption device.',
    );
  }
  const mediaDeviceVerification = verifyMediaDeviceProof({
    usernameNormalized,
    yuidPublicKey: yuidVerification.yuidPublicKey,
    yuidNonce,
    mediaDeviceId,
    mediaPublicKey,
    mediaDeviceSignature,
  });
  if (!mediaDeviceVerification.ok) {
    return apiError(
      res,
      mediaDeviceVerification.status,
      mediaDeviceVerification.code,
      mediaDeviceVerification.message,
    );
  }

  const yuidBan = getActiveBanForIdentity({ yuid: yuidVerification.yuid });
  if (yuidBan) {
    return apiError(
      res,
      403,
      'account_banned',
      'This YUID is banned from this server.',
      {
        banId: toId(yuidBan.id),
        reason: yuidBan.reason || null,
      },
    );
  }

  if (username.length < 3 || username.length > 24) {
    return apiError(
      res,
      400,
      'invalid_username_length',
      'Username must be 3-24 characters.',
    );
  }

  if (!/^[A-Za-z0-9_\-]+$/.test(username)) {
    return apiError(
      res,
      400,
      'invalid_username_characters',
      'Username can only use letters, numbers, underscore, and dash.',
    );
  }

  if (password.length < 6 || password.length > 128) {
    return apiError(
      res,
      400,
      'invalid_password_length',
      'Password must be 6-128 characters.',
    );
  }

  let user = db
  .prepare('SELECT id, username, role, display_name, avatar_url, password_hash, created_at, last_login_at, yuid, yuid_public_key, yuid_bound_at, yuid_last_seen_at FROM users WHERE lower(username) = ?')
  .get(usernameNormalized);

  if (user) {
    const accountBan = getActiveBanForIdentity({ userId: user.id, yuid: user.yuid || yuidVerification.yuid });
    if (accountBan) {
      clearSessionsForUser(user.id);
      disconnectUserSockets(user.id);
      return apiError(
        res,
        403,
        'account_banned',
        'This account or YUID is banned from this server.',
        {
          banId: toId(accountBan.id),
          reason: accountBan.reason || null,
        },
      );
    }

    const activeBackoff = getAuthBackoff(user.id);
    if (activeBackoff) {
      return authBackoffError(res, activeBackoff);
    }
  }

  if (!user) {
    if (password.length < NEW_ACCOUNT_PASSWORD_MIN_LENGTH) {
      return apiError(
        res,
        400,
        'password_too_short',
        `New account passwords must be at least ${NEW_ACCOUNT_PASSWORD_MIN_LENGTH} characters.`,
      );
    }

    const existingCount = db.prepare('SELECT COUNT(*) AS value FROM users').get().value;
    const role = Number(existingCount) === 0 ? 'owner' : 'member';
    const existingYuidUser = getUserByYuid(db, yuidVerification.yuid);
    if (existingYuidUser) {
      return apiError(
        res,
        409,
        'yuid_already_bound',
        'This YUID is already bound to another account on this node.',
      );
    }

    const passwordHash = await bcrypt.hash(password, BCRYPT_COST);
    const boundAt = nowIso();
    const created = createUserWithRole(db, {
      username,
      usernameNormalized,
      passwordHash,
      role,
      yuid: yuidVerification.yuid,
      yuidPublicKey: yuidVerification.yuidPublicKey,
      yuidBoundAt: boundAt,
      yuidLastSeenAt: boundAt,
    });
    user = {
      ...created,
      password_hash: passwordHash,
    };
  } else {
    const passwordMatch = await bcrypt.compare(password, user.password_hash);
    if (!passwordMatch) {
      const backoff = recordAuthFailure(user.id);
      if (backoff) {
        return authBackoffError(res, backoff);
      }
      return apiError(
        res,
        401,
        'invalid_credentials',
        'Username or password is incorrect.',
      );
    }
    clearAuthFailures(user.id);

    const currentCost = bcrypt.getRounds(user.password_hash);
    if (currentCost < BCRYPT_COST) {
      const upgradedPasswordHash = await bcrypt.hash(password, BCRYPT_COST);
      db.prepare('UPDATE users SET password_hash = ? WHERE id = ?').run(
        upgradedPasswordHash,
        user.id,
      );
      user = {
        ...user,
        password_hash: upgradedPasswordHash,
      };
    }

    const presentedYuid = yuidVerification.yuid;
    const presentedYuidPublicKey = yuidVerification.yuidPublicKey;
    const currentYuid = String(user.yuid || '').trim();
    const currentYuidPublicKey = String(user.yuid_public_key || '').trim();
    const needsInitialBinding = currentYuid.isEmpty || currentYuidPublicKey.isEmpty;
    const needsRebind =
      (!needsInitialBinding && currentYuid !== presentedYuid) ||
      (!needsInitialBinding && currentYuidPublicKey !== presentedYuidPublicKey);

    if (needsInitialBinding || needsRebind) {
      const existingYuidUser = getUserByYuid(db, presentedYuid);
      if (existingYuidUser && Number(existingYuidUser.id) !== Number(user.id)) {
        return apiError(
          res,
          409,
          'yuid_already_bound',
          'This YUID is already bound to another account on this node.',
        );
      }

      const existingYuidKeyUser = db
        .prepare('SELECT id FROM users WHERE yuid_public_key = ? LIMIT 1')
        .get(presentedYuidPublicKey);
      if (existingYuidKeyUser && Number(existingYuidKeyUser.id) !== Number(user.id)) {
        return apiError(
          res,
          409,
          'yuid_key_already_bound',
          'This YUID key is already bound to another account on this node.',
        );
      }

      const reboundAt = nowIso();
      user = {
        ...user,
        ...bindUserYuid(db, user.id, {
          yuid: presentedYuid,
          yuidPublicKey: presentedYuidPublicKey,
          boundAt: reboundAt,
          lastSeenAt: reboundAt,
        }),
      };

    } else {
      touchUserYuid(db, user.id, nowIso());
    }
  }

  const mediaDeviceRegistration = registerMediaDevice(
    user.id,
    mediaDeviceVerification,
  );
  if (!mediaDeviceRegistration.ok) {
    return apiError(
      res,
      mediaDeviceRegistration.status,
      mediaDeviceRegistration.code,
      mediaDeviceRegistration.message,
    );
  }

  const token = crypto.randomBytes(32).toString('hex');
  const createdAt = nowIso();
  const expiresAt = new Date(
    Date.now() + SESSION_ABSOLUTE_TTL_MS,
  ).toISOString();
  const idleExpiresAt = nextIdleExpiry();
  db.prepare(`
  INSERT INTO sessions (
    token, user_id, created_at, last_seen_at, expires_at, idle_expires_at,
    device_name, media_device_id
  )
  VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    sessionTokenStorageValue(token),
    user.id,
    createdAt,
    createdAt,
    expiresAt,
    idleExpiresAt,
    deviceName,
    mediaDeviceVerification.deviceId,
  );

  touchUserLogin(db, user.id, createdAt);
  const refreshedUser = db
  .prepare('SELECT id, username, role, display_name, avatar_url, created_at, last_login_at, yuid, yuid_public_key, yuid_bound_at, yuid_last_seen_at FROM users WHERE id = ?')
  .get(user.id);

  const voicePresence = getVoicePresenceForUser(refreshedUser.id);

  res.status(201).json({
    ok: true,
    token,
    mediaDevice: serializeMediaDevice(mediaDeviceRegistration.device),
    user: serializeUser(refreshedUser, {
      isOnline: true,
      voiceChannelId: voicePresence?.voiceChannelId || null,
      voiceJoinedAt: voicePresence?.voiceJoinedAt || null,
      voiceState: getVoiceMediaStateForUser(refreshedUser.id),
    }),
    server: currentServer(),
                       channels: currentChannels(),
                       settings: currentSettings(),
                       voice: getVoiceState(),
                       permissions: {
                         isOwner: refreshedUser.role === 'owner',
                         canManageServer: refreshedUser.role === 'owner',
                         canManageChannels: refreshedUser.role === 'owner',
                         canManageInvites: refreshedUser.role === 'owner',
                         canManageBranding: refreshedUser.role === 'owner',
                         canManageMedia: refreshedUser.role === 'owner',
                       },
                       bans: refreshedUser.role === 'owner' ? currentBans() : [],
  });
});

app.get('/api/auth/me', authRequired, (req, res) => {
  touchSession(db, req.auth.token);
  const user = req.auth.user;
  const voicePresence = getVoicePresenceForUser(user.id);

  res.json({
    ok: true,
    mediaDevice: req.auth.session.mediaDeviceId
      ? serializeMediaDevice(
          db
            .prepare('SELECT * FROM media_devices WHERE id = ?')
            .get(req.auth.session.mediaDeviceId),
        )
      : null,
    user: serializeUser(user, {
      isOnline: getOnlineUserIds().has(user.id),
                        voiceChannelId: voicePresence?.voiceChannelId || null,
                        voiceJoinedAt: voicePresence?.voiceJoinedAt || null,
                        voiceState: getVoiceMediaStateForUser(user.id),
    }),
    server: currentServer(),
           channels: currentChannels(),
           settings: currentSettings(),
           bans: req.auth.user.role === 'owner' ? currentBans() : [],
           voice: getVoiceState(),
           permissions: {
             isOwner: user.role === 'owner',
             canManageServer: user.role === 'owner',
             canManageChannels: user.role === 'owner',
             canManageInvites: user.role === 'owner',
             canManageBranding: user.role === 'owner',
             canManageMedia: user.role === 'owner',
           },
  });
});

app.post(
  '/api/media/devices/register',
  authRequired,
  accountMutationRateLimit,
  (req, res) => {
  const usernameNormalized = req.auth.user.username.trim().toLowerCase();
  const yuidPublicKey = String(req.body?.yuidPublicKey || '').trim();
  const yuidSignature = String(req.body?.yuidSignature || '').trim();
  const yuidNonce = String(req.body?.yuidNonce || '').trim();
  const yuidVerification = verifyYuidProof({
    usernameNormalized,
    yuidPublicKey,
    yuidSignature,
    yuidNonce,
  });
  if (!yuidVerification.ok) {
    return apiError(
      res,
      yuidVerification.status,
      yuidVerification.code,
      yuidVerification.message,
    );
  }
  if (
    yuidVerification.yuid !== req.auth.user.yuid ||
    yuidVerification.yuidPublicKey !== yuidPublicKey
  ) {
    return apiError(
      res,
      403,
      'media_device_yuid_mismatch',
      'The device authorization does not match this account.',
    );
  }
  const mediaVerification = verifyMediaDeviceProof({
    usernameNormalized,
    yuidPublicKey,
    yuidNonce,
    mediaDeviceId: String(req.body?.mediaDeviceId || '').trim(),
    mediaPublicKey: String(req.body?.mediaPublicKey || '').trim(),
    mediaDeviceSignature: String(
      req.body?.mediaDeviceSignature || '',
    ).trim(),
  });
  if (!mediaVerification.ok) {
    return apiError(
      res,
      mediaVerification.status,
      mediaVerification.code,
      mediaVerification.message,
    );
  }
  const registration = registerMediaDevice(
    req.auth.user.id,
    mediaVerification,
  );
  if (!registration.ok) {
    return apiError(
      res,
      registration.status,
      registration.code,
      registration.message,
    );
  }
  db.prepare(
    'UPDATE sessions SET media_device_id = ? WHERE id = ?',
  ).run(mediaVerification.deviceId, req.auth.session.id);
  return res.json({
    ok: true,
    mediaDevice: serializeMediaDevice(registration.device),
  });
  },
);

app.get('/api/media/devices', authRequired, (_req, res) => {
  const rows = db
    .prepare(`
      SELECT media_devices.*, users.username, users.yuid,
             users.yuid_public_key
      FROM media_devices
      JOIN users ON users.id = media_devices.user_id
      WHERE media_devices.revoked_at IS NULL
      AND NOT EXISTS (
        SELECT 1
        FROM bans
        WHERE bans.revoked_at IS NULL
        AND (
          bans.user_id = users.id
          OR (bans.yuid IS NOT NULL AND bans.yuid = users.yuid)
        )
      )
      ORDER BY media_devices.id ASC
    `)
    .all();
  return res.json({
    ok: true,
    devices: rows.map((row) => ({
      ...serializeMediaDevice(row),
      username: row.username,
      yuid: row.yuid,
      yuidPublicKey: row.yuid_public_key,
    })),
  });
});

app.delete(
  '/api/media/devices/:deviceId',
  authRequired,
  accountMutationRateLimit,
  (req, res) => {
  const deviceId = String(req.params.deviceId || '').trim();
  if (!/^device_[A-Za-z0-9_-]{24}$/.test(deviceId)) {
    return apiError(
      res,
      400,
      'invalid_media_device_id',
      'Invalid media device identifier.',
    );
  }
  const device = db
    .prepare('SELECT * FROM media_devices WHERE id = ?')
    .get(deviceId);
  if (!device || device.revoked_at) {
    return apiError(
      res,
      404,
      'media_device_not_found',
      'Media device was not found.',
    );
  }
  if (
    Number(device.user_id) !== Number(req.auth.user.id) &&
    req.auth.user.role !== 'owner'
  ) {
    return apiError(
      res,
      403,
      'media_device_forbidden',
      'You cannot revoke another account’s media device.',
    );
  }
  const sessionRows = db
    .prepare('SELECT id FROM sessions WHERE media_device_id = ?')
    .all(deviceId);
  const revokedAt = nowIso();
  const revoke = db.transaction(() => {
    db.prepare(
      'UPDATE media_devices SET revoked_at = ? WHERE id = ?',
    ).run(revokedAt, deviceId);
    db.prepare('DELETE FROM sessions WHERE media_device_id = ?').run(deviceId);
  });
  revoke();
  for (const session of sessionRows) {
    disconnectSessionSockets(session.id);
  }
  return res.json({ ok: true, deviceId, revokedAt });
  },
);

app.get('/api/mls/key-packages', authRequired, (req, res) => {
  const deviceId = req.auth.session.mediaDeviceId;
  if (!deviceId) {
    return apiError(
      res,
      409,
      'media_device_required',
      'This session must be bound to an active device.',
    );
  }
  const now = nowIso();
  compactExpiredMlsKeyPackages(now);
  const counts = db.prepare(`
    SELECT
      COUNT(*) AS total,
      SUM(CASE
        WHEN claimed_at IS NULL AND expires_at > ? THEN 1
        ELSE 0
      END) AS available
    FROM mls_key_packages
    WHERE device_id = ?
  `).get(now, deviceId);
  return res.json({
    ok: true,
    deviceId,
    total: Number(counts.total || 0),
    available: Number(counts.available || 0),
  });
});

app.post(
  '/api/mls/key-packages',
  authRequired,
  accountMutationRateLimit,
  (req, res) => {
    const deviceId = req.auth.session.mediaDeviceId;
    if (!deviceId) {
      return apiError(
        res,
        409,
        'media_device_required',
        'This session must be bound to an active device.',
      );
    }
    const packages = req.body?.packages;
    if (!Array.isArray(packages) || packages.length < 1 || packages.length > 2) {
      return apiError(
        res,
        400,
        'invalid_mls_key_packages',
        'Submit one or two MLS KeyPackages per request.',
      );
    }
    const user = db.prepare(`
      SELECT yuid, yuid_public_key
      FROM users
      WHERE id = ?
    `).get(req.auth.user.id);
    if (!user?.yuid || !user?.yuid_public_key) {
      return apiError(
        res,
        409,
        'verified_yuid_required',
        'A verified YUID is required for encrypted messaging.',
      );
    }
    const now = Date.now();
    compactExpiredMlsKeyPackages(new Date(now).toISOString());
    const validated = [];
    for (const item of packages) {
      const ciphersuite = Number(item?.ciphersuite);
      const keyPackageText = String(item?.keyPackage || '').trim();
      const expiresAt = String(item?.expiresAt || '').trim();
      const expiresAtMs = Date.parse(expiresAt);
      if (
        ciphersuite !== 1 ||
        !/^[A-Za-z0-9_-]+$/.test(keyPackageText) ||
        !Number.isFinite(expiresAtMs) ||
        expiresAtMs < now + 5 * 60 * 1000 ||
        expiresAtMs > now + 30 * 24 * 60 * 60 * 1000
      ) {
        return apiError(
          res,
          400,
          'invalid_mls_key_package',
          'Invalid MLS KeyPackage ciphersuite, encoding, or expiry.',
        );
      }
      const keyPackage = decodeBase64Url(keyPackageText);
      if (!keyPackage || keyPackage.length < 64 || keyPackage.length > 65536) {
        return apiError(
          res,
          400,
          'invalid_mls_key_package',
          'MLS KeyPackage size must be between 64 and 65536 bytes.',
        );
      }
      const binding = verifyMlsCredentialBinding({
        yuid: user.yuid,
        yuidPublicKey: user.yuid_public_key,
        deviceId,
        signaturePublicKey: String(item?.signaturePublicKey || '').trim(),
        identityBindingSignature: String(
          item?.identityBindingSignature || '',
        ).trim(),
      });
      if (!binding.ok) {
        return apiError(
          res,
          401,
          binding.code,
          'The MLS credential is not authorized by this account’s YUID.',
        );
      }
      validated.push({
        id: `kp_${crypto.randomBytes(16).toString('base64url')}`,
        ciphersuite,
        signaturePublicKey: binding.signaturePublicKey,
        identityBindingSignature: binding.identityBindingSignature,
        keyPackage,
        keyPackageHash: crypto
          .createHash('sha256')
          .update(keyPackage)
          .digest('hex'),
        expiresAt: new Date(expiresAtMs).toISOString(),
      });
    }
    const available = db.prepare(`
      SELECT COUNT(*) AS count
      FROM mls_key_packages
      WHERE device_id = ?
      AND claimed_at IS NULL
      AND expires_at > ?
    `).get(deviceId, nowIso()).count;
    if (Number(available) + validated.length > 100) {
      return apiError(
        res,
        409,
        'mls_key_package_limit',
        'This device already has enough unused MLS KeyPackages.',
      );
    }
    const total = db.prepare(`
      SELECT COUNT(*) AS count
      FROM mls_key_packages
      WHERE device_id = ?
    `).get(deviceId).count;
    if (Number(total) + validated.length > 10000) {
      return apiError(
        res,
        409,
        'mls_key_package_history_limit',
        'This device has reached its MLS KeyPackage history limit.',
      );
    }
    const insert = db.prepare(`
      INSERT INTO mls_key_packages (
        id, device_id, ciphersuite, signature_public_key,
        identity_binding_signature, key_package, key_package_hash,
        created_at, expires_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    try {
      db.transaction(() => {
        const createdAt = nowIso();
        const existingCredentials = Number(
          db.prepare(`
            SELECT COUNT(*) AS count
            FROM mls_device_credentials
            WHERE device_id = ?
          `).get(deviceId).count,
        );
        const existingKeys = new Set(
          db.prepare(`
            SELECT signature_public_key
            FROM mls_device_credentials
            WHERE device_id = ?
          `).all(deviceId).map((row) => row.signature_public_key),
        );
        const newKeys = new Set(
          validated
            .map((item) => item.signaturePublicKey)
            .filter((key) => !existingKeys.has(key)),
        );
        if (existingCredentials + newKeys.size > 8) {
          const limit = new Error('MLS credential history limit reached.');
          limit.code = 'MLS_DEVICE_CREDENTIAL_LIMIT';
          throw limit;
        }
        const insertCredential = db.prepare(`
          INSERT OR IGNORE INTO mls_device_credentials (
            device_id, signature_public_key, identity_binding_signature,
            created_at
          )
          VALUES (?, ?, ?, ?)
        `);
        for (const item of validated) {
          insertCredential.run(
            deviceId,
            item.signaturePublicKey,
            item.identityBindingSignature,
            createdAt,
          );
          insert.run(
            item.id,
            deviceId,
            item.ciphersuite,
            item.signaturePublicKey,
            item.identityBindingSignature,
            item.keyPackage,
            item.keyPackageHash,
            createdAt,
            item.expiresAt,
          );
        }
      })();
    } catch (error) {
      if (error?.code === 'MLS_DEVICE_CREDENTIAL_LIMIT') {
        return apiError(
          res,
          409,
          'mls_device_credential_limit',
          'This device has reached its MLS credential history limit.',
        );
      }
      if (String(error?.code || '').startsWith('SQLITE_CONSTRAINT')) {
        return apiError(
          res,
          409,
          'duplicate_mls_key_package',
          'An MLS KeyPackage was already registered.',
        );
      }
      throw error;
    }
    return res.status(201).json({
      ok: true,
      deviceId,
      registered: validated.length,
    });
  },
);

app.get('/api/mls/device-credentials', authRequired, (_req, res) => {
  const credentials = db.prepare(`
    SELECT mls_device_credentials.device_id,
           mls_device_credentials.signature_public_key,
           mls_device_credentials.identity_binding_signature,
           mls_device_credentials.created_at,
           users.id AS user_id, users.username, users.yuid,
           users.yuid_public_key,
           CASE WHEN users.role = 'owner' THEN 1 ELSE 0 END AS is_server_owner,
           CASE
             WHEN media_devices.revoked_at IS NULL
              AND NOT EXISTS (
                SELECT 1 FROM bans
                WHERE bans.revoked_at IS NULL
                AND (
                  bans.user_id = users.id
                  OR (bans.yuid IS NOT NULL AND bans.yuid = users.yuid)
                )
              )
             THEN 1 ELSE 0
           END AS is_active
    FROM mls_device_credentials
    JOIN media_devices
      ON media_devices.id = mls_device_credentials.device_id
    JOIN users ON users.id = media_devices.user_id
    ORDER BY mls_device_credentials.device_id ASC,
             mls_device_credentials.signature_public_key ASC
    LIMIT 10000
  `).all();
  return res.json({
    ok: true,
    credentials: credentials.map((row) => ({
      deviceId: row.device_id,
      signaturePublicKey: row.signature_public_key,
      identityBindingSignature: row.identity_binding_signature,
      userId: toId(row.user_id),
      username: row.username,
      yuid: row.yuid,
      yuidPublicKey: row.yuid_public_key,
      isServerOwner: row.is_server_owner === 1,
      isActive: row.is_active === 1,
      createdAt: row.created_at,
    })),
  });
});

app.post(
  '/api/mls/key-packages/claim',
  authRequired,
  accountMutationRateLimit,
  (req, res) => {
    const claimantDeviceId = req.auth.session.mediaDeviceId;
    const targetDeviceId = String(req.body?.deviceId || '').trim();
    if (
      !claimantDeviceId ||
      !/^device_[A-Za-z0-9_-]{24}$/.test(targetDeviceId)
    ) {
      return apiError(
        res,
        400,
        'invalid_mls_key_package_claim',
        'An active claimant and target device are required.',
      );
    }
    const target = db.prepare(`
      SELECT media_devices.id, users.username, users.yuid,
             users.yuid_public_key
      FROM media_devices
      JOIN users ON users.id = media_devices.user_id
      WHERE media_devices.id = ?
      AND media_devices.revoked_at IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM bans
        WHERE bans.revoked_at IS NULL
        AND (
          bans.user_id = users.id
          OR (bans.yuid IS NOT NULL AND bans.yuid = users.yuid)
        )
      )
    `).get(targetDeviceId);
    if (!target) {
      return apiError(
        res,
        404,
        'mls_target_device_not_found',
        'The target encrypted-messaging device is unavailable.',
      );
    }
    const claimedAt = nowIso();
    compactExpiredMlsKeyPackages(claimedAt);
    const claim = db.transaction(() => {
      const item = db.prepare(`
        SELECT *
        FROM mls_key_packages
        WHERE device_id = ?
        AND claimed_at IS NULL
        AND expires_at > ?
        ORDER BY expires_at ASC, id ASC
        LIMIT 1
      `).get(targetDeviceId, claimedAt);
      if (!item) return null;
      const update = db.prepare(`
        UPDATE mls_key_packages
        SET claimed_at = ?, claimed_by_device_id = ?, key_package = X''
        WHERE id = ? AND claimed_at IS NULL
      `).run(claimedAt, claimantDeviceId, item.id);
      return update.changes === 1 ? item : null;
    })();
    if (!claim) {
      return apiError(
        res,
        404,
        'mls_key_package_unavailable',
        'That device has no unused MLS KeyPackage.',
      );
    }
    return res.json({
      ok: true,
      keyPackage: {
        id: claim.id,
        deviceId: claim.device_id,
        ciphersuite: Number(claim.ciphersuite),
        signaturePublicKey: claim.signature_public_key,
        identityBindingSignature: claim.identity_binding_signature,
        username: target.username,
        yuid: target.yuid,
        yuidPublicKey: target.yuid_public_key,
        keyPackage: Buffer.from(claim.key_package).toString('base64url'),
        keyPackageHash: claim.key_package_hash,
        expiresAt: claim.expires_at,
      },
    });
  },
);

app.post(
  '/api/channels/:channelId/encrypted-attachments',
  authRequired,
  uploadRateLimit,
  durableStorageRequired,
  uploadSingleEncryptedAttachment,
  async (req, res, next) => {
    const uploadedFile = req.file;
    const channelId = Number(req.params.channelId);
    const uploaderDeviceId = req.auth.session.mediaDeviceId;
    const discardUpload = () => {
      if (uploadedFile?.path) {
        fs.unlink(uploadedFile.path, () => {});
      }
    };
    if (!uploadedFile) {
      return apiError(
        res,
        400,
        'missing_encrypted_attachment',
        'No encrypted attachment object was uploaded.',
      );
    }
    if (!requireDurableStorage(req, res, { uploadedFile, incomingBytes: 0 })) {
      return;
    }
    if (!Number.isInteger(channelId) || !uploaderDeviceId) {
      discardUpload();
      return apiError(
        res,
        400,
        'invalid_encrypted_attachment',
        'An encrypted text channel and active device are required.',
      );
    }
    const channel = db.prepare(`
      SELECT id, type, encryption_mode, encryption_version
      FROM channels
      WHERE id = ?
    `).get(channelId);
    if (
      !channel ||
      channel.type !== 'text' ||
      channel.encryption_mode !== 'e2ee' ||
      Number(channel.encryption_version) !== 1
    ) {
      discardUpload();
      return apiError(
        res,
        409,
        'encrypted_channel_required',
        'Encrypted attachments require an E2EE version 1 text channel.',
      );
    }

    const secretstreamHeaderText = String(
      req.body?.secretstreamHeader || '',
    ).trim();
    const attachmentId = String(req.body?.attachmentId || '').trim();
    const expectedDigest = String(req.body?.ciphertextSha256 || '')
      .trim()
      .toLowerCase();
    const chunkCount = Number(req.body?.chunkCount);
    const secretstreamHeader = decodeBase64Url(secretstreamHeaderText);
    if (
      !secretstreamHeader ||
      secretstreamHeader.length !== 24 ||
      !/^eatt_[A-Za-z0-9_-]{22}$/.test(attachmentId) ||
      !/^[a-f0-9]{64}$/.test(expectedDigest) ||
      !Number.isInteger(chunkCount) ||
      chunkCount < 1 ||
      chunkCount > 1000000
    ) {
      discardUpload();
      return apiError(
        res,
        400,
        'invalid_encrypted_attachment_metadata',
        'Invalid secretstream header, ciphertext digest, or chunk count.',
      );
    }

    const settings = getServerSettings(db);
    const maxCiphertextBytes =
      Number(settings.attachment_max_bytes) + 1024 * 1024;
    if (
      uploadedFile.size < 17 ||
      uploadedFile.size > maxCiphertextBytes
    ) {
      discardUpload();
      return apiError(
        res,
        400,
        'encrypted_attachment_too_large',
        `Encrypted attachment exceeds the ${maxCiphertextBytes} byte limit.`,
      );
    }

    let actualDigest;
    try {
      actualDigest = await sha256File(uploadedFile.path);
    } catch (error) {
      discardUpload();
      throw error;
    }
    if (actualDigest !== expectedDigest) {
      discardUpload();
      return apiError(
        res,
        400,
        'encrypted_attachment_digest_mismatch',
        'The uploaded ciphertext does not match its declared digest.',
      );
    }

    const existingAttachment = db.prepare(`
      SELECT *
      FROM encrypted_attachments
      WHERE id = ?
    `).get(attachmentId);
    if (existingAttachment) {
      const existingHeader = Buffer.from(
        existingAttachment.secretstream_header,
      );
      const sameAttachment =
        Number(existingAttachment.channel_id) === channelId &&
        Number(existingAttachment.uploader_user_id) ===
          Number(req.auth.user.id) &&
        existingAttachment.uploader_device_id === uploaderDeviceId &&
        existingAttachment.deleted_at == null &&
        Number(existingAttachment.ciphertext_size_bytes) ===
          Number(uploadedFile.size) &&
        existingAttachment.ciphertext_sha256 === actualDigest &&
        Number(existingAttachment.chunk_count) === chunkCount &&
        existingHeader.length === secretstreamHeader.length &&
        crypto.timingSafeEqual(existingHeader, secretstreamHeader);
      discardUpload();
      if (!sameAttachment) {
        return apiError(
          res,
          409,
          'encrypted_attachment_operation_conflict',
          'That encrypted attachment id was already used for different data.',
        );
      }
      return res.status(200).json({
        ok: true,
        replayed: true,
        attachment: {
          id: attachmentId,
          channelId: toId(channelId),
          secretstreamHeader: existingHeader.toString('base64url'),
          ciphertextSizeBytes: Number(
            existingAttachment.ciphertext_size_bytes,
          ),
          ciphertextSha256: existingAttachment.ciphertext_sha256,
          chunkCount: Number(existingAttachment.chunk_count),
          createdAt: existingAttachment.created_at,
          expiresAt: existingAttachment.expires_at,
        },
      });
    }

    const totalBytes = db.prepare(`
      SELECT
        (SELECT COALESCE(SUM(size_bytes), 0)
         FROM attachments
         WHERE deleted_at IS NULL) +
        (SELECT COALESCE(SUM(ciphertext_size_bytes), 0)
         FROM encrypted_attachments
         WHERE deleted_at IS NULL) AS total
    `).get().total;
    if (
      Number(totalBytes) + uploadedFile.size >
      Number(settings.file_storage_max_total_bytes)
    ) {
      discardUpload();
      return apiError(
        res,
        400,
        'attachment_storage_limit_reached',
        'The server is out of attachment storage space.',
      );
    }

    const createdAt = nowIso();
    const expiresAt = computeExpiresAt(settings.attachment_retention_days);
    const relativePath = path.relative(DATA_ROOT, uploadedFile.path);
    try {
      db.prepare(`
        INSERT INTO encrypted_attachments (
          id, channel_id, event_id, uploader_user_id, uploader_device_id,
          relative_path, secretstream_header, ciphertext_size_bytes,
          ciphertext_sha256, chunk_count, created_at, expires_at, deleted_at
        )
        VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
      `).run(
        attachmentId,
        channelId,
        req.auth.user.id,
        uploaderDeviceId,
        relativePath,
        secretstreamHeader,
        uploadedFile.size,
        actualDigest,
        chunkCount,
        createdAt,
        expiresAt,
      );
    } catch (error) {
      discardUpload();
      if (String(error?.code || '').startsWith('SQLITE_CONSTRAINT')) {
        return apiError(
          res,
          409,
          'duplicate_encrypted_attachment',
          'That encrypted attachment id is already reserved.',
        );
      }
      return next(error);
    }
    return res.status(201).json({
      ok: true,
      attachment: {
        id: attachmentId,
        channelId: toId(channelId),
        secretstreamHeader: secretstreamHeader.toString('base64url'),
        ciphertextSizeBytes: uploadedFile.size,
        ciphertextSha256: actualDigest,
        chunkCount,
        createdAt,
        expiresAt,
      },
    });
  },
);

app.get(
  '/api/channels/:channelId/encrypted-attachments/:attachmentId',
  authRequired,
  attachmentDownloadRateLimit,
  (req, res) => {
    const channelId = Number(req.params.channelId);
    const attachmentId = String(req.params.attachmentId || '').trim();
    if (
      !Number.isInteger(channelId) ||
      !/^eatt_[A-Za-z0-9_-]{22}$/.test(attachmentId)
    ) {
      return apiError(
        res,
        400,
        'invalid_encrypted_attachment',
        'Invalid encrypted attachment identifier.',
      );
    }
    const attachment = db.prepare(`
      SELECT encrypted_attachments.*
      FROM encrypted_attachments
      JOIN channels ON channels.id = encrypted_attachments.channel_id
      WHERE encrypted_attachments.id = ?
      AND encrypted_attachments.channel_id = ?
      AND encrypted_attachments.deleted_at IS NULL
      AND (
        encrypted_attachments.expires_at IS NULL
        OR encrypted_attachments.expires_at > ?
      )
      AND channels.type = 'text'
      AND channels.encryption_mode = 'e2ee'
      AND channels.encryption_version = 1
    `).get(attachmentId, channelId, nowIso());
    if (!attachment) {
      return apiError(
        res,
        404,
        'encrypted_attachment_not_found',
        'Encrypted attachment not found.',
      );
    }
    const absolutePath = path.resolve(DATA_ROOT, attachment.relative_path);
    const resolvedRoot = path.resolve(encryptedAttachmentsRoot);
    if (
      absolutePath === resolvedRoot ||
      !absolutePath.startsWith(`${resolvedRoot}${path.sep}`)
    ) {
      return apiError(
        res,
        403,
        'encrypted_attachment_path_invalid',
        'The encrypted attachment path is invalid.',
      );
    }
    res.setHeader('Content-Type', 'application/octet-stream');
    res.setHeader('Content-Disposition', 'attachment; filename="ciphertext.bin"');
    res.setHeader('Cache-Control', 'private, no-store');
    res.setHeader(
      'X-Yappa-Secretstream-Header',
      Buffer.from(attachment.secretstream_header).toString('base64url'),
    );
    res.setHeader(
      'X-Yappa-Ciphertext-SHA256',
      attachment.ciphertext_sha256,
    );
    res.setHeader('X-Yappa-Chunk-Count', String(attachment.chunk_count));
    res.setHeader(
      'X-Yappa-Ciphertext-Size',
      String(attachment.ciphertext_size_bytes),
    );
    return res.sendFile(absolutePath);
  },
);

app.post(
  '/api/channels/:channelId/mls/initialize',
  authRequired,
  accountMutationRateLimit,
  (req, res) => {
    const channelId = Number(req.params.channelId);
    const deviceId = req.auth.session.mediaDeviceId;
    if (!Number.isInteger(channelId) || !deviceId) {
      return apiError(
        res,
        400,
        'invalid_mls_group_initialization',
        'An encrypted text channel and active device are required.',
      );
    }
    const channel = db.prepare(`
      SELECT id, type, encryption_mode, encryption_version
      FROM channels
      WHERE id = ?
    `).get(channelId);
    if (
      !channel ||
      channel.type !== 'text' ||
      channel.encryption_mode !== 'e2ee' ||
      Number(channel.encryption_version) !== 1
    ) {
      return apiError(
        res,
        409,
        'encrypted_channel_required',
        'MLS groups can only initialize in an E2EE version 1 text channel.',
      );
    }
    const groupId = `yappa-text-v1|${serverId}|${toId(channelId)}`;
    const existingState = db
      .prepare('SELECT * FROM mls_channel_state WHERE channel_id = ?')
      .get(channelId);
    if (!existingState) {
      if (req.auth.user.role !== 'owner') {
        return apiError(
          res,
          403,
          'owner_required',
          'Only the server owner can initialize encrypted channel state.',
        );
      }
      const enrolled = db.prepare(`
        SELECT 1
        FROM mls_device_credentials
        WHERE device_id = ?
        LIMIT 1
      `).get(deviceId);
      if (!enrolled) {
        return apiError(
          res,
          409,
          'mls_device_enrollment_required',
          'This owner device must enroll encrypted messaging first.',
        );
      }
    }
    const createdAt = nowIso();
    let created = false;
    try {
      const insert = db.prepare(`
        INSERT INTO mls_channel_state (
          channel_id, group_id, current_epoch, next_sequence,
          initialized_by_device_id, initialized_at, updated_at
        )
        VALUES (?, ?, 0, 1, ?, ?, ?)
      `).run(channelId, groupId, deviceId, createdAt, createdAt);
      created = insert.changes === 1;
    } catch (error) {
      if (!String(error?.code || '').startsWith('SQLITE_CONSTRAINT')) {
        throw error;
      }
    }
    const state = db
      .prepare('SELECT * FROM mls_channel_state WHERE channel_id = ?')
      .get(channelId);
    if (!state) {
      return apiError(
        res,
        409,
        'mls_group_initialization_conflict',
        'The MLS group could not be initialized.',
      );
    }
    return res.status(created ? 201 : 200).json({
      ok: true,
      created,
      group: {
        channelId: toId(channelId),
        groupId: state.group_id,
        currentEpoch: Number(state.current_epoch),
        nextSequence: Number(state.next_sequence),
        initializedByDeviceId: state.initialized_by_device_id,
        initializedAt: state.initialized_at,
      },
    });
  },
);

app.post(
  '/api/channels/:channelId/mls/messages',
  authRequired,
  contentMutationRateLimit,
  durableStorageRequired,
  (req, res) => {
    const channelId = Number(req.params.channelId);
    const uploaderDeviceId = req.auth.session.mediaDeviceId;
    if (!Number.isInteger(channelId) || !uploaderDeviceId) {
      return apiError(
        res,
        400,
        'invalid_mls_delivery_message',
        'An encrypted text channel and active device are required.',
      );
    }
    const channel = db.prepare(`
      SELECT id, type, encryption_mode, encryption_version
      FROM channels
      WHERE id = ?
    `).get(channelId);
    if (
      !channel ||
      channel.type !== 'text' ||
      channel.encryption_mode !== 'e2ee' ||
      Number(channel.encryption_version) !== 1
    ) {
      return apiError(
        res,
        409,
        'encrypted_channel_required',
        'MLS delivery requires an E2EE version 1 text channel.',
      );
    }
    const messageClass = String(req.body?.messageClass || '').trim();
    const clientOperationId = String(
      req.body?.clientOperationId || '',
    ).trim();
    const acceptedEpoch = Number(req.body?.acceptedEpoch);
    const parentEpoch =
      req.body?.parentEpoch == null ? null : Number(req.body.parentEpoch);
    const recipientDeviceId =
      req.body?.recipientDeviceId == null
        ? null
        : String(req.body.recipientDeviceId).trim();
    const wireText = String(req.body?.wireMessage || '').trim();
    if (
      !/^mlsop_[A-Za-z0-9_-]{22}$/.test(clientOperationId) ||
      !['proposal', 'commit', 'welcome', 'application'].includes(messageClass) ||
      !Number.isInteger(acceptedEpoch) ||
      acceptedEpoch < 0 ||
      (parentEpoch != null &&
        (!Number.isInteger(parentEpoch) || parentEpoch < 0)) ||
      !/^[A-Za-z0-9_-]+$/.test(wireText)
    ) {
      return apiError(
        res,
        400,
        'invalid_mls_delivery_message',
        'Invalid MLS delivery metadata or wire encoding.',
      );
    }
    const wireMessage = decodeBase64Url(wireText);
    if (!wireMessage || wireMessage.length < 1 || wireMessage.length > 131072) {
      return apiError(
        res,
        400,
        'invalid_mls_delivery_message',
        'MLS wire messages must be between 1 and 131072 bytes.',
      );
    }
    if (
      (messageClass === 'welcome' &&
        (!recipientDeviceId || !activeMlsDevice(recipientDeviceId))) ||
      (messageClass !== 'welcome' && recipientDeviceId != null)
    ) {
      return apiError(
        res,
        400,
        'invalid_mls_delivery_recipient',
        'Only Welcome messages may name one active recipient device.',
      );
    }

    let event = null;
    if (messageClass === 'application') {
      const eventId = String(req.body?.event?.eventId || '').trim();
      const kind = String(req.body?.event?.kind || '').trim();
      const targetEventId =
        req.body?.event?.targetEventId == null
          ? null
          : String(req.body.event.targetEventId).trim();
      const encryptedAttachmentIds = Array.isArray(
        req.body?.event?.encryptedAttachmentIds,
      )
        ? req.body.event.encryptedAttachmentIds.map((value) =>
            String(value || '').trim(),
          )
        : [];
      if (
        !/^[A-Za-z0-9_-]{22}$/.test(eventId) ||
        !['message', 'edit', 'delete', 'reaction', 'attachment'].includes(kind) ||
        (targetEventId != null && !/^[A-Za-z0-9_-]{22}$/.test(targetEventId)) ||
        encryptedAttachmentIds.length > 10 ||
        encryptedAttachmentIds.some(
          (id) => !/^eatt_[A-Za-z0-9_-]{22}$/.test(id),
        ) ||
        new Set(encryptedAttachmentIds).size !==
          encryptedAttachmentIds.length ||
        (['edit', 'delete', 'reaction'].includes(kind) &&
          targetEventId == null) ||
        (kind === 'attachment'
          ? encryptedAttachmentIds.length === 0
          : encryptedAttachmentIds.length !== 0)
      ) {
        return apiError(
          res,
          400,
          'invalid_encrypted_event_routing',
          'Invalid encrypted application-event routing metadata.',
        );
      }
      event = {
        eventId,
        kind,
        targetEventId,
        encryptedAttachmentIds,
      };
    } else if (req.body?.event != null) {
      return apiError(
        res,
        400,
        'unexpected_encrypted_event_routing',
        'Only MLS application messages may include event routing metadata.',
      );
    }

    try {
      const accepted = db.transaction(() => {
        const existing = db.prepare(`
          SELECT mls_delivery_messages.*, encrypted_message_events.event_id,
                 encrypted_message_events.event_kind,
                 encrypted_message_events.target_event_id
          FROM mls_delivery_messages
          LEFT JOIN encrypted_message_events
            ON encrypted_message_events.delivery_message_id =
               mls_delivery_messages.id
          WHERE mls_delivery_messages.uploader_device_id = ?
          AND mls_delivery_messages.client_operation_id = ?
        `).get(uploaderDeviceId, clientOperationId);
        if (existing) {
          const existingAttachments =
            existing.event_id == null
              ? []
              : db.prepare(`
                  SELECT id
                  FROM encrypted_attachments
                  WHERE event_id = ?
                  AND deleted_at IS NULL
                  ORDER BY id ASC
                `).all(existing.event_id).map((item) => item.id);
          const requestedAttachments = [
            ...(event?.encryptedAttachmentIds || []),
          ].sort();
          const sameWire =
            Buffer.from(existing.wire_message).length === wireMessage.length &&
            crypto.timingSafeEqual(
              Buffer.from(existing.wire_message),
              wireMessage,
            );
          const sameOperation =
            Number(existing.channel_id) === channelId &&
            existing.message_class === messageClass &&
            Number(existing.accepted_epoch) === acceptedEpoch &&
            (existing.parent_epoch == null
              ? parentEpoch == null
              : Number(existing.parent_epoch) === parentEpoch) &&
            (existing.recipient_device_id || null) === recipientDeviceId &&
            sameWire &&
            (existing.event_id || null) === (event?.eventId || null) &&
            (existing.event_kind || null) === (event?.kind || null) &&
            (existing.target_event_id || null) ===
              (event?.targetEventId || null) &&
            existingAttachments.length === requestedAttachments.length &&
            existingAttachments.every(
              (value, index) => value === requestedAttachments[index],
            );
          return sameOperation
            ? { row: existing, replayed: true }
            : { error: 'mls_operation_conflict' };
        }
        const state = db
          .prepare('SELECT * FROM mls_channel_state WHERE channel_id = ?')
          .get(channelId);
        if (!state) {
          return { error: 'mls_group_not_initialized' };
        }
        const currentEpoch = Number(state.current_epoch);
        const validEpoch =
          messageClass === 'commit'
            ? parentEpoch === currentEpoch && acceptedEpoch === currentEpoch + 1
            : messageClass === 'proposal'
              ? parentEpoch === currentEpoch && acceptedEpoch === currentEpoch
              : parentEpoch == null && acceptedEpoch === currentEpoch;
        if (!validEpoch) {
          return {
            error: 'mls_epoch_conflict',
            currentEpoch,
            nextSequence: Number(state.next_sequence),
          };
        }
        const id = `mls_${crypto.randomBytes(16).toString('base64url')}`;
        const sequence = Number(state.next_sequence);
        const createdAt = nowIso();
        if (event?.targetEventId) {
          const target = db.prepare(`
            SELECT event_id, channel_id, sender_user_id, event_kind
            FROM encrypted_message_events
            WHERE event_id = ?
          `).get(event.targetEventId);
          if (!target || Number(target.channel_id) !== channelId) {
            const invalidReference = new Error(
              'Invalid encrypted event reference.',
            );
            invalidReference.code = 'INVALID_ENCRYPTED_EVENT_REFERENCE';
            throw invalidReference;
          }
          const targetKinds =
            event.kind === 'edit'
              ? ['message']
              : ['message', 'attachment'];
          if (!targetKinds.includes(target.event_kind)) {
            const invalidReference = new Error(
              'Invalid encrypted event root reference.',
            );
            invalidReference.code = 'INVALID_ENCRYPTED_EVENT_REFERENCE';
            throw invalidReference;
          }
          if (
            event.kind === 'edit' &&
            Number(target.sender_user_id) !== Number(req.auth.user.id)
          ) {
            const forbidden = new Error('Encrypted edit is not authorized.');
            forbidden.code = 'FORBIDDEN_ENCRYPTED_EVENT_MUTATION';
            throw forbidden;
          }
          if (
            event.kind === 'delete' &&
            Number(target.sender_user_id) !== Number(req.auth.user.id) &&
            req.auth.user.role !== 'owner'
          ) {
            const forbidden = new Error('Encrypted delete is not authorized.');
            forbidden.code = 'FORBIDDEN_ENCRYPTED_EVENT_MUTATION';
            throw forbidden;
          }
        }
        db.prepare(`
          INSERT INTO mls_delivery_messages (
            id, client_operation_id, channel_id, server_sequence,
            message_class, accepted_epoch, parent_epoch, uploader_user_id,
            uploader_device_id,
            recipient_device_id, wire_message, created_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        `).run(
          id,
          clientOperationId,
          channelId,
          sequence,
          messageClass,
          acceptedEpoch,
          parentEpoch,
          req.auth.user.id,
          uploaderDeviceId,
          recipientDeviceId,
          wireMessage,
          createdAt,
        );
        if (event) {
          db.prepare(`
            INSERT INTO encrypted_message_events (
              event_id, channel_id, delivery_message_id, server_sequence,
              sender_user_id, sender_device_id, event_kind, target_event_id,
              accepted_epoch, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          `).run(
            event.eventId,
            channelId,
            id,
            sequence,
            req.auth.user.id,
            uploaderDeviceId,
            event.kind,
            event.targetEventId,
            acceptedEpoch,
            createdAt,
          );
          if (event.encryptedAttachmentIds.length > 0) {
            const placeholders = event.encryptedAttachmentIds
              .map(() => '?')
              .join(',');
            const linked = db.prepare(`
              UPDATE encrypted_attachments
              SET event_id = ?
              WHERE id IN (${placeholders})
              AND channel_id = ?
              AND uploader_user_id = ?
              AND uploader_device_id = ?
              AND event_id IS NULL
              AND deleted_at IS NULL
              AND (expires_at IS NULL OR expires_at > ?)
            `).run(
              event.eventId,
              ...event.encryptedAttachmentIds,
              channelId,
              req.auth.user.id,
              uploaderDeviceId,
              createdAt,
            );
            if (linked.changes !== event.encryptedAttachmentIds.length) {
              const invalidReference = new Error(
                'Invalid encrypted attachment reference.',
              );
              invalidReference.code =
                'INVALID_ENCRYPTED_ATTACHMENT_REFERENCE';
              throw invalidReference;
            }
          }
        }
        db.prepare(`
          UPDATE mls_channel_state
          SET current_epoch = ?, next_sequence = ?, updated_at = ?
          WHERE channel_id = ?
        `).run(
          messageClass === 'commit' ? acceptedEpoch : currentEpoch,
          sequence + 1,
          createdAt,
          channelId,
        );
        return {
          row: db.prepare(`
          SELECT mls_delivery_messages.*, encrypted_message_events.event_id,
                 encrypted_message_events.event_kind,
                 encrypted_message_events.target_event_id
          FROM mls_delivery_messages
          LEFT JOIN encrypted_message_events
            ON encrypted_message_events.delivery_message_id =
               mls_delivery_messages.id
          WHERE mls_delivery_messages.id = ?
          `).get(id),
          replayed: false,
        };
      })();
      if (accepted.error) {
        return apiError(
          res,
          409,
          accepted.error,
          accepted.error === 'mls_group_not_initialized'
            ? 'The MLS group is not initialized.'
            : accepted.error === 'mls_operation_conflict'
              ? 'That MLS operation id was already used for different data.'
              : 'The MLS parent epoch was superseded.',
          accepted.currentEpoch == null
            ? {}
            : {
                currentEpoch: accepted.currentEpoch,
                nextSequence: accepted.nextSequence,
              },
        );
      }
      const serialized = serializeMlsDeliveryMessage(accepted.row);
      if (!accepted.replayed) {
        for (const liveSocket of io.sockets.sockets.values()) {
          if (
            !serialized.recipientDeviceId ||
            liveSocket.user.mediaDeviceId === serialized.recipientDeviceId
          ) {
            liveSocket.emit('mls:message', { message: serialized });
          }
        }
      }
      return res
        .status(accepted.replayed ? 200 : 201)
        .json({ ok: true, replayed: accepted.replayed, message: serialized });
    } catch (error) {
      if (error?.code === 'INVALID_ENCRYPTED_EVENT_REFERENCE') {
        return apiError(
          res,
          409,
          'invalid_encrypted_event_reference',
          'The encrypted event target does not exist in this channel.',
        );
      }
      if (error?.code === 'FORBIDDEN_ENCRYPTED_EVENT_MUTATION') {
        return apiError(
          res,
          403,
          'encrypted_event_mutation_forbidden',
          'That encrypted event change is not authorized.',
        );
      }
      if (error?.code === 'INVALID_ENCRYPTED_ATTACHMENT_REFERENCE') {
        return apiError(
          res,
          409,
          'invalid_encrypted_attachment_reference',
          'An encrypted attachment is unavailable or belongs to another sender.',
        );
      }
      if (String(error?.code || '').startsWith('SQLITE_CONSTRAINT')) {
        const foreignKey =
          String(error?.code || '') === 'SQLITE_CONSTRAINT_FOREIGNKEY';
        return apiError(
          res,
          409,
          foreignKey
            ? 'invalid_encrypted_event_reference'
            : 'duplicate_encrypted_event',
          foreignKey
            ? 'The encrypted event target does not exist.'
            : 'That encrypted event or delivery sequence already exists.',
        );
      }
      throw error;
    }
  },
);

app.get(
  '/api/channels/:channelId/mls/messages',
  authRequired,
  (req, res) => {
    const channelId = Number(req.params.channelId);
    const deviceId = req.auth.session.mediaDeviceId;
    const after = Number(req.query?.after || 0);
    const requestedLimit = Number(req.query?.limit || 100);
    const limit = Math.max(
      1,
      Math.min(200, Number.isFinite(requestedLimit) ? requestedLimit : 100),
    );
    if (
      !Number.isInteger(channelId) ||
      !deviceId ||
      !Number.isInteger(after) ||
      after < 0
    ) {
      return apiError(
        res,
        400,
        'invalid_mls_delivery_cursor',
        'Invalid MLS channel, device, or delivery cursor.',
      );
    }
    const state = db.prepare(`
      SELECT mls_channel_state.*
      FROM mls_channel_state
      JOIN channels ON channels.id = mls_channel_state.channel_id
      WHERE mls_channel_state.channel_id = ?
      AND channels.type = 'text'
      AND channels.encryption_mode = 'e2ee'
      AND channels.encryption_version = 1
    `).get(channelId);
    if (!state) {
      return apiError(
        res,
        409,
        'mls_group_not_initialized',
        'The encrypted channel MLS group is not initialized.',
      );
    }
    const rows = db.prepare(`
      SELECT mls_delivery_messages.*, encrypted_message_events.event_id,
             encrypted_message_events.event_kind,
             encrypted_message_events.target_event_id
      FROM mls_delivery_messages
      LEFT JOIN encrypted_message_events
        ON encrypted_message_events.delivery_message_id =
           mls_delivery_messages.id
      WHERE mls_delivery_messages.channel_id = ?
      AND mls_delivery_messages.server_sequence > ?
      AND (
        mls_delivery_messages.message_class != 'welcome'
        OR mls_delivery_messages.recipient_device_id = ?
      )
      ORDER BY mls_delivery_messages.server_sequence ASC
      LIMIT ?
    `).all(channelId, after, deviceId, limit);
    const deliveredSequence =
      rows.length === 0
        ? after
        : Number(rows[rows.length - 1].server_sequence);
    if (rows.length > 0) {
      db.prepare(`
        INSERT INTO mls_device_cursors (
          channel_id, device_id, delivered_sequence,
          acknowledged_sequence, acknowledged_epoch, updated_at
        )
        VALUES (?, ?, ?, 0, 0, ?)
        ON CONFLICT(channel_id, device_id) DO UPDATE SET
          delivered_sequence = MAX(
            mls_device_cursors.delivered_sequence,
            excluded.delivered_sequence
          ),
          updated_at = excluded.updated_at
      `).run(channelId, deviceId, deliveredSequence, nowIso());
    }
    return res.json({
      ok: true,
      group: {
        groupId: state.group_id,
        currentEpoch: Number(state.current_epoch),
        nextSequence: Number(state.next_sequence),
      },
      messages: rows.map(serializeMlsDeliveryMessage),
      deliveredSequence,
    });
  },
);

app.post(
  '/api/channels/:channelId/mls/ack',
  authRequired,
  accountMutationRateLimit,
  (req, res) => {
    const channelId = Number(req.params.channelId);
    const deviceId = req.auth.session.mediaDeviceId;
    const acknowledgedSequence = Number(req.body?.acknowledgedSequence);
    const acknowledgedEpoch = Number(req.body?.acknowledgedEpoch);
    if (
      !Number.isInteger(channelId) ||
      !deviceId ||
      !Number.isInteger(acknowledgedSequence) ||
      acknowledgedSequence < 0 ||
      !Number.isInteger(acknowledgedEpoch) ||
      acknowledgedEpoch < 0
    ) {
      return apiError(
        res,
        400,
        'invalid_mls_acknowledgement',
        'Invalid MLS delivery acknowledgement.',
      );
    }
    const result = db.transaction(() => {
      const state = db
        .prepare('SELECT * FROM mls_channel_state WHERE channel_id = ?')
        .get(channelId);
      const cursor = db.prepare(`
        SELECT *
        FROM mls_device_cursors
        WHERE channel_id = ? AND device_id = ?
      `).get(channelId, deviceId);
      if (
        !state ||
        !cursor ||
        acknowledgedSequence > Number(cursor.delivered_sequence) ||
        acknowledgedSequence < Number(cursor.acknowledged_sequence) ||
        acknowledgedEpoch > Number(state.current_epoch) ||
        acknowledgedEpoch < Number(cursor.acknowledged_epoch)
      ) {
        return null;
      }
      db.prepare(`
        UPDATE mls_device_cursors
        SET acknowledged_sequence = ?, acknowledged_epoch = ?, updated_at = ?
        WHERE channel_id = ? AND device_id = ?
      `).run(
        acknowledgedSequence,
        acknowledgedEpoch,
        nowIso(),
        channelId,
        deviceId,
      );
      return {
        deliveredSequence: Number(cursor.delivered_sequence),
        acknowledgedSequence,
        acknowledgedEpoch,
      };
    })();
    if (!result) {
      return apiError(
        res,
        409,
        'mls_acknowledgement_conflict',
        'The acknowledgement is ahead of delivery or behind saved state.',
      );
    }
    return res.json({ ok: true, cursor: result });
  },
);

app.patch(
  '/api/users/me',
  authRequired,
  accountMutationRateLimit,
  (req, res) => {
  const user = req.auth.user;
  const patch = {};

  if (req.body && Object.prototype.hasOwnProperty.call(req.body, 'displayName')) {
    const rawDisplayName = req.body.displayName;
    if (rawDisplayName === null) {
      patch.displayName = null;
    } else if (typeof rawDisplayName !== 'string') {
      return apiError(
        res,
        400,
        'invalid_display_name',
        'displayName must be a string.',
      );
    } else {
      const cleaned = rawDisplayName.trim();
      if (cleaned.length < 2 || cleaned.length > 32) {
        return apiError(
          res,
          400,
          'invalid_display_name',
          'Display name must be 2-32 characters.',
        );
      }
      patch.displayName = cleaned;
    }
  }

  if (req.body && Object.prototype.hasOwnProperty.call(req.body, 'avatarUrl')) {
    const rawAvatarUrl = req.body.avatarUrl;
    if (rawAvatarUrl === null) {
      patch.avatarUrl = null;
    } else if (typeof rawAvatarUrl !== 'string') {
      return apiError(
        res,
        400,
        'invalid_avatar_url',
        'avatarUrl must be a string.',
      );
    } else {
      const cleaned = rawAvatarUrl.trim();
      if (!cleaned) {
        patch.avatarUrl = null;
      } else {
        if (cleaned.length > 1500000) {
          return apiError(
            res,
            400,
            'avatar_too_large',
            'Profile picture payload is too large.',
          );
        }
        if (
          !cleaned.startsWith('data:image/') &&
          !cleaned.startsWith('/uploads/') &&
          !/^https?:\/\//i.test(cleaned)
        ) {
          return apiError(
            res,
            400,
            'invalid_avatar_url',
            'avatarUrl must be an image data URI or image URL.',
          );
        }
        patch.avatarUrl = cleaned;
      }
    }
  }

  if (
    !Object.prototype.hasOwnProperty.call(patch, 'displayName') &&
    !Object.prototype.hasOwnProperty.call(patch, 'avatarUrl')
  ) {
    return apiError(
      res,
      400,
      'missing_profile_patch',
      'Nothing to update.',
    );
  }

  const updatedUser = updateUserProfile(db, user.id, patch);
  if (!updatedUser) {
    return apiError(res, 404, 'user_not_found', 'User was not found.');
  }

  const voicePresence = getVoicePresenceForUser(updatedUser.id);
  emitPresence();

  res.json({
    ok: true,
    user: serializeUser(updatedUser, {
      isOnline: getOnlineUserIds().has(updatedUser.id),
      voiceChannelId: voicePresence?.voiceChannelId || null,
      voiceJoinedAt: voicePresence?.voiceJoinedAt || null,
      voiceState: getVoiceMediaStateForUser(updatedUser.id),
    }),
  });
  },
);

app.post(
  '/api/auth/logout',
  authRequired,
  accountMutationRateLimit,
  (req, res) => {
  revokeSession(db, req.auth.token);
  disconnectSessionSockets(req.auth.session.id);
  res.json({ ok: true });
  },
);

app.get('/api/auth/sessions', authRequired, (req, res) => {
  const sessions = db
    .prepare(`
    SELECT id, device_name, created_at, last_seen_at, expires_at, idle_expires_at
    FROM sessions
    WHERE user_id = ?
    ORDER BY last_seen_at DESC, id DESC
    `)
    .all(req.auth.user.id)
    .map((row) => serializeSession(row, req.auth.session.id));

  res.json({ ok: true, sessions });
});

app.post(
  '/api/auth/session/rotate',
  authRequired,
  accountMutationRateLimit,
  (req, res) => {
  const token = crypto.randomBytes(32).toString('hex');
  const idleExpiresAt = nextIdleExpiry();
  db.prepare(`
  UPDATE sessions
  SET token = ?, last_seen_at = ?, idle_expires_at = ?
  WHERE id = ? AND user_id = ?
  `).run(
    sessionTokenStorageValue(token),
    nowIso(),
    idleExpiresAt,
    req.auth.session.id,
    req.auth.user.id,
  );

  res.json({ ok: true, token, idleExpiresAt });
  disconnectSessionSockets(req.auth.session.id);
  },
);

app.delete(
  '/api/auth/sessions/:sessionId',
  authRequired,
  accountMutationRateLimit,
  (req, res) => {
  const sessionId = Number(req.params.sessionId);
  if (!Number.isInteger(sessionId) || sessionId <= 0) {
    return apiError(res, 400, 'invalid_session_id', 'Invalid session id.');
  }

  const result = db
    .prepare('DELETE FROM sessions WHERE id = ? AND user_id = ?')
    .run(sessionId, req.auth.user.id);
  if (result.changes === 0) {
    return apiError(res, 404, 'session_not_found', 'Session not found.');
  }

  disconnectSessionSockets(sessionId);
  res.json({
    ok: true,
    revokedSessionId: toId(sessionId),
    revokedCurrent: sessionId === Number(req.auth.session.id),
  });
  },
);

function disconnectSessionSockets(sessionId) {
  for (const socket of io.sockets.sockets.values()) {
    if (Number(socket.user?.sessionId) === Number(sessionId)) {
      socket.disconnect(true);
    }
  }
}

app.get('/api/channels', authRequired, (_req, res) => {
  res.json({
    ok: true,
    channels: currentChannels(),
           voice: getVoiceState(),
  });
});

app.get('/api/channels/:channelId/messages', authRequired, (req, res) => {
  const channelId = Number(req.params.channelId);
  if (!Number.isSafeInteger(channelId) || channelId <= 0) {
    return apiError(res, 400, 'invalid_channel_id', 'Invalid channel id.');
  }

  const channel = db.prepare(`
    SELECT id, type, encryption_mode, encryption_version
    FROM channels
    WHERE id = ?
  `).get(channelId);
  if (!channel) {
    return apiError(res, 404, 'channel_not_found', 'Channel not found.');
  }
  if (channel.type !== 'text') {
    return apiError(
      res,
      400,
      'channel_not_text',
      'Messages can only be read from text channels.',
    );
  }
  if (rejectPlaintextForEncryptedChannel(res, channel)) {
    return;
  }

  const limitText = req.query.limit == null ? '50' : String(req.query.limit);
  const limit = Number(limitText);
  if (!/^[1-9][0-9]*$/.test(limitText) || !Number.isSafeInteger(limit) || limit > 100) {
    return apiError(
      res,
      400,
      'invalid_history_limit',
      'History limit must be an integer from 1 to 100.',
    );
  }

  let decodedCursor = null;
  if (req.query.cursor != null) {
    decodedCursor = decodeHistoryCursor(String(req.query.cursor), {
      channelId,
      userId: req.auth.user.id,
    });
    if (decodedCursor == null) {
      return apiError(
        res,
        400,
        'invalid_history_cursor',
        'History cursor is invalid for this account and channel.',
      );
    }
  }

  const historySelect = `
  SELECT
  messages.id,
  messages.channel_id,
  messages.user_id,
  messages.content,
  messages.created_at,
  messages.updated_at,
  users.username,
  users.role,
  users.yuid,
  users.yuid_public_key
  FROM messages
  JOIN users ON users.id = messages.user_id
  WHERE messages.channel_id = ?
  `;
  const direction = decodedCursor?.direction || 'before';
  const rows = decodedCursor == null
    ? db.prepare(`
  ${historySelect}
  ORDER BY messages.id DESC
  LIMIT ?
  `).all(channelId, limit + 1)
    : direction === 'before'
      ? db.prepare(`
  ${historySelect}
  AND messages.id < ?
  ORDER BY messages.id DESC
  LIMIT ?
  `).all(channelId, decodedCursor.messageId, limit + 1)
      : db.prepare(`
  ${historySelect}
  AND messages.id > ?
  ORDER BY messages.id ASC
  LIMIT ?
  `).all(channelId, decodedCursor.messageId, limit + 1);

  const hasMore = rows.length > limit;
  if (hasMore) {
    rows.pop();
  }
  if (direction === 'before') {
    rows.reverse();
  }

  const attachmentsMap = getAttachmentsForMessageIds(
    db,
    rows.map((row) => row.id),
  );

  res.json({
    ok: true,
    messages: rows.map((row) =>
    serializeMessage(
      row,
      attachmentsMap.get(Number(row.id)) || [],
      req.auth.user.id,
    ),
    ),
    page: {
      direction,
      hasMore,
      nextCursor:
        hasMore && rows.length > 0
          ? encodeHistoryCursor({
              channelId,
              messageId:
                direction === 'before'
                  ? rows[0].id
                  : rows[rows.length - 1].id,
              userId: req.auth.user.id,
              direction,
            })
          : null,
      forwardCursor:
        rows.length > 0
          ? encodeHistoryCursor({
              channelId,
              messageId: rows[rows.length - 1].id,
              userId: req.auth.user.id,
              direction: 'after',
            })
          : direction === 'after'
            ? String(req.query.cursor)
            : null,
      backwardCursor:
        rows.length > 0
          ? encodeHistoryCursor({
              channelId,
              messageId: rows[0].id,
              userId: req.auth.user.id,
              direction: 'before',
            })
          : null,
    },
  });
});

app.post(
  '/api/uploads/attachments',
  authRequired,
  uploadRateLimit,
  durableStorageRequired,
  uploadSingleAttachment,
         (req, res) => {
           const uploadedFile = req.file;
           const channelId = Number(req.body?.channelId);

           if (!uploadedFile) {
             return apiError(res, 400, 'missing_file', 'No file was uploaded.');
           }
           if (!requireDurableStorage(req, res, {
             uploadedFile,
             incomingBytes: 0,
           })) {
             return;
           }

           if (!Number.isInteger(channelId)) {
             fs.unlink(uploadedFile.path, () => {});
             return apiError(res, 400, 'invalid_channel_id', 'Invalid channel id.');
           }

           const channel = db.prepare(`
             SELECT id, type, encryption_mode, encryption_version
             FROM channels
             WHERE id = ?
           `).get(channelId);
           if (!channel || channel.type !== 'text') {
             fs.unlink(uploadedFile.path, () => {});
             return apiError(
               res,
               400,
               'channel_not_text',
               'Attachments can only be uploaded to text channels.',
             );
           }
           if (rejectPlaintextForEncryptedChannel(res, channel)) {
             fs.unlink(uploadedFile.path, () => {});
             return;
           }

           const settings = getServerSettings(db);
           const maxBytes = Number(settings.attachment_max_bytes);
           if (uploadedFile.size > maxBytes) {
             fs.unlink(uploadedFile.path, () => {});
             return apiError(
               res,
               400,
               'attachment_too_large',
               `File exceeds the current ${maxBytes} byte limit.`,
             );
           }

           const allowedTypes = safeJsonParse(settings.attachment_allowed_types_json, []);
           const mimeType = inferMimeType(uploadedFile);

           if (!isAllowedMimeType(mimeType, allowedTypes)) {
             fs.unlink(uploadedFile.path, () => {});
             return apiError(
               res,
               400,
               'attachment_type_not_allowed',
               `That file type is not allowed by this server. (${mimeType})`,
             );
           }

           const totalBytes = Number(getAttachmentTotalBytes(db) || 0);
           if (
             totalBytes + uploadedFile.size >
             Number(settings.file_storage_max_total_bytes)
           ) {
             fs.unlink(uploadedFile.path, () => {});
             return apiError(
               res,
               400,
               'attachment_storage_limit_reached',
               'The server is out of attachment storage space.',
             );
           }

           const relativePath = path.relative(DATA_ROOT, uploadedFile.path);
           let attachment;
           try {
             attachment = createAttachment(db, {
               serverId,
               channelId,
               uploaderUserId: req.auth.user.id,
               kind: classifyAttachmentKind(mimeType),
               originalName: uploadedFile.originalname,
               storedName: uploadedFile.filename,
               relativePath,
               mimeType,
               sizeBytes: uploadedFile.size,
               createdAt: nowIso(),
               expiresAt: computeExpiresAt(
                 settings.attachment_retention_days,
               ),
             });
           } catch (error) {
             fs.unlink(uploadedFile.path, () => {});
             throw error;
           }

           res.status(201).json({
             ok: true,
             attachment: serializeAttachment(attachment, req.auth.user.id),
           });
         },
);

app.post(
  '/api/channels/:channelId/messages',
  authRequired,
  contentMutationRateLimit,
  durableStorageRequired,
  (req, res) => {
  const channelId = Number(req.params.channelId);
  if (!Number.isInteger(channelId)) {
    return apiError(res, 400, 'invalid_channel_id', 'Invalid channel id.');
  }

  const channel = db.prepare(`
    SELECT id, type, encryption_mode, encryption_version
    FROM channels
    WHERE id = ?
  `).get(channelId);
  if (!channel) {
    return apiError(res, 404, 'channel_not_found', 'Channel not found.');
  }
  if (channel.type !== 'text') {
    return apiError(
      res,
      400,
      'channel_not_text',
      'Messages can only be sent to text channels.',
    );
  }
  if (rejectPlaintextForEncryptedChannel(res, channel)) {
    return;
  }

  const content = String(req.body?.content || '').trim();
  const attachmentIds = Array.isArray(req.body?.attachmentIds)
  ? req.body.attachmentIds
  .map((value) => Number(value))
  .filter((value) => Number.isInteger(value))
  : [];

  if ((!content && attachmentIds.length === 0) || content.length > 2000) {
    return apiError(
      res,
      400,
      'invalid_message_length',
      'Message must contain text or attachments, and text must be 0-2000 characters.',
    );
  }

  for (const attachmentId of attachmentIds) {
    const pending = getPendingAttachmentById(db, attachmentId);
    if (
      !pending ||
      Number(pending.channel_id) !== channelId ||
      Number(pending.uploader_user_id) !== req.auth.user.id
    ) {
      return apiError(
        res,
        400,
        'invalid_attachment_reference',
        'One or more attachment ids are invalid.',
      );
    }
  }

  const createdAt = nowIso();
  const result = db.prepare(`
  INSERT INTO messages (channel_id, user_id, content, created_at)
  VALUES (?, ?, ?, ?)
  `).run(channelId, req.auth.user.id, content, createdAt);

  const messageId = Number(result.lastInsertRowid);
  linkAttachmentsToMessage(db, {
    attachmentIds,
    messageId,
    channelId,
    userId: req.auth.user.id,
  });

  const message = buildSerializedMessage(messageId, req.auth.user.id);

  for (const liveSocket of io.sockets.sockets.values()) {
    liveSocket.emit('message:new', {
      message: buildSerializedMessage(messageId, liveSocket.user.id),
    });
  }

  res.status(201).json({
    ok: true,
    message,
  });
  },
);

app.patch(
  '/api/channels/:channelId/messages/:messageId',
  authRequired,
  contentMutationRateLimit,
  (req, res) => {
  const channelId = Number(req.params.channelId);
  const messageId = Number(req.params.messageId);

  if (!Number.isInteger(channelId)) {
    return apiError(res, 400, 'invalid_channel_id', 'Invalid channel id.');
  }

  if (!Number.isInteger(messageId)) {
    return apiError(res, 400, 'invalid_message_id', 'Invalid message id.');
  }

  const existing = db.prepare(`
  SELECT messages.id, messages.channel_id, messages.user_id,
         channels.encryption_mode, channels.encryption_version
  FROM messages
  JOIN channels ON channels.id = messages.channel_id
  WHERE messages.id = ?
  `).get(messageId);

  if (!existing || Number(existing.channel_id) !== channelId) {
    return apiError(res, 404, 'message_not_found', 'Message not found.');
  }

  if (Number(existing.user_id) !== Number(req.auth.user.id)) {
    return apiError(
      res,
      403,
      'message_edit_forbidden',
      'You can only edit your own messages.',
    );
  }
  if (rejectPlaintextForEncryptedChannel(res, existing)) {
    return;
  }

  const content = String(req.body?.content || '').trim();
  const attachments = getAttachmentsForMessageIds(db, [messageId]).get(messageId) || [];

  if (!content && attachments.length === 0) {
    return apiError(
      res,
      400,
      'invalid_message_length',
      'Message must contain text or attachments.',
    );
  }

  if (content.length > 2000) {
    return apiError(
      res,
      400,
      'invalid_message_length',
      'Message text must be 0-2000 characters.',
    );
  }

  db.prepare(`
  UPDATE messages
  SET content = ?, updated_at = ?
  WHERE id = ?
  `).run(content, nowIso(), messageId);

  const message = buildSerializedMessage(messageId, req.auth.user.id);
  for (const liveSocket of io.sockets.sockets.values()) {
    liveSocket.emit('message:update', {
      message: buildSerializedMessage(messageId, liveSocket.user.id),
    });
  }

  res.json({
    ok: true,
    message,
  });
  },
);

app.delete(
  '/api/channels/:channelId/messages/:messageId',
  authRequired,
  contentMutationRateLimit,
  (req, res) => {
  const channelId = Number(req.params.channelId);
  const messageId = Number(req.params.messageId);

  if (!Number.isInteger(channelId)) {
    return apiError(res, 400, 'invalid_channel_id', 'Invalid channel id.');
  }

  if (!Number.isInteger(messageId)) {
    return apiError(res, 400, 'invalid_message_id', 'Invalid message id.');
  }

  const existing = db.prepare(`
  SELECT id, channel_id, user_id
  FROM messages
  WHERE id = ?
  `).get(messageId);

  if (!existing || Number(existing.channel_id) !== channelId) {
    return apiError(res, 404, 'message_not_found', 'Message not found.');
  }

  const canDelete =
    Number(existing.user_id) === Number(req.auth.user.id) || isOwner(req.auth.user);

  if (!canDelete) {
    return apiError(
      res,
      403,
      'message_delete_forbidden',
      'You can only delete your own messages unless you are the owner.',
    );
  }

  const deletedAt = nowIso();
  const attachments = getAttachmentsForMessageIds(db, [messageId]).get(messageId) || [];

  db.transaction(() => {
    for (const attachment of attachments) {
      markAttachmentDeleted(db, attachment.id, deletedAt);
    }

    db.prepare('DELETE FROM messages WHERE id = ?').run(messageId);
  })();

  for (const attachment of attachments) {
    removeAttachmentFile(attachment.relative_path);
  }

  io.emit('message:delete', {
    channelId: toId(channelId),
    messageId: toId(messageId),
  });

  res.json({
    ok: true,
    channelId: toId(channelId),
    messageId: toId(messageId),
  });
  },
);

app.get('/api/members', authRequired, (_req, res) => {
  res.json({
    ok: true,
    members: getMemberList(),
           voice: getVoiceState(),
  });
});

app.get('/api/presence', authRequired, (_req, res) => {
  res.json({
    ok: true,
    members: getMemberList(),
           voice: getVoiceState(),
  });
});

app.patch(
  '/api/admin/server',
  authRequired,
  ownerOnly,
  accountMutationRateLimit,
  (req, res) => {
  const current = getServerConfig(db);
  const name =
  typeof req.body?.name === 'string' ? req.body.name.trim() : current.name;
  const description =
  typeof req.body?.description === 'string'
  ? req.body.description.trim()
  : current.description;

  const currentBranding = safeJsonParse(current.branding_json, {});
  const nextBranding = {
    ...currentBranding,
    ...(typeof req.body?.branding === 'object' && req.body.branding
    ? req.body.branding
    : {}),
  };

  if (name.length < 2 || name.length > 60) {
    return apiError(
      res,
      400,
      'invalid_server_name',
      'Server name must be 2-60 characters.',
    );
  }

  if (description.length < 2 || description.length > 180) {
    return apiError(
      res,
      400,
      'invalid_server_description',
      'Description must be 2-180 characters.',
    );
  }

  db.prepare(`
  UPDATE server_config
  SET name = ?, description = ?, branding_json = ?, updated_at = ?
  WHERE id = 1
  `).run(name, description, JSON.stringify(nextBranding), nowIso());

  emitServerUpdated();

  res.json({
    ok: true,
    server: currentServer(),
  });
  },
);

app.post(
  '/api/admin/server/:slot',
  authRequired,
  ownerOnly,
  uploadRateLimit,
  brandingUpload.single('file'),
         (req, res) => {
           const slot =
           req.params.slot === 'banner'
           ? 'banner'
           : req.params.slot === 'icon'
           ? 'icon'
           : null;
           const uploadedFile = req.file;

           if (!slot) {
             if (uploadedFile) {
               fs.unlink(uploadedFile.path, () => {});
             }
             return apiError(
               res,
               400,
               'invalid_branding_slot',
               'Branding slot must be icon or banner.',
             );
           }

           if (!uploadedFile) {
             return apiError(
               res,
               400,
               'missing_file',
               'No branding file was uploaded.',
             );
           }

           const mimeType = inferMimeType(uploadedFile);
           if (!mimeType.startsWith('image/')) {
             fs.unlink(uploadedFile.path, () => {});
             return apiError(
               res,
               400,
               'invalid_branding_type',
               `Branding uploads must be image files. (${mimeType})`,
             );
           }

           const result = persistBrandingAsset(slot, uploadedFile);
           emitServerUpdated();

           res.status(201).json({
             ok: true,
             slot,
             assetUrl: result.assetUrl,
             server: result.server,
           });
         },
);

app.post(
  '/api/admin/channels',
  authRequired,
  ownerOnly,
  accountMutationRateLimit,
  (req, res) => {
  const name = String(req.body?.name || '').trim();
  const type = String(req.body?.type || '').trim().toLowerCase();

  if (!name || name.length < 2 || name.length > 40) {
    return apiError(
      res,
      400,
      'invalid_channel_name',
      'Channel name must be 2-40 characters.',
    );
  }

  if (!['text', 'voice'].includes(type)) {
    return apiError(
      res,
      400,
      'invalid_channel_type',
      'Channel type must be text or voice.',
    );
  }

  const existing = db
  .prepare('SELECT id FROM channels WHERE lower(name) = lower(?)')
  .get(name);
  if (existing) {
    return apiError(
      res,
      409,
      'channel_name_taken',
      'A channel with that name already exists.',
    );
  }

  const maxPosition = db
  .prepare('SELECT COALESCE(MAX(position), 0) AS value FROM channels')
  .get().value;
  const nextPosition = Number(maxPosition) + 1;
  const createdAt = nowIso();
  const encryptionMode = type === 'text' ? 'e2ee' : 'legacy';
  const encryptionVersion = type === 'text' ? 1 : 0;

  const result = db.prepare(`
  INSERT INTO channels (
    name, type, position, created_at, encryption_mode, encryption_version
  )
  VALUES (?, ?, ?, ?, ?, ?)
  `).run(
    name,
    type,
    nextPosition,
    createdAt,
    encryptionMode,
    encryptionVersion,
  );

  const channelRow = db
  .prepare(`
  SELECT id, name, type, position, glyph, created_at,
         encryption_mode, encryption_version
  FROM channels
  WHERE id = ?
  `)
  .get(result.lastInsertRowid);

  emitServerUpdated();

  res.status(201).json({
    ok: true,
    channel: serializeChannel(channelRow, currentServer().id),
                       channels: currentChannels(),
  });
  },
);

app.patch(
  '/api/admin/channels/:channelId',
  authRequired,
  ownerOnly,
  accountMutationRateLimit,
  (req, res) => {
  const channelId = Number(req.params.channelId);
  if (!Number.isInteger(channelId)) {
    return apiError(res, 400, 'invalid_channel_id', 'Invalid channel id.');
  }

  const existing = db
    .prepare(`
    SELECT id, name, type, position, glyph, created_at,
           encryption_mode, encryption_version
    FROM channels
    WHERE id = ?
    `)
    .get(channelId);

  if (!existing) {
    return apiError(res, 404, 'channel_not_found', 'Channel was not found.');
  }

  const patch = req.body ?? {};
  const hasName = Object.prototype.hasOwnProperty.call(patch, 'name');
  const hasGlyph = Object.prototype.hasOwnProperty.call(patch, 'glyph');
  const hasEncryptionMode = Object.prototype.hasOwnProperty.call(
    patch,
    'encryptionMode',
  );
  const hasEncryptionVersion = Object.prototype.hasOwnProperty.call(
    patch,
    'encryptionVersion',
  );

  if (hasEncryptionMode || hasEncryptionVersion) {
    return apiError(
      res,
      409,
      'channel_encryption_immutable',
      'A channel encryption boundary cannot be changed in place.',
    );
  }

  if (!hasName && !hasGlyph) {
    return apiError(
      res,
      400,
      'missing_channel_patch',
      'Nothing to update.',
    );
  }

  let nextName = existing.name;
  if (hasName) {
    const name = String(patch.name || '').trim();
    if (!name || name.length < 2 || name.length > 40) {
      return apiError(
        res,
        400,
        'invalid_channel_name',
        'Channel name must be 2-40 characters.',
      );
    }

    const duplicate = db
      .prepare('SELECT id FROM channels WHERE lower(name) = lower(?) AND id != ?')
      .get(name, channelId);
    if (duplicate) {
      return apiError(
        res,
        409,
        'channel_name_taken',
        'A channel with that name already exists.',
      );
    }

    nextName = name;
  }

  let nextGlyph = existing.glyph || null;
  if (hasGlyph) {
    const glyphResult = normalizeChannelGlyph(patch.glyph);
    if (!glyphResult.ok) {
      return apiError(
        res,
        glyphResult.status,
        glyphResult.code,
        glyphResult.message,
      );
    }
    nextGlyph = glyphResult.value;
  }

  db.prepare(`
  UPDATE channels
  SET name = ?, glyph = ?
  WHERE id = ?
  `).run(nextName, nextGlyph, channelId);

  const channelRow = db
    .prepare(`
    SELECT id, name, type, position, glyph, created_at,
           encryption_mode, encryption_version
    FROM channels
    WHERE id = ?
    `)
    .get(channelId);

  emitServerUpdated();

  res.json({
    ok: true,
    channel: serializeChannel(channelRow, currentServer().id),
    channels: currentChannels(),
  });
  },
);

app.delete(
  '/api/admin/channels/:channelId',
  authRequired,
  ownerOnly,
  accountMutationRateLimit,
  (req, res) => {
  const channelId = Number(req.params.channelId);
  if (!Number.isInteger(channelId)) {
    return apiError(res, 400, 'invalid_channel_id', 'Invalid channel id.');
  }

  const channel = db
    .prepare('SELECT id, name, type FROM channels WHERE id = ?')
    .get(channelId);
  if (!channel) {
    return apiError(res, 404, 'channel_not_found', 'Channel was not found.');
  }

  const attachments = db
    .prepare('SELECT relative_path FROM attachments WHERE channel_id = ?')
    .all(channelId);

  db.transaction(() => {
    db.prepare('DELETE FROM attachments WHERE channel_id = ?').run(channelId);
    db.prepare('DELETE FROM messages WHERE channel_id = ?').run(channelId);
    db.prepare('DELETE FROM channels WHERE id = ?').run(channelId);
  })();

  for (const attachment of attachments) {
    removeAttachmentFile(attachment.relative_path);
  }

  let presenceChanged = false;
  for (const [socketId, presence] of socketPresence.entries()) {
    if (Number(presence.voiceChannelId) !== channelId) {
      continue;
    }
    presence.voiceChannelId = null;
    presence.voiceJoinedAt = null;
    presence.voiceState = sanitizeVoiceMediaState();
    socketPresence.set(socketId, presence);
    presenceChanged = true;
  }

  if (presenceChanged) {
    emitPresence();
  }
  emitServerUpdated();

  res.json({
    ok: true,
    deletedChannelId: toId(channelId),
    channels: currentChannels(),
  });
  },
);

app.get('/api/admin/bans', authRequired, ownerOnly, (_req, res) => {
  res.json({
    ok: true,
    bans: currentBans(),
  });
});

app.post(
  '/api/admin/bans',
  authRequired,
  ownerOnly,
  accountMutationRateLimit,
  (req, res) => {
  const targetUserId = Number(req.body?.userId);
  const reason = String(req.body?.reason || '').trim();

  if (!Number.isInteger(targetUserId)) {
    return apiError(
      res,
      400,
      'invalid_user_id',
      'A valid userId is required to ban a user.',
    );
  }

  if (Number(targetUserId) === Number(req.auth.user.id)) {
    return apiError(
      res,
      400,
      'cannot_ban_self',
      'You cannot ban yourself.',
    );
  }

  const targetUser = db.prepare(`
  SELECT id, username, display_name, role, yuid
  FROM users
  WHERE id = ?
  `).get(targetUserId);
  if (!targetUser) {
    return apiError(
      res,
      404,
      'user_not_found',
      'That user could not be found.',
    );
  }

  if (targetUser.role === 'owner') {
    return apiError(
      res,
      403,
      'cannot_ban_owner',
      'The server owner cannot be banned.',
    );
  }

  const ban = createBan(db, {
    userId: targetUser.id,
    yuid: targetUser.yuid || null,
    usernameSnapshot: targetUser.username,
    reason,
    createdByUserId: req.auth.user.id,
  });

  clearSessionsForUser(targetUser.id);
  disconnectUserSockets(targetUser.id);
  emitPresence();
  emitServerUpdated();

  res.status(201).json({
    ok: true,
    ban: serializeBan(ban),
    bans: currentBans(),
  });
  },
);

app.delete(
  '/api/admin/bans/:banId',
  authRequired,
  ownerOnly,
  accountMutationRateLimit,
  (req, res) => {
  const banId = Number(req.params?.banId);
  if (!Number.isInteger(banId)) {
    return apiError(
      res,
      400,
      'invalid_ban_id',
      'A valid ban id is required.',
    );
  }

  const existing = getAllActiveBans(db).find((row) => Number(row.id) === banId);
  if (!existing) {
    return apiError(
      res,
      404,
      'ban_not_found',
      'That ban could not be found.',
    );
  }

  const revoked = revokeBan(db, banId);
  emitServerUpdated();

  res.json({
    ok: true,
    ban: serializeBan(revoked),
    bans: currentBans(),
  });
  },
);

io.use((socket, next) => {
  if (!allowSocketConnection(socket)) {
    return next(new Error('Too many realtime connection attempts.'));
  }
  const token = socket.handshake.auth?.token;
  if (!token) {
    return next(new Error('Missing auth token.'));
  }

  const row = getSessionWithUser(db, token);
  if (!row) {
    return next(new Error('Invalid auth token.'));
  }

  const activeBan = getActiveBanForIdentity({
    userId: row.user_id,
    yuid: row.yuid || null,
  });
  if (activeBan) {
    revokeSession(db, token);
    return next(new Error('This account or YUID is banned from this server.'));
  }
  if (row.media_device_id && row.media_device_revoked_at) {
    revokeSession(db, token);
    return next(new Error('This media device identity has been revoked.'));
  }

  touchSession(db, token, nextIdleExpiry());
  socket.user = {
    id: row.user_id,
    username: row.username,
    role: row.role,
    yuid: row.yuid || null,
    yuidVerified: Boolean(row.yuidVerified || (row.yuid && row.yuid_public_key)),
    sessionId: row.session_id,
    mediaDeviceId: row.media_device_id || null,
    mediaPublicKey: row.media_device_public_key || null,
    token,
  };
  next();
});

io.on('connection', (socket) => {
  socketPresence.set(socket.id, {
    userId: socket.user.id,
    username: socket.user.username,
    mediaDeviceId: socket.user.mediaDeviceId,
    voiceChannelId: null,
    voiceJoinedAt: null,
    voiceState: sanitizeVoiceMediaState(),
  });
  onlineUsersById.set(toId(socket.user.id), socket.id);
  emitPresence();

  socket.emit('server:hello', {
    server: currentServer(),
              channels: currentChannels(),
              settings: currentSettings(),
              voice: getVoiceState(),
              me: {
                id: toId(socket.user.id),
              username: socket.user.username,
              name: socket.user.username,
              role: socket.user.role,
              voiceState: getVoiceMediaStateForUser(socket.user.id),
              },
              members: getMemberList(),
              bans: socket.user.role === 'owner' ? currentBans() : [],
  });

  socket.on('presence:ping', () => {
    if (!allowSocketEvent(socket, 'control', socketControlLimit)) return;
    touchSession(db, socket.user.token, nextIdleExpiry());
  });

  socket.on('voice:join', (payload = {}, ack) => {
    if (!allowSocketEvent(socket, 'control', socketControlLimit, ack)) return;
    if (!socket.user.mediaDeviceId || !socket.user.mediaPublicKey) {
      ack?.({
        ok: false,
        error: {
          code: 'media_device_required',
          message: 'Register this device before joining voice.',
        },
      });
      return;
    }
    const channelId = Number(payload.channelId);
    if (!Number.isInteger(channelId)) {
      if (typeof ack === 'function') {
        ack({
          ok: false,
          error: {
            code: 'invalid_channel_id',
            message: 'Invalid voice channel id.',
          },
        });
      }
      return;
    }

    const channel = db
    .prepare('SELECT id, name, type FROM channels WHERE id = ?')
    .get(channelId);
    if (!channel || channel.type !== 'voice') {
      if (typeof ack === 'function') {
        ack({
          ok: false,
          error: {
            code: 'voice_channel_not_found',
            message: 'That voice deck does not exist.',
          },
        });
      }
      return;
    }

    const current = socketPresence.get(socket.id);
    if (!current) {
      if (typeof ack === 'function') {
        ack({
          ok: false,
          error: {
            code: 'presence_missing',
            message: 'Voice presence could not be updated.',
          },
        });
      }
      return;
    }

    const previousChannelId = current.voiceChannelId;
    const joiningSameDeck = Number(previousChannelId) === channelId;
    current.voiceChannelId = channelId;
    current.voiceJoinedAt = joiningSameDeck && current.voiceJoinedAt
    ? current.voiceJoinedAt
    : nowIso();
    current.voiceState = sanitizeVoiceMediaState(current.voiceState);
    socketPresence.set(socket.id, current);

    emitPresence();
    if (!joiningSameDeck && previousChannelId != null) {
      emitMediaRoomState(previousChannelId);
    }
    const mediaState = emitMediaRoomState(channelId);

    if (typeof ack === 'function') {
      ack({
        ok: true,
        channelId: toId(channelId),
        channelName: channel.name,
        joinedAt: current.voiceJoinedAt,
        mediaE2ee: mediaState
          ? {
              protocol: 'yappa-media-room-v1',
              serverId,
              channelId: toId(channelId),
              epoch: mediaState.epoch,
              membershipSequence: mediaState.membershipSequence,
              leaderDeviceId: mediaState.leaderDeviceId,
            }
          : null,
      });
    }
  });

  socket.on('voice:leave', (_payload = {}, ack) => {
    if (!allowSocketEvent(socket, 'control', socketControlLimit, ack)) return;
    const current = socketPresence.get(socket.id);
    if (!current) {
      if (typeof ack === 'function') {
        ack({
          ok: false,
          error: {
            code: 'presence_missing',
            message: 'Voice presence could not be updated.',
          },
        });
      }
      return;
    }

    const previousChannelId = current.voiceChannelId;
    current.voiceChannelId = null;
    current.voiceJoinedAt = null;
    current.voiceState = sanitizeVoiceMediaState(current.voiceState);
    socketPresence.set(socket.id, current);

    emitPresence();
    emitMediaRoomState(previousChannelId);

    if (typeof ack === 'function') {
      ack({ ok: true });
    }
  });

  socket.on('voice:state', (payload = {}, ack) => {
    if (!allowSocketEvent(socket, 'control', socketControlLimit, ack)) return;
    const current = socketPresence.get(socket.id);
    if (!current) {
      if (typeof ack === 'function') {
        ack({
          ok: false,
          error: {
            code: 'presence_missing',
            message: 'Voice presence could not be updated.',
          },
        });
      }
      return;
    }

    const nextVoiceState = mergeVoiceMediaState(
      current.voiceState,
      payload,
    );

    const changed = voiceMediaStateChanged(current.voiceState, nextVoiceState);
    current.voiceState = nextVoiceState;
    socketPresence.set(socket.id, current);

    if (changed) {
      emitPresence();
    }

    if (typeof ack === 'function') {
      ack({
        ok: true,
        voiceState: nextVoiceState,
      });
    }
  });

  socket.on('media:e2ee:envelope', (payload = {}, ack) => {
    if (!allowSocketEvent(socket, 'media-envelope', mediaEnvelopeLimit, ack)) {
      return;
    }
    const envelope = payload?.envelope;
    if (!validateMediaEnvelopePayload(envelope)) {
      ack?.({
        ok: false,
        error: {
          code: 'invalid_media_envelope',
          message: 'Invalid media key envelope.',
        },
      });
      return;
    }
    const presence = socketPresence.get(socket.id);
    const channelId = toId(envelope.channelId);
    if (
      !presence ||
      toId(presence.voiceChannelId) !== channelId ||
      socket.user.mediaDeviceId !== envelope.senderDeviceId
    ) {
      ack?.({
        ok: false,
        error: {
          code: 'media_envelope_sender_forbidden',
          message: 'The sender is not active in this encrypted room.',
        },
      });
      return;
    }
    const roomState = mediaRoomStates.get(channelId);
    if (!roomState || roomState.epoch !== envelope.epoch) {
      ack?.({
        ok: false,
        error: {
          code: 'stale_media_epoch',
          message: 'The media key envelope uses a stale room epoch.',
        },
      });
      return;
    }
    const members = activeMediaRoomMembers(channelId);
    const sender = members.find(
      (member) => member.device.id === envelope.senderDeviceId,
    );
    if (
      !sender ||
      roomState.leaderDeviceId !== envelope.senderDeviceId ||
      !verifyRelayedMediaEnvelope(envelope, sender.device)
    ) {
      ack?.({
        ok: false,
        error: {
          code: 'invalid_media_envelope_signature',
          message: 'The media key envelope authorization is invalid.',
        },
      });
      return;
    }
    const recipient = members.find(
      (member) => member.device.id === envelope.recipientDeviceId,
    );
    if (!recipient) {
      ack?.({
        ok: false,
        error: {
          code: 'media_envelope_recipient_forbidden',
          message: 'The recipient is not active in this encrypted room.',
        },
      });
      return;
    }
    const previousSequence =
      roomState.lastEnvelopeSequenceBySender.get(envelope.senderDeviceId) || 0;
    if (envelope.messageSequence <= previousSequence) {
      ack?.({
        ok: false,
        error: {
          code: 'replayed_media_envelope',
          message: 'The media key envelope sequence was already used.',
        },
      });
      return;
    }
    roomState.lastEnvelopeSequenceBySender.set(
      envelope.senderDeviceId,
      envelope.messageSequence,
    );
    io.to(recipient.socketId).emit('media:e2ee:envelope', { envelope });
    ack?.({ ok: true });
  });

  socket.on('voice:signal:offer', (payload = {}, ack) => {
    if (!allowSocketEvent(socket, 'signal', socketSignalLimit, ack)) return;
    try {
      const fromUserId = toId(socket.user.id);
      const { toUserId, channelId, sdp, type } = payload;

      if (!toUserId || !channelId || !sdp || !type) {
        ack?.({ ok: false, error: 'Missing offer payload.' });
        return;
      }

      const sourcePresence = getVoicePresenceForUser(socket.user.id);
      const targetPresence = getVoicePresenceForUser(toUserId);
      if (
        !sourcePresence ||
        !targetPresence ||
        toId(sourcePresence.voiceChannelId) !== toId(channelId) ||
        toId(targetPresence.voiceChannelId) !== toId(channelId)
      ) {
        ack?.({ ok: false, error: 'Users are not in the same voice deck.' });
        return;
      }

      const targetSocketId = onlineUsersById.get(toId(toUserId));
      if (!targetSocketId) {
        ack?.({ ok: false, error: 'Target user is offline.' });
        return;
      }

      io.to(targetSocketId).emit('voice:signal:offer', {
        fromUserId,
        channelId: toId(channelId),
                                 description: {
                                   type,
                                   sdp,
                                 },
      });

      ack?.({ ok: true });
    } catch (error) {
      logOperationalFailure('voice offer relay', error);
      ack?.({ ok: false, error: 'Failed to relay offer.' });
    }
  });

  socket.on('voice:signal:answer', (payload = {}, ack) => {
    if (!allowSocketEvent(socket, 'signal', socketSignalLimit, ack)) return;
    try {
      const fromUserId = toId(socket.user.id);
      const { toUserId, channelId, sdp, type } = payload;

      if (!toUserId || !channelId || !sdp || !type) {
        ack?.({ ok: false, error: 'Missing answer payload.' });
        return;
      }

      const sourcePresence = getVoicePresenceForUser(socket.user.id);
      const targetPresence = getVoicePresenceForUser(toUserId);
      if (
        !sourcePresence ||
        !targetPresence ||
        toId(sourcePresence.voiceChannelId) !== toId(channelId) ||
        toId(targetPresence.voiceChannelId) !== toId(channelId)
      ) {
        ack?.({ ok: false, error: 'Users are not in the same voice deck.' });
        return;
      }

      const targetSocketId = onlineUsersById.get(toId(toUserId));
      if (!targetSocketId) {
        ack?.({ ok: false, error: 'Target user is offline.' });
        return;
      }

      io.to(targetSocketId).emit('voice:signal:answer', {
        fromUserId,
        channelId: toId(channelId),
                                 description: {
                                   type,
                                   sdp,
                                 },
      });

      ack?.({ ok: true });
    } catch (error) {
      logOperationalFailure('voice answer relay', error);
      ack?.({ ok: false, error: 'Failed to relay answer.' });
    }
  });

  socket.on('voice:signal:ice-candidate', (payload = {}, ack) => {
    if (!allowSocketEvent(socket, 'signal', socketSignalLimit, ack)) return;
    try {
      const fromUserId = toId(socket.user.id);
      const { toUserId, channelId, candidate, sdpMid, sdpMLineIndex } = payload;

      if (!toUserId || !channelId || !candidate) {
        ack?.({ ok: false, error: 'Missing ICE payload.' });
        return;
      }

      const sourcePresence = getVoicePresenceForUser(socket.user.id);
      const targetPresence = getVoicePresenceForUser(toUserId);
      if (
        !sourcePresence ||
        !targetPresence ||
        toId(sourcePresence.voiceChannelId) !== toId(channelId) ||
        toId(targetPresence.voiceChannelId) !== toId(channelId)
      ) {
        ack?.({ ok: false, error: 'Users are not in the same voice deck.' });
        return;
      }

      const targetSocketId = onlineUsersById.get(toId(toUserId));
      if (!targetSocketId) {
        ack?.({ ok: false, error: 'Target user is offline.' });
        return;
      }

      io.to(targetSocketId).emit('voice:signal:ice-candidate', {
        fromUserId,
        channelId: toId(channelId),
                                 candidate: {
                                   candidate,
                                   sdpMid: sdpMid ?? null,
                                   sdpMLineIndex: sdpMLineIndex ?? null,
                                 },
      });

      ack?.({ ok: true });
    } catch (error) {
      logOperationalFailure('voice ICE relay', error);
      ack?.({
        ok: false,
        error: 'Failed to relay ICE candidate.',
      });
    }
  });

  socket.on('disconnect', () => {
    const previousChannelId = socketPresence.get(socket.id)?.voiceChannelId;
    socketPresence.delete(socket.id);
    if (onlineUsersById.get(toId(socket.user.id)) === socket.id) {
      onlineUsersById.delete(toId(socket.user.id));
    }
    emitPresence();
    emitMediaRoomState(previousChannelId);
  });
});

setInterval(() => {
  const expired = getExpiredAttachments(db, nowIso());
  const expiredEncrypted = db.prepare(`
    SELECT *
    FROM encrypted_attachments
    WHERE deleted_at IS NULL
    AND expires_at IS NOT NULL
    AND expires_at <= ?
    ORDER BY id ASC
    LIMIT 200
  `).all(nowIso());

  const deletedAt = nowIso();

  for (const attachment of [...expired, ...expiredEncrypted]) {
    const absolutePath = path.join(DATA_ROOT, attachment.relative_path);
    try {
      if (fs.existsSync(absolutePath)) {
        fs.unlinkSync(absolutePath);
      }
    } catch (error) {
      logOperationalFailure('expired attachment cleanup', error);
      continue;
    }

    if (String(attachment.id).startsWith('eatt_')) {
      db.prepare(`
        UPDATE encrypted_attachments
        SET deleted_at = ?
        WHERE id = ?
      `).run(deletedAt, attachment.id);
    } else {
      markAttachmentDeleted(db, attachment.id, deletedAt);
    }
  }
}, 5 * 60 * 1000);

app.use((error, _req, res, next) => {
  if (error?.code === 'cors_origin_denied') {
    return apiError(
      res,
      403,
      'cors_origin_denied',
      'This browser origin is not allowed by the server.',
    );
  }

  if (error?.type === 'entity.too.large') {
    return apiError(
      res,
      413,
      'request_body_too_large',
      'The request body exceeds this server limit.',
    );
  }

  if (error instanceof multer.MulterError) {
    if (error.code === 'LIMIT_FILE_SIZE') {
      return apiError(
        res,
        413,
        'file_too_large',
        'The uploaded file exceeds this server’s configured limit.',
      );
    }
    return apiError(
      res,
      400,
      'upload_error',
      'The multipart upload could not be processed.',
    );
  }

  if (
    error?.code === 'SQLITE_FULL' ||
    error?.code === 'SQLITE_IOERR_WRITE' ||
    error?.code === 'ENOSPC'
  ) {
    logOperationalFailure('durable storage write', error);
    res.setHeader('Retry-After', '60');
    return apiError(
      res,
      507,
      'durable_storage_unavailable',
      'The server cannot safely store another durable message right now.',
      {
        retryable: true,
        storageStatus: 'critical',
      },
    );
  }

  if (error) {
    const incidentId = crypto.randomUUID();
    console.error(
      `[server] Unexpected request failure (incident=${incidentId}, ` +
        `code=${safeOperationalErrorCode(error)}).`,
    );
    return apiError(
      res,
      500,
      'internal_error',
      'An internal server error occurred.',
      { incidentId },
    );
  }

  return next();
});

httpServer.listen(PORT, LISTEN_HOST, () => {
  console.log(`Yappa node listening on configured interface port ${PORT}.`);
  if (!configuredAttachmentSigningSecret) {
    console.warn(
      'Attachment signing is using an ephemeral key; links will be invalidated on restart.',
    );
  }
});
