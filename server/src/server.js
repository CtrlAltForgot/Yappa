require('dotenv').config();

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const path = require('path');
const express = require('express');
const cors = require('cors');
const bcrypt = require('bcryptjs');
const multer = require('multer');
const mime = require('mime-types');
const { Server } = require('socket.io');
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
  touchSession,
  touchUserLogin,
  touchUserYuid,
  updateServerSettings,
  updateUserProfile,
} = require('./db');
const { buildAuthMiddleware, getSessionWithUser } = require('./auth');

const PORT = Number(process.env.PORT || 4100);
const DEFAULT_SERVER_NAME = process.env.SERVER_NAME || 'Night Wire';
const DEFAULT_SERVER_DESCRIPTION =
process.env.SERVER_DESCRIPTION || 'quiet grid for testing strange ideas';
const DB_PATH =
process.env.DB_PATH || path.join(process.cwd(), 'data', 'newchat.db');
const DATA_ROOT =
process.env.DATA_ROOT || path.join(path.dirname(DB_PATH), 'servers');
const CORS_ORIGIN = process.env.CORS_ORIGIN || '*';
const LIVEKIT_URL = (process.env.LIVEKIT_URL || '').trim();
const LIVEKIT_PUBLIC_HOST = (process.env.LIVEKIT_PUBLIC_HOST || '').trim();
const LIVEKIT_PUBLIC_SCHEME = (process.env.LIVEKIT_PUBLIC_SCHEME || '').trim();
const LIVEKIT_SIGNAL_PORT = Number(process.env.LIVEKIT_SIGNAL_PORT || 7880);
const LIVEKIT_API_KEY = (process.env.LIVEKIT_API_KEY || '').trim();
const LIVEKIT_API_SECRET = (process.env.LIVEKIT_API_SECRET || '').trim();
const LIVEKIT_TOKEN_TTL = process.env.LIVEKIT_TOKEN_TTL || '12h';
const YUID_CHALLENGE_TTL_MS = Number(process.env.YUID_CHALLENGE_TTL_MS || 5 * 60 * 1000);

const db = createDb(DB_PATH, {
  serverName: DEFAULT_SERVER_NAME,
  serverDescription: DEFAULT_SERVER_DESCRIPTION,
});
const app = express();
const httpServer = http.createServer(app);
const io = new Server(httpServer, {
  cors: {
    origin: CORS_ORIGIN === '*' ? true : CORS_ORIGIN,
    credentials: false,
  },
});

app.use(cors({ origin: CORS_ORIGIN === '*' ? true : CORS_ORIGIN }));
app.use(express.json({ limit: '2mb' }));


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

function truncateText(value, maxLength) {
  const text = String(value || '').trim();
  if (!text) return '';
  return text.length > maxLength ? `${text.slice(0, maxLength - 1)}…` : text;
}

async function loadLinkPreview(url) {
  const cached = getCachedLinkPreview(url);
  if (cached) {
    return cached;
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), LINK_PREVIEW_TIMEOUT_MS);

  try {
    const response = await fetch(url, {
      redirect: 'follow',
      signal: controller.signal,
      headers: {
        'user-agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36 YappaLinkPreview/1.0',
        'accept': 'text/html,application/xhtml+xml,image/avif,image/webp,image/apng,*/*;q=0.8',
        'accept-language': 'en-US,en;q=0.9',
      },
    });

    const finalUrl = response.url || url;
    const parsedUrl = new URL(finalUrl);
    const contentType = String(response.headers.get('content-type') || '').toLowerCase();

    if (contentType.startsWith('image/')) {
      const preview = {
        url: finalUrl,
        domain: parsedUrl.hostname,
        siteName: parsedUrl.hostname,
        title: path.basename(parsedUrl.pathname) || parsedUrl.hostname,
        description: null,
        imageUrl: finalUrl,
        faviconUrl: null,
      };
      setCachedLinkPreview(url, preview);
      return preview;
    }

    const rawHtml = await response.text();
    const html = rawHtml.slice(0, 600000);

    const title = truncateText(
      extractMetaContent(html, ['og:title', 'twitter:title']) || extractTitle(html) || parsedUrl.hostname,
      180,
    );
    const description = truncateText(
      extractMetaContent(html, ['og:description', 'twitter:description', 'description']) || '',
      280,
    ) || null;
    const siteName = truncateText(
      extractMetaContent(html, ['og:site_name', 'application-name']) || parsedUrl.hostname,
      80,
    );

    const imageCandidate =
      extractMetaContent(html, ['og:image', 'og:image:url', 'og:image:secure_url', 'twitter:image', 'twitter:image:src', 'image']) ||
      extractLinkHref(html, ['image_src']) ||
      extractFirstImageSource(html);
    const faviconCandidate =
      extractLinkHref(html, ['icon']) ||
      '/favicon.ico';

    const preview = {
      url: finalUrl,
      domain: parsedUrl.hostname,
      siteName,
      title,
      description,
      imageUrl: resolveAbsoluteUrl(finalUrl, imageCandidate),
      faviconUrl: resolveAbsoluteUrl(finalUrl, faviconCandidate),
    };

    setCachedLinkPreview(url, preview);
    return preview;
  } finally {
    clearTimeout(timeout);
  }
}

const authRequired = buildAuthMiddleware(db);
const socketPresence = new Map();
const onlineUsersById = new Map();
const yuidChallenges = new Map();
const serverId = getServerConfig(db).server_id;
const serverRoot = path.join(DATA_ROOT, serverId);
const attachmentsRoot = path.join(serverRoot, 'attachments');
const sharedStorageRoot = path.join(serverRoot, 'storage', 'root');
const brandingRoot = path.join(serverRoot, 'branding');
const brandingIconRoot = path.join(brandingRoot, 'icon');
const brandingBannerRoot = path.join(brandingRoot, 'banner');

ensureDir(attachmentsRoot);
ensureDir(sharedStorageRoot);
ensureDir(brandingIconRoot);
ensureDir(brandingBannerRoot);

app.use(
  '/uploads',
  express.static(DATA_ROOT, {
    fallthrough: false,
    maxAge: '1h',
  }),
);

function toId(value) {
  return String(value);
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

function resolveLiveKitWebSocketUrl(req) {
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

  const rawHost = String(req.get('x-forwarded-host') || req.get('host') || '')
    .split(',')[0]
    .trim();
  const host = stripPortFromHost(rawHost) || '127.0.0.1';

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

migrateStoredYuids();

function serializeChannel(row, currentServerId) {
  return {
    id: toId(row.id),
    serverId: currentServerId,
    name: row.name,
    type: row.type,
    position: row.position,
    createdAt: row.created_at,
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
    console.error(
      'Failed to delete previous branding asset:',
      absolutePath,
      error.message,
    );
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

function serializeAttachment(row) {
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
    url: attachmentUrlFromRelativePath(row.relative_path),
    relativePath: row.relative_path,
    createdAt: row.created_at,
    expiresAt: row.expires_at,
    deletedAt: row.deleted_at,
  };
}

function serializeMessage(row, attachments = []) {
  return {
    id: toId(row.id),
    channelId: toId(row.channel_id),
    content: row.content,
    createdAt: row.created_at,
    author: {
      id: toId(row.user_id),
      username: row.username,
      name: row.username,
      role: row.role,
    yuid: row.yuid || null,
    yuidVerified: Boolean(row.yuidVerified || (row.yuid && row.yuid_public_key)),
    },
    attachments: attachments.map(serializeAttachment),
  };
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
          bans: currentBans(),
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

const upload = multer({ storage });

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

app.get('/health', (_req, res) => {
  res.json({
    ok: true,
    server: currentServer(),
           settings: currentSettings(),
           voice: getVoiceState(),
           time: nowIso(),
  });
});


app.get('/api/link-preview', authRequired, async (req, res) => {
  const url = normalizePreviewUrl(req.query?.url);
  if (!url) {
    return apiError(res, 400, 'invalid_url', 'A valid http or https URL is required.');
  }

  try {
    const preview = await loadLinkPreview(url);
    return res.json({ ok: true, preview });
  } catch (error) {
    return apiError(
      res,
      502,
      'link_preview_failed',
      error?.message || 'Could not load link preview.',
    );
  }
});

app.post('/api/voice/token', authRequired, async (req, res) => {
  if (!ensureLiveKitConfigured()) {
    return apiError(
      res,
      503,
      'voice_transport_unavailable',
      'Voice transport is not configured on this Yappa node.',
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
    identity: toId(req.auth.user.id),
    name: req.auth.user.username,
    ttl: LIVEKIT_TOKEN_TTL,
    metadata: JSON.stringify({
      userId: toId(req.auth.user.id),
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
    return apiError(
      res,
      500,
      'voice_token_failed',
      error.message || 'Could not create voice token.',
    );
  }
});

app.get('/api/server', (_req, res) => {
  res.json({
    ok: true,
    server: currentServer(),
           channels: currentChannels(),
           settings: currentSettings(),
           bans: req.auth.user.role === 'owner' ? currentBans() : [],
           voice: getVoiceState(),
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

app.patch('/api/server/settings', authRequired, ownerOnly, (req, res) => {
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
    if (!Number.isInteger(value) || value < 0 || value > 3650) {
      return apiError(
        res,
        400,
        'invalid_attachment_retention_days',
        'attachmentRetentionDays must be between 0 and 3650.',
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
});

app.get('/api/auth/yuid/challenge', (_req, res) => {
  res.json({
    ok: true,
    challenge: issueYuidChallenge(),
  });
});

app.post('/api/auth/session', async (req, res) => {
  const username = String(req.body?.username || '').trim();
  const password = String(req.body?.password || '');
  const usernameNormalized = username.toLowerCase();
  const yuidClaim = String(req.body?.yuid || '').trim();
  const yuidPublicKey = String(req.body?.yuidPublicKey || '').trim();
  const yuidSignature = String(req.body?.yuidSignature || '').trim();
  const yuidNonce = String(req.body?.yuidNonce || '').trim();


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
  }

  if (!user) {
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

    const passwordHash = await bcrypt.hash(password, 10);
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
      return apiError(
        res,
        401,
        'invalid_credentials',
        'Username or password is incorrect.',
      );
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

      if (needsRebind) {
        console.log(
          `[auth] Rebound YUID for @${user.username} on successful password login.`,
        );
      }
    } else {
      touchUserYuid(db, user.id, nowIso());
    }
  }

  const token = crypto.randomBytes(32).toString('hex');
  const createdAt = nowIso();
  db.prepare(`
  INSERT INTO sessions (token, user_id, created_at, last_seen_at)
  VALUES (?, ?, ?, ?)
  `).run(token, user.id, createdAt, createdAt);

  touchUserLogin(db, user.id, createdAt);
  const refreshedUser = db
  .prepare('SELECT id, username, role, display_name, avatar_url, created_at, last_login_at, yuid, yuid_public_key, yuid_bound_at, yuid_last_seen_at FROM users WHERE id = ?')
  .get(user.id);

  const voicePresence = getVoicePresenceForUser(refreshedUser.id);

  res.status(201).json({
    ok: true,
    token,
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

app.patch('/api/users/me', authRequired, (req, res) => {
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
});

app.post('/api/auth/logout', authRequired, (req, res) => {
  db.prepare('DELETE FROM sessions WHERE token = ?').run(req.auth.token);
  res.json({ ok: true });
});

app.get('/api/channels', (_req, res) => {
  res.json({
    ok: true,
    channels: currentChannels(),
           voice: getVoiceState(),
  });
});

app.get('/api/channels/:channelId/messages', authRequired, (req, res) => {
  const channelId = Number(req.params.channelId);
  if (!Number.isInteger(channelId)) {
    return apiError(res, 400, 'invalid_channel_id', 'Invalid channel id.');
  }

  const limitRaw = Number(req.query.limit || 50);
  const limit = Math.max(
    1,
    Math.min(100, Number.isFinite(limitRaw) ? limitRaw : 50),
  );

  const rows = db
  .prepare(`
  SELECT
  messages.id,
  messages.channel_id,
  messages.user_id,
  messages.content,
  messages.created_at,
  users.username,
  users.role
  FROM messages
  JOIN users ON users.id = messages.user_id
  WHERE messages.channel_id = ?
  ORDER BY messages.id DESC
  LIMIT ?
  `)
  .all(channelId, limit)
  .reverse();

  const attachmentsMap = getAttachmentsForMessageIds(
    db,
    rows.map((row) => row.id),
  );

  res.json({
    ok: true,
    messages: rows.map((row) =>
    serializeMessage(row, attachmentsMap.get(Number(row.id)) || []),
    ),
  });
});

app.post(
  '/api/uploads/attachments',
  authRequired,
  upload.single('file'),
         (req, res) => {
           const uploadedFile = req.file;
           const channelId = Number(req.body?.channelId);

           if (!uploadedFile) {
             return apiError(res, 400, 'missing_file', 'No file was uploaded.');
           }

           if (!Number.isInteger(channelId)) {
             fs.unlink(uploadedFile.path, () => {});
             return apiError(res, 400, 'invalid_channel_id', 'Invalid channel id.');
           }

           const channel = db.prepare('SELECT id, type FROM channels WHERE id = ?').get(channelId);
           if (!channel || channel.type !== 'text') {
             fs.unlink(uploadedFile.path, () => {});
             return apiError(
               res,
               400,
               'channel_not_text',
               'Attachments can only be uploaded to text channels.',
             );
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
           const attachment = createAttachment(db, {
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
                                               expiresAt: computeExpiresAt(settings.attachment_retention_days),
           });

           res.status(201).json({
             ok: true,
             attachment: serializeAttachment(attachment),
           });
         },
);

app.post('/api/channels/:channelId/messages', authRequired, (req, res) => {
  const channelId = Number(req.params.channelId);
  if (!Number.isInteger(channelId)) {
    return apiError(res, 400, 'invalid_channel_id', 'Invalid channel id.');
  }

  const channel = db.prepare('SELECT id, type FROM channels WHERE id = ?').get(channelId);
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

  const row = db
  .prepare(`
  SELECT
  messages.id,
  messages.channel_id,
  messages.user_id,
  messages.content,
  messages.created_at,
  users.username,
  users.role
  FROM messages
  JOIN users ON users.id = messages.user_id
  WHERE messages.id = ?
  `)
  .get(messageId);

  const attachmentsMap = getAttachmentsForMessageIds(db, [messageId]);
  const message = serializeMessage(row, attachmentsMap.get(messageId) || []);

  io.emit('message:new', { message });

  res.status(201).json({
    ok: true,
    message,
  });
});

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

app.patch('/api/admin/server', authRequired, ownerOnly, (req, res) => {
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
});

app.post(
  '/api/admin/server/:slot',
  authRequired,
  ownerOnly,
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

app.post('/api/admin/channels', authRequired, ownerOnly, (req, res) => {
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

  const result = db.prepare(`
  INSERT INTO channels (name, type, position, created_at)
  VALUES (?, ?, ?, ?)
  `).run(name, type, nextPosition, createdAt);

  const channelRow = db
  .prepare(`
  SELECT id, name, type, position, created_at
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
});

app.get('/api/admin/bans', authRequired, ownerOnly, (_req, res) => {
  res.json({
    ok: true,
    bans: currentBans(),
  });
});

app.post('/api/admin/bans', authRequired, ownerOnly, (req, res) => {
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
});

app.delete('/api/admin/bans/:banId', authRequired, ownerOnly, (req, res) => {
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
});

io.use((socket, next) => {
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
    db.prepare('DELETE FROM sessions WHERE token = ?').run(token);
    return next(new Error('This account or YUID is banned from this server.'));
  }

  touchSession(db, token);
  socket.user = {
    id: row.user_id,
    username: row.username,
    role: row.role,
    yuid: row.yuid || null,
    yuidVerified: Boolean(row.yuidVerified || (row.yuid && row.yuid_public_key)),
    token,
  };
  next();
});

io.on('connection', (socket) => {
  socketPresence.set(socket.id, {
    userId: socket.user.id,
    username: socket.user.username,
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
    touchSession(db, socket.user.token);
  });

  socket.on('voice:join', (payload = {}, ack) => {
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

    const joiningSameDeck = Number(current.voiceChannelId) === channelId;
    current.voiceChannelId = channelId;
    current.voiceJoinedAt = joiningSameDeck && current.voiceJoinedAt
    ? current.voiceJoinedAt
    : nowIso();
    current.voiceState = sanitizeVoiceMediaState(current.voiceState);
    socketPresence.set(socket.id, current);

    emitPresence();

    if (typeof ack === 'function') {
      ack({
        ok: true,
        channelId: toId(channelId),
          channelName: channel.name,
          joinedAt: current.voiceJoinedAt,
      });
    }
  });

  socket.on('voice:leave', (_payload = {}, ack) => {
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

    current.voiceChannelId = null;
    current.voiceJoinedAt = null;
    current.voiceState = sanitizeVoiceMediaState(current.voiceState);
    socketPresence.set(socket.id, current);

    emitPresence();

    if (typeof ack === 'function') {
      ack({ ok: true });
    }
  });

  socket.on('voice:state', (payload = {}, ack) => {
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

    const nextVoiceState = sanitizeVoiceMediaState({
      ...current.voiceState,
      micMuted: payload.micMuted,
      audioMuted: payload.audioMuted,
      cameraEnabled: payload.cameraEnabled,
      screenShareEnabled: payload.screenShareEnabled,
      speaking: payload.speaking,
    });

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

  socket.on('voice:signal:offer', (payload = {}, ack) => {
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
      ack?.({ ok: false, error: error.message || 'Failed to relay offer.' });
    }
  });

  socket.on('voice:signal:answer', (payload = {}, ack) => {
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
      ack?.({ ok: false, error: error.message || 'Failed to relay answer.' });
    }
  });

  socket.on('voice:signal:ice-candidate', (payload = {}, ack) => {
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
      ack?.({
        ok: false,
        error: error.message || 'Failed to relay ICE candidate.',
      });
    }
  });

  socket.on('disconnect', () => {
    socketPresence.delete(socket.id);
    if (onlineUsersById.get(toId(socket.user.id)) === socket.id) {
      onlineUsersById.delete(toId(socket.user.id));
    }
    emitPresence();
  });
});

setInterval(() => {
  const expired = getExpiredAttachments(db, nowIso());
  if (expired.length === 0) {
    return;
  }

  const deletedAt = nowIso();

  for (const attachment of expired) {
    const absolutePath = path.join(DATA_ROOT, attachment.relative_path);
    try {
      if (fs.existsSync(absolutePath)) {
        fs.unlinkSync(absolutePath);
      }
    } catch (error) {
      console.error(
        'Failed to delete expired attachment file:',
        absolutePath,
        error.message,
      );
      continue;
    }

    markAttachmentDeleted(db, attachment.id, deletedAt);
  }
}, 5 * 60 * 1000);

app.use((error, _req, res, next) => {
  if (error instanceof multer.MulterError) {
    if (error.code === 'LIMIT_FILE_SIZE') {
      return apiError(
        res,
        400,
        'file_too_large',
        'Uploaded file exceeds the 10 MB branding limit.',
      );
    }
    return apiError(res, 400, 'upload_error', error.message);
  }

  if (error) {
    console.error(error);
    return apiError(
      res,
      500,
      'internal_error',
      'An internal server error occurred.',
    );
  }

  return next();
});

httpServer.listen(PORT, () => {
  const server = currentServer();
  console.log(`Yappa node listening on http://127.0.0.1:${PORT}`);
  console.log(`Node name: ${server.name}`);
  console.log(`Server id: ${server.id}`);
  console.log(`DB path: ${DB_PATH}`);
  console.log(`Data root: ${DATA_ROOT}`);
});
