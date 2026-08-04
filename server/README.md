# Yappa Server

The server provides account/session authentication, community and channel
state, authorization, message/attachment persistence, realtime Socket.IO
coordination, LiveKit token/key coordination, migrations, and operational
installation/backup tooling. SQLite and the `data/` tree are persistent state.

## Local development

Node.js 18 or newer is declared; CI uses Node.js `22.22.1`.

```bash
npm ci
cp .env.example .env
npm run dev
```

Review every example value and keep `.env` private. Direct development startup
is loopback-only by default and is not the supported public deployment path.

## Tests

```bash
npm ci
npm audit --omit=dev --audit-level=moderate
npm test
```

## Deployment and persistence

The canonical self-hosted path uses the repository installer and packaged
Docker/Caddy/LiveKit workload. Follow [DEPLOYMENT.md](DEPLOYMENT.md); do not
forward raw backend/private listeners. Persistent state includes `.env` and
`data/`, including SQLite, attachments, identity, and configuration. Use the
documented encrypted backup and isolated restore verification process.

Migrations are forward-only and transactional. Rollback means restoring the
matching encrypted pre-upgrade configuration and data with its matching
software revision—never opening a newer database with older software. See
[MIGRATIONS.md](MIGRATIONS.md).

## Security boundaries

The host operator controls server plaintext, metadata, credentials, backups,
and network exposure. Some encrypted-feed/media paths keep content keys at
clients, but have not completed independent review or all native validation.
Read the [public policy](../SECURITY.md) and
[detailed plan](../docs/security/SECURITY_PLAN.md).

[Project home](../README.md) · [Self-hosting overview](../docs/installation/SELF_HOSTING.md) ·
[Documentation index](../docs/README.md)
