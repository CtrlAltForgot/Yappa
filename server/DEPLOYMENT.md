# Yappa Server Deployment

The server bundle includes the application backend, LiveKit, and Caddy. Caddy
is the only reverse proxy required and stores its automatically managed
certificates in the persistent `caddy_data` Docker volume.

## Development install entry point

The locally present development server tree now has one Linux lifecycle front
end:

```bash
./install-yappa.sh preflight
./install-yappa.sh install --local-source
```

Use `--lan` after `--local-source` for private-network-only development. The
preflight checks the current x86-64, memory, disk, Docker Compose, backup, and
restore prerequisites before startup. It also dispatches `start`, `stop`,
`status`, `logs`, `backup`, `restore`, `verify`, and `verify-backup` to the
implemented hardened operations.

This is not a remote public installer. `install-manifest.json` is explicitly
an unpublished development manifest: it has no artifact URL, checksum,
signature, release-validated host, client command-generation permission, or
client-supervision permission. The wrapper requires an explicit
`--local-source` flag and otherwise fails closed. Do not copy a command from a
development checkout and describe it as a supported one-click install.

`Install-Yappa.ps1` now runs preflight and the implemented canonical lifecycle
inside one explicit WSL2 distribution. Development install/restore requires a
local bundle, full SHA-256, and a new absolute Linux path outside `/mnt`; later
commands require that same `-InstallDirectory`. Windows bundle and encrypted
backup paths are converted without shell-string interpolation. This remains an
unpublished bridge contract, not Windows support: real WSL2 Docker operation,
Windows service and firewall integration, signed artifacts, and the Windows
11/Windows Server conformance matrices are still required.

## Development server bundle

Release CI builds the canonical server tree with:

```bash
.github/scripts/build-server-bundle.sh
```

The script stages an explicit runtime allowlist, creates normalized build
metadata containing the development version, full source commit, and source
timestamp, and emits a deterministic `tar.gz` plus a SHA-256 file under
`dist/server/`. Ownership, order, timestamps, and gzip headers are normalized.
It refuses overwrite and rejects generated `.env`, LiveKit credentials,
databases, data, backups, dependencies, tests, and common private-key/token
markers. The backend suite builds the same inputs twice and requires
byte-identical output, verifies the checksum and metadata, extracts the bundle,
and executes its non-mutating installer help path.

The checksum is an integrity input, not release authenticity. This development
bundle is unsigned and the install manifest remains unpublished. A public
release still requires a detached signature, SBOM, trusted provenance, and
release-manifest publication from the tagged commit.

For local development testing, an already-built bundle can be installed into
a new private directory without merging into an existing server:

```bash
./install-yappa.sh install \
  --local-bundle /path/yappa-server-0.1.0-dev.tar.gz \
  --sha256 FULL_LOWERCASE_SHA256 \
  --install-dir /absolute/new/yappa-server
```

The installer verifies the digest before extraction, requires one matching
versioned archive root and build metadata, rejects traversal, links and special
files, refuses every existing destination, and sets the new root to mode
`0700`. It then runs the normal preflight and starts the installed server.
`--no-start` exists for isolated packaging/conformance tests and leaves an
explicitly unverified runtime state. A failed checksum or unsafe bundle creates
no install directory.

## Verify a running installation

Run:

```bash
./install-yappa.sh verify
```

This is operational verification, not backup verification. It requires:

- mode `0600` configuration and persistent identity plus mode `0700` data;
- the database inside the data root at the manifest schema with SQLite
  `quick_check` success;
- writable persistent storage and exactly one server identity;
- all four canonical services running and a healthy backend container;
- a cryptographically valid Ed25519 identity proof from the backend;
- matching identity through the configured LAN route or certificate-verified
  public HTTPS route;
- a successful Socket.IO WebSocket upgrade through Caddy; and
- a guarded 4xx response from the LiveKit `/rtc` route, proving it reached the
  media service instead of a dead reverse-proxy target.

The verifier prints no private key, credential, database path, or server
configuration. It explicitly leaves outside-network reachability, forced TURN,
and real media calls to the release conformance matrix because those cannot be
proved from inside the host.

Encrypted backup restore inspection is a separate command:

```bash
./install-yappa.sh verify-backup /path/yappa-backup.tar.gz.age
```

To restore a backup with a checksum-pinned local bundle, choose a new absolute
destination whose parent already exists:

```bash
./install-yappa.sh restore \
  --backup /secure/path/yappa-backup-YYYY-MM-DD.tar.gz.age \
  --local-bundle /path/yappa-server-0.1.0-dev.tar.gz \
  --sha256 FULL_LOWERCASE_SHA256 \
  --install-dir /absolute/new/yappa-server
```

Restore decrypts directly into a private assembly directory, validates the
bundle before combining it with state, rejects links and special files,
requires `.env`, the configured single database, and one persistent identity,
and runs SQLite integrity and schema checks. It never writes a plaintext
archive or merges into an existing destination. The completed installation is
renamed into place and left stopped so its network configuration can be
reviewed before `install-yappa.sh start`.

## Upgrade and rollback

Upgrade only from a healthy initialized installation and choose a new
encrypted-backup path:

```bash
./install-yappa.sh upgrade \
  --local-bundle /path/yappa-server-VERSION.tar.gz \
  --sha256 FULL_LOWERCASE_SHA256 \
  --backup /secure/path/yappa-before-upgrade.tar.gz.age
```

Yappa verifies the current server and encrypted recovery point, copies stopped
state into a checksum-pinned candidate, checks the database path, schema, and
integrity, then switches directory names. The candidate must start and pass
the operational verifier. A failed candidate is retained as
`.failed-upgrade`, while the previous installation is restored and verified.
A successful upgrade retains the previous installation as `.rollback`.

To deliberately return to that snapshot:

```bash
./install-yappa.sh rollback \
  --backup /secure/path/yappa-before-rollback.tar.gz.age
```

Rollback first encrypts and verifies the newer state, then activates and
verifies the older installation. The newer directory is retained as
`.pre-rollback`. Activity created after the upgrade is therefore preserved but
is not present in the active older snapshot. Never merge the two databases.

## Data-preserving uninstall

Uninstall requires two new absolute destinations and preserves server state by
default:

```bash
./install-yappa.sh uninstall \
  --backup /secure/path/yappa-before-uninstall.tar.gz.age \
  --preserve-data /secure/path/yappa-preserved-state
```

The command verifies the running installation, creates and verifies an
encrypted backup, stops the stack, copies `.env` and `data/` into a private
preservation directory, then removes the active runtime. It refuses overwrite
and refuses to proceed while `.rollback`, `.pre-rollback`, or
`.failed-upgrade` installations remain unresolved. A placement failure restores
and restarts the original installation. The preservation directory is not
directly runnable; restore it only through a checksum-pinned bundle.

## Explicit sign-in autostart on systemd Linux

On a Linux desktop with a working per-user systemd manager, an unprivileged
operator may explicitly opt into visible sign-in autostart:

```bash
./install-yappa.sh service-install
./install-yappa.sh service-status
./install-yappa.sh service-remove
```

Registration refuses root, writes a mode-`0600` unit under the current user's
`systemd/user` configuration, and calls only `systemctl --user`. The unit
starts the canonical lifecycle, requires operational verification before
systemd considers startup successful, and stops the stack when disabled.
Removal leaves all server data intact. It does not enable user lingering,
change the firewall, or request privilege; therefore it starts at user sign-in
rather than claiming unattended boot support.

Every canonical container has `restart: unless-stopped`, so Docker restarts a
container whose process exits unexpectedly and restores it after Docker daemon
restart. Yappa also records whether the last lifecycle request was `running`
or `stopped` in private host-local state. `install-yappa.sh recover` does
nothing after an intentional stop. When running was requested, it acquires a
single-instance lock, checks the canonical services and backend health, makes
at most one Compose recovery, waits through twelve bounded verification
attempts, and requires the full operational verifier. Three consecutive
failures trigger a 15-minute cooldown.

The explicit user-service registration includes a hardened one-minute systemd
timer for that bounded recovery command. This catches exited, missing, and
unhealthy services after ordinary crashes or a resumed user session without
creating an infinite restart loop. Removal deletes the main unit, timer,
recovery unit, and registration together. Real sleep, network transition, and
distribution-specific systemd conformance remain release work.

The development runtime contract now boots real per-user systemd managers on
Ubuntu 24.04, Debian 13, Fedora 44, and Rocky Linux 10 in disposable isolated
containers. It verifies paths containing spaces and refuses to report
registration success unless both the server unit and recovery timer become
active. Bare-metal boot, sleep/network transitions, and full Docker workload
recovery remain release gates.

## Explicit host firewall lifecycle

Preview firewall changes as an ordinary user before authorizing anything:

```bash
./install-yappa.sh firewall-plan --backend ufw
./install-yappa.sh firewall-plan \
  --backend firewalld \
  --lan-cidr 192.168.1.0/24
```

LAN mode requires an explicit IPv4 CIDR and scopes every rule to it. Public
mode opens only the configured HTTP/HTTPS, authenticated TURN, ICE/TCP, and
media UDP range; optional signed LAN discovery is CIDR-scoped. Raw backend
TCP `4100`, raw LiveKit TCP `7880`, the LAN-only proxy outside LAN mode, and
loopback discovery UDP `41201` are never opened.

Application/removal are separate explicit root actions:

```bash
./install-yappa.sh firewall-apply \
  --backend ufw \
  --lan-cidr 192.168.1.0/24
./install-yappa.sh firewall-remove
```

The script never invokes `sudo`, asks for a password, enables UFW, starts
firewalld, changes default policy, or touches unrelated rules. It refuses a
requested rule that already exists because ownership would be ambiguous,
rolls back partial application, and records exact owned rules in a
root-owned mode-`0600` file under mode-`0700` `/var/lib/yappa`. A non-secret
local marker prevents uninstall until rules are removed. Host-local service
and firewall state is excluded from encrypted portable backups and bundles;
it is preserved only across same-host upgrades.

## Start a public server

Run:

```bash
chmod +x start-yappa.sh
./start-yappa.sh
```

The first run creates `.env` with unique LiveKit credentials and a unique
attachment-signing secret, writes `livekit.yaml`, and starts the complete
stack. Users join with the server's public IP address. Caddy obtains and
automatically renews a publicly trusted six-day Let's Encrypt certificate for
that literal IP; no DNS name or DNS account is required. API, Socket.IO, and
LiveKit signaling share TCP `443`.

The startup and custom-domain scripts use a private process umask and enforce
mode `0600` on `.env`. The generated `livekit.yaml` is mode `0640` beneath the
mode-`0700` installation root so only the installation owner and the explicitly
supplemented LiveKit runtime group can read it. The repository does not
ship a runnable LiveKit configuration with shared development credentials;
`livekit.yaml` is created only from the installation's generated `.env`.

Public-IP detection makes one HTTPS request to `api.ipify.org`; running the
default setup therefore discloses the host's source IP to that service. Use
`--lan` if this external dependency is not acceptable.

Forward only these router/firewall ports to the server:

- TCP `80` for certificate issuance and HTTP-to-HTTPS redirects
- TCP `443` for the Yappa API, Socket.IO, and LiveKit signaling
- UDP `443` for authenticated LiveKit TURN/UDP media fallback
- TCP `7881` for WebRTC ICE/TCP
- UDP `50000-50100` for WebRTC media

The startup output prints these as `external -> internal` mappings so routers
with separate fields can be configured without guessing. In automatic-IP mode
it prints the public IP as the join address.

Do not forward TCP `4100`, TCP `7880`, or TCP `7882`. They are internal or
LAN compatibility listeners, not public entry points.

If the host already uses ports `80` or `443` (as Unraid commonly does), set
`YAPPA_HTTP_PORT` and `YAPPA_HTTPS_PORT` to unused host ports. Keep Caddy's
site addresses unchanged, and map public router ports `80`/`443` to those
chosen host ports. `YAPPA_LIVEKIT_PROXY_PORT` similarly controls the LAN-only
host mapping for Caddy's `7882` signaling listener.

The public IP is visible to anyone connecting and appears in public
certificate-transparency records. If the ISP changes it, rerun
`./start-yappa.sh`; automatic mode updates the address fields and obtains a new
IP certificate while preserving all server secrets and application data.

Routers without NAT loopback may prevent a host on the same LAN from reaching
its own public IP even while outside users can connect. Yappa packages a
hardened, unprivileged LAN-only discovery relay on UDP `41200`; do not forward
this port through the router. The relay has no server keys or user data and
can reach the signed backend responder only through host-loopback UDP `41201`.
Clients validate the persistent signed identity and use the discovered IP only
as the TCP route to the normal public HTTPS/WSS IP origin, preserving
certificate validation. API, realtime, and LiveKit signaling support this
fallback in the current client. Never forward plaintext compatibility
listeners publicly.

## Use a custom domain

After the initial start, point one DNS name at the public IP and run:

```bash
./setup-domain.sh chat.example.com
```

The script validates the name, changes only the relevant `.env` values, and
restarts the stack. The API, Socket.IO, and LiveKit signaling continue to share
one HTTPS/WSS origin, and Caddy obtains and renews its certificate.

## Private-network-only mode

For a server that will never be port-forwarded, run:

```bash
./start-yappa.sh --lan
```

This uses HTTP on the private network. It must not be exposed publicly.

The bundled media configuration provides direct UDP, ICE/TCP, and LiveKit's
authenticated embedded TURN/UDP fallback on UDP `443`. Caddy deliberately
does not publish HTTP/3 on UDP `443`, leaving that host socket to LiveKit.
TURN/TLS is not enabled because a single-IP installation cannot have both
Caddy and LiveKit independently terminate TLS on TCP `443` without an
additional layer-4 routing design and a TURN certificate. Networks that block
all UDP and non-HTTPS TCP may therefore still be unable to join calls. Treat
TURN/TLS as a separate release-readiness item rather than claiming universal
connectivity.

## Persistent and secret data

Install `age` from the host operating system's trusted package source, then
create an encrypted backup:

```bash
./backup-yappa.sh /secure/path/yappa-backup-YYYY-MM-DD.tar.gz.age
```

On Unraid, place the verified upstream `age` binary at
`/mnt/user/appdata/yappa/bin/age` so it persists across host reboots. Both
backup scripts prefer `bin/age` beside the Yappa installation, then fall back
to the system `PATH`. `YAPPA_AGE_BIN` may name another explicitly managed
binary.

The script refuses to overwrite an existing file, briefly pauses only the
application backend so SQLite and attachment state are consistent, streams
`.env` and `data/` directly into passphrase-authenticated encryption, deletes
an incomplete output on failure, and restarts the backend even after an error.
It never writes a plaintext archive. Store the passphrase separately and test
recovery before relying on a backup.

Attachment size limits are applied by the multipart parser as uploads stream
to disk. Oversized legacy or encrypted attachments receive HTTP 413 and are
cleaned up without creating an attachment record.

To inspect an encrypted backup without restoring it:

```bash
age --decrypt /secure/path/yappa-backup-YYYY-MM-DD.tar.gz.age | tar -tzf -
```

Run the bundled isolated restore verifier before relying on a backup:

```bash
./verify-yappa-backup.sh /secure/path/yappa-backup-YYYY-MM-DD.tar.gz.age
```

It decrypts directly into a mode-`0700` temporary directory, requires the
expected `.env`, database, and persistent server identity, runs SQLite's
integrity check, prints only schema and row counts, and removes the restored
copy on success or failure. It never writes a plaintext archive.

Prefer the fresh-install restore lifecycle above. For an older source-tree
installation without that command, restore only into an empty,
access-controlled server directory after stopping the stack:

```bash
age --decrypt /secure/path/yappa-backup-YYYY-MM-DD.tar.gz.age | tar -xzf - -C /path/to/empty/yappa
chmod 600 /path/to/empty/yappa/.env
```

The required backup set is:

- `data/`
- `.env`

The generated `livekit.yaml` is recreated from `.env`. Caddy certificate state
is replaceable and certificates are reissued automatically, so the Caddy
volume is not part of the cryptographic server identity or required recovery
set. Never publish `.env`, `livekit.yaml`, raw `data/`, plaintext database
copies, or the Caddy data volume.

Database upgrades are forward-only. Read `MIGRATIONS.md` before changing
versions. The backend applies and journals schema changes atomically and
refuses a database created by newer code. Rolling software back requires
restoring the matching pre-upgrade `.env` and `data/` backup into an empty
directory; never run an older image against an upgraded database.

The packaged backend and discovery relay run as the unprivileged numeric
UID/GID of the installation owner; startup verifies and restricts `data/` for
that account without requiring a privileged `chown`. All four
containers use read-only root filesystems, bounded `noexec,nosuid,nodev`
temporary mounts, dropped Linux capabilities, and `no-new-privileges`.
Only Caddy and LiveKit regain `NET_BIND_SERVICE` for intentional low-numbered
listeners. LiveKit is an explicit root exception for host-network TURN/UDP
443, but has no writable host-data mount; its root is read-only and its only
supplementary group can read mode-`0640` `livekit.yaml` beneath the private
installation root. The backend image contains production dependencies and
runtime source only, and its build context excludes secrets, data, databases,
backups, tests, and host `node_modules`.
