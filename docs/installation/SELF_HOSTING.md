# Self-Hosting

Yappa's current server path is an experimental canonical workload combining
the Node backend, SQLite/server-file persistence, LiveKit, Caddy, and LAN
discovery support. The production-like reference deployment is on Unraid, but
the repository also tests Linux host contracts. No signed public server bundle
is currently published.

Start with [server/README.md](../../server/README.md), then follow the detailed
[deployment guide](../../server/DEPLOYMENT.md) and
[migration/rollback contract](../../server/MIGRATIONS.md). Public hosting
requires deliberate TLS, firewall, router, storage, secret, backup, and restore
decisions. Never expose raw backend or private compatibility listeners.

[Project home](../../README.md) · [Documentation index](../README.md)
