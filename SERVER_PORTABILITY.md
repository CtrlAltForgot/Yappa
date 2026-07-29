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

## Client “Create Server” Experience

The desktop client should make server creation feel native to Yappa rather
than sending every user to deployment documentation. “Create server” offers
two explicit paths backed by the same server release:

### Host on this computer

- The client installs or locates the canonical server package and supervises
  its lifecycle. The initial supported mode keeps the server running while the
  Yappa client is open and states clearly that closing Yappa makes the server
  unavailable.
- A later, explicit setting may install a tray/background supervisor and
  launch it at operating-system sign-in. Autostart is opt-in, reversible, and
  visible in both Yappa and the OS startup/service controls.
- The flow chooses a durable data location, shows expected disk/network use,
  performs port/firewall/TLS preflight, generates protected secrets, starts the
  stack, verifies every health boundary, and then adds the new server to the
  client.
- The server dashboard exposes running/degraded/stopped state, local and
  external reachability, current version, storage/headroom, last verified
  backup, logs with secret redaction, restart, backup, update, and safe stop.
- Sleep, hibernate, network changes, public-IP changes, client crashes,
  duplicate client launches, OS shutdown, port conflicts, partial startup,
  updates, and supervisor crashes require deterministic recovery behavior.
- Resource limits and a warning are required before hosting a large or public
  community on a workstation. A locally hosted server remains the same Yappa
  server and may later move to another supported host through verified backup
  and restore.

### Host on another computer

- The client asks for the remote operating system, distribution/version,
  architecture, container/native availability, domain or direct-IP choice,
  storage location, and intended LAN/public reachability.
- It generates a short, version-pinned installer command plus inspectable
  step-by-step instructions from the same release manifest. Commands must
  checksum the installer before execution and must not embed server secrets,
  client session tokens, passwords, or private SSH keys.
- The default flow never asks the user to paste a root/administrator password
  into Yappa and never executes remote privileged commands. A future managed
  SSH flow would require explicit authorization, host-key verification,
  least-privilege credentials, previewed actions, and reliable cleanup.
- After installation, the client accepts a signed invitation or connection
  proof and independently verifies TLS, server identity, protocol/capability
  compatibility, realtime, media, and ownership setup before adding the
  server.
- Unsupported host choices produce honest compatibility guidance rather than
  a best-guess command labeled as supported.

Both paths are generated from a machine-readable support/install manifest so
the client UI, documentation, release artifacts, and CI matrix cannot drift.

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

The first shared installation contract is now implemented in
`server/install-manifest.json` with a versioned JSON Schema and a security
validator in the backend suite. It centralizes the development release,
configuration/database schema versions, exact Tier-1 targets and validation
state, prerequisites, public/LAN/private ports, required capabilities, health
boundaries, artifact publication fields, and lifecycle command contract.
Because no signed server bundle exists, every artifact and public-support flag
is null/false and client install-command generation and local supervision are
disabled.

`server/install-yappa.sh` is the first thin Linux front end. It can preflight
the local x86-64 development server tree and, only with explicit
`--local-source`, dispatch the current start/stop/status/log/backup,
fresh-install restore, install-verification, and backup-verification
operations.
`server/Install-Yappa.ps1` currently implements prerequisite
preflight only and refuses every mutating lifecycle command. This is useful
foundation, not Windows support: remote download, artifact verification,
upgrade, rollback, uninstall, services, firewalls, cross-platform discovery,
and the conformance matrix remain open.

`.github/scripts/build-server-bundle.sh` now packages an explicit canonical
runtime allowlist into a normalized `tar.gz` with source/version metadata and a
SHA-256 sidecar. Tests require two builds with identical inputs to be
byte-identical, inspect the archive, reject secret/generated/development
content, verify the checksum and metadata, extract it, and run the bundled
non-mutating installer entry point. Security CI repeats the real bundle build.
This supplies the artifact shape for installers but is not publication:
signature, SBOM, provenance, tagged-release binding, support enablement, and
remote download remain open.

The Linux wrapper can also install a locally supplied development bundle plus
an explicit SHA-256 into a brand-new absolute directory. It validates the
archive root/metadata, rejects traversal, links and special files, refuses
merge/overwrite, applies a private root mode, and normally runs full preflight
before startup. Negative tests cover wrong digest, existing destination, and a
checksum-valid archive containing a symlink. This is the durable-layout
foundation only; checksums do not authenticate an attacker-controlled bundle,
so remote fetch stays disabled until detached signing is designed and shipped.

The Linux `verify` lifecycle now performs operational installation checks
instead of aliasing backup inspection. It verifies private storage/identity
modes, SQLite integrity and exact schema, persistent write access, all
canonical containers and backend health, a real Ed25519 server identity proof,
identity consistency through the configured LAN or TLS route, Socket.IO
WebSocket upgrade, and guarded LiveKit route reachability. `verify-backup`
retains isolated encrypted restore inspection. The manifest distinguishes the
implemented host checks from still-open LiveKit signaling, TURN, signed LAN
invitation, and outside-network evidence so the future client dashboard cannot
present partial verification as full health.

The Linux `restore` lifecycle now combines a checksum-pinned local bundle with
an encrypted backup only in a brand-new absolute directory. Decryption streams
into private staging rather than a plaintext archive; the operation rejects
links, special files, an unsafe or mismatched `DB_PATH`, multiple databases or
identities, SQLite corruption, and schemas newer than the selected bundle.
Runtime and state are assembled before one final rename and remain stopped for
configuration review. Integration tests cover a complete history/attachment
round trip, wrong checksum, existing destination, future schema, escaped
database path, malicious symlink, and staging cleanup. This is not yet a
cross-platform or production deployment claim.

The Linux `upgrade` lifecycle now requires a healthy current server, a new
encrypted recovery point that passes isolated verification, and a
checksum-pinned local candidate. It copies only stopped state into private
staging, rejects unsafe database paths and unsupported schemas, runs SQLite
integrity checks, switches directory names, and requires candidate startup and
operational verification. Failure restores and verifies the prior directory
while retaining the candidate for inspection. `rollback` likewise encrypts
and verifies the newer state before activating the retained old snapshot; it
keeps the newer installation as `.pre-rollback` rather than silently deleting
post-upgrade activity. Integration coverage proves successful upgrade,
explicit rollback, state preservation, and failed-candidate recovery. Windows
parity and real-host conformance remain open.

The Linux `uninstall` lifecycle is data-preserving by contract. It requires a
new encrypted backup and a separate fresh preservation destination, verifies
both current health and the encrypted recovery point, stops the stack, copies
only `.env` and `data/` with private modes, and removes runtime files only
after the preserved state is placed. It refuses unresolved rollback or failed
candidate directories instead of orphaning them. Tests cover successful
removal, state/permission preservation, existing-target refusal, retained
rollback refusal, and temporary-path cleanup. OS service and firewall removal
are required before runtime removal; user-systemd service removal is now
implemented, while firewall registration remains open.

Explicit Linux sign-in autostart is now implemented for hosts with a per-user
systemd manager. Registration is rejected as root, uses only
`systemctl --user`, creates one deterministic mode-`0600` unit per installation,
and never enables lingering or mutates a firewall. The unit starts through the
canonical lifecycle, must pass the operational verifier, stops cleanly when
disabled, is visible in OS controls, and is completely removable without
deleting data. Duplicate and failed registration cleanly refuse/remove state.
All four containers use `restart: unless-stopped` for unexpected process and
Docker-daemon recovery. Automated tests prove unit hardening, path quoting,
opt-in registration/status/removal, duplicate refusal, failed-enable cleanup,
and uninstall refusal while registered. Unraid, Windows, unattended boot,
sleep/network recovery, and unhealthy-but-running remediation remain open.

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
  same declarative install manifest and validation rules. The manifest and
  initial front ends exist; only the source-tree Linux lifecycle subset is
  currently implemented.
- Publish that manifest for the client’s “Create server” wizard, including
  exact supported hosts, prerequisites, artifact URLs/digests, configuration
  schema, capabilities, health checks, and upgrade compatibility.
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
- Test client-supervised local hosting, explicit tray/autostart registration
  and removal, remote-command generation for every Tier-1 host, and connection
  verification against the installed server.
- Publish support windows and an explicit best-effort tier. Never describe an
  untested distribution or Windows configuration as supported.

Official Docker documentation checked on 2026-07-28 lists Docker Engine
installation paths for Ubuntu, Debian, Fedora, RHEL, and CentOS families and
includes Compose with Docker Desktop on Windows. It also states that host
networking is primarily a Linux-host capability and is opt-in and limited on
Docker Desktop, which is why Yappa cannot treat the current Linux discovery
container as Windows parity evidence. Recheck these constraints at each
supported tooling update.
