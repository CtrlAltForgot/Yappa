# Yappa Server Portability and Parity

Last reviewed: 2026-07-28

## Product Contract

A Yappa server must expose the same protocol, security boundaries, migrations,
features, and administration behavior regardless of host operating system.
Linux and Windows packaging may use different launch/service wrappers, but
they must not become different server editions.

The intended setup experience is:

1. Install or unpack one supported Yappa server package.
2. Run one guided launcher.
3. Review or edit one documented configuration file.
4. Pass automated preflight checks.
5. Start the complete stack and receive a verified connection invitation.

The launcher must never invent weak production secrets, expose raw backend
ports, skip TLS, or claim success before health and connectivity checks pass.

## Current State

The canonical deployed stack is Linux-container based and includes:

- the Node backend and SQLite database;
- Caddy TLS/reverse proxy;
- LiveKit media/SFU and TURN/UDP;
- a host-network LAN discovery relay;
- persistent data, certificate, LiveKit, and backup volumes;
- hardened container users, capabilities, read-only filesystems, health
  checks, loopback-only internal ports, and encrypted backup tooling.

This stack is deployed and verified on Unraid. The backend JavaScript is
largely portable, but the complete server is not yet a supported Windows
deployment:

- the current Compose file uses Linux host networking for LAN discovery;
- backup, restore, domain/IP setup, and start helpers are shell scripts;
- Caddy/LiveKit networking and firewall behavior have not been validated on
  Docker Desktop, WSL2, or native Windows;
- no PowerShell installer, Windows service lifecycle, upgrade/rollback flow,
  or Windows backup verifier exists;
- the complete conformance suite has not run against separate Linux
  distributions or Windows.

## Supported-Host Target

### Tier 1: validated public-release hosts

- Ubuntu LTS x86-64
- Debian stable x86-64
- Fedora current x86-64
- a current RHEL-compatible distribution x86-64
- Unraid current x86-64
- Windows 11 x86-64 with the documented Linux-container/WSL2 prerequisites
- Windows Server current x86-64 through a supported native or Microsoft-backed
  Linux-container/WSL deployment path that does not require Docker Desktop

ARM64 Linux is a release target after every pinned image and native dependency
is verified for that architecture. Other OCI-capable Linux distributions can
be documented as best-effort only until their matrix passes.

### Canonical architecture

- Keep one versioned configuration schema and one set of container images,
  database migrations, HTTP/realtime/media protocols, and conformance tests.
- Use a base Compose application for the portable core, plus small,
  reviewable OS-specific overrides only for networking, filesystem ownership,
  service integration, and host discovery.
- Do not rely on Docker Desktop host networking for LAN discovery. Docker
  documents host networking as Linux-host functionality with an opt-in,
  layer-4-limited Desktop mode. A minimal signed host-native discovery helper
  or another verified cross-platform mechanism must advertise the same
  server-identity proof on Linux and Windows.
- Provide a native Windows route if Windows Server cannot support the canonical
  container path. It must run the identical backend version and migrations and
  pin/checksum Caddy, LiveKit, Node, and native dependencies; it may not be a
  reduced feature set.

## Installation and Configuration

- Provide `install-yappa.sh` and `Install-Yappa.ps1` as thin front ends to the
  same declarative install manifest and validation rules.
- Offer interactive prompts and unattended flags. Generate a local config from
  a versioned example, display every network/storage decision, and preserve
  user edits during upgrades.
- Separate ordinary settings from protected secrets. Enforce restrictive file
  permissions or Windows ACLs and redact secrets from output.
- Preflight CPU architecture, OS/version, available RAM/disk, clock
  synchronization, required ports, firewall reachability, virtualization/
  container support, DNS or direct-IP certificate prerequisites, filesystem
  semantics, and backup destination.
- Make install/start/stop/status/logs/backup/restore/verify/upgrade/rollback
  commands behave consistently on both operating systems.
- Installation is not successful until the backend, TLS route, WebSocket
  upgrade, LiveKit route, TURN listener, server-identity endpoint, LAN
  invitation where enabled, database schema, and writable persistent volumes
  pass health checks.

## Parity and Conformance

Every supported host runs the same black-box suite against a clean install and
an upgraded install:

- authentication, YUID proof, sessions, roles, bans, and abuse controls;
- channel/message/attachment and encrypted MLS delivery contracts;
- realtime reconnect and ordered catch-up;
- Caddy HTTPS/WSS routing and direct-IP/custom-domain modes;
- LiveKit token, media connection, TURN/UDP relay, and LAN discovery;
- backup, destructive isolated restore, migration, and rollback;
- restart persistence, storage-full behavior, log/secret checks, and
  permission/ACL checks;
- identical API capability/version documents and client-visible feature flags.

The matrix compares serialized contracts and observable behavior, not merely
whether processes start. Any unavoidable OS difference must be documented in
the installer and must not change user-facing features or security claims.

## Release Engineering

- Pin and checksum all downloaded installer inputs and container image digests.
- Produce signed installer archives plus SHA-256 checksums, SBOMs, provenance,
  and a machine-readable support matrix from the tagged commit.
- Test clean install, upgrade from the previous supported version, failed
  upgrade rollback, uninstall that preserves data by default, and restore onto
  another supported OS.
- Publish support windows and an explicit best-effort tier. Never describe an
  untested distribution or Windows configuration as supported.

Official Docker documentation checked on 2026-07-28 lists Docker Engine
installation paths for Ubuntu, Debian, Fedora, RHEL, and CentOS families and
includes Compose with Docker Desktop on Windows. It also states that host
networking is primarily a Linux-host capability and is opt-in and limited on
Docker Desktop, which is why Yappa cannot treat the current Linux discovery
container as Windows parity evidence. Recheck these constraints at each
supported tooling update.
