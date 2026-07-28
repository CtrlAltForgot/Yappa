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
restore prerequisites before startup. After initialization it also dispatches
`start`, `stop`, `status`, `logs`, `backup`, and `verify` to the existing
hardened operations.

This is not a remote public installer. `install-manifest.json` is explicitly
an unpublished development manifest: it has no artifact URL, checksum,
signature, release-validated host, client command-generation permission, or
client-supervision permission. The wrapper requires an explicit
`--local-source` flag and otherwise fails closed. Do not copy a command from a
development checkout and describe it as a supported one-click install.

`Install-Yappa.ps1 preflight` checks the currently planned Windows/WSL
prerequisites but intentionally cannot install or operate the server yet.
Windows lifecycle commands remain disabled until signed artifacts and the
Windows 11/Windows Server conformance matrices exist.

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
mode `0600` on `.env` and the generated `livekit.yaml`. The repository does not
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

Restore only into an empty, access-controlled server directory after stopping
the stack:

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

The packaged backend runs as unprivileged UID/GID `1000:1000`; the startup
script creates, owns, and restricts `data/` for that account. All three
containers use read-only root filesystems, bounded `noexec,nosuid,nodev`
temporary mounts, dropped Linux capabilities, and `no-new-privileges`.
Only Caddy and LiveKit regain `NET_BIND_SERVICE` for their intentional
low-numbered listeners. The backend image contains production dependencies and
runtime source only, and its build context excludes secrets, data, databases,
backups, tests, and host `node_modules`.
