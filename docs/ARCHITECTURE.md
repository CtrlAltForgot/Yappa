# Architecture

Yappa has three primary runtime components:

- A Flutter desktop client for UI, local state, native capture, and client-held
  cryptographic operations.
- A Node.js/Express/Socket.IO backend for accounts, authorization, community
  state, realtime coordination, persistence, and deployment operations.
- LiveKit for voice/video/screen media routing, normally reached through the
  same trusted TLS origin terminated by Caddy.

SQLite and server-managed files provide persistent state. The canonical
self-hosted workload packages Caddy, the backend, LiveKit, and a bounded LAN
discovery relay. Public HTTPS/WSS transport, media encryption, message
encryption, and disk protection are separate security boundaries.

Detailed subsystem contracts: [persistent chat](architecture/PERSISTENT_CHAT.md),
[server portability](architecture/SERVER_PORTABILITY.md),
[screen sharing](platform/SCREEN_SHARING.md), and
[security plan](security/SECURITY_PLAN.md).

[Project home](../README.md) · [Documentation index](README.md)
