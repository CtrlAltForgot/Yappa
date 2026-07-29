# Yappa Database Migration and Rollback Contract

Yappa's SQLite schema is forward-only. The current supported schema version is
recorded in `schema_migrations`; the backend refuses to open a database whose
version is newer than the running code supports.

## Startup behavior

Schema creation, additive migrations, default configuration, and version
journaling run in one SQLite transaction. A failed statement rolls back all
schema and data changes from that startup attempt. The version row is written
only after every migration succeeds.

This protects against partial migration. It does not make an old Yappa binary
compatible with a new database and does not replace a backup.

## Before upgrading

Create and inspect an encrypted backup while the currently installed version
is still running:

```bash
./backup-yappa.sh /secure/path/yappa-before-upgrade-YYYY-MM-DD.tar.gz.age
age --decrypt /secure/path/yappa-before-upgrade-YYYY-MM-DD.tar.gz.age | tar -tzf -
```

Keep the matching Yappa source/image revision with the backup. Do not copy a
live SQLite file independently of its WAL; use the supplied backup command,
which pauses the application backend and includes the complete `data/` tree.

The Linux lifecycle performs this sequence with:

```bash
./install-yappa.sh upgrade \
  --local-bundle /path/yappa-server-VERSION.tar.gz \
  --sha256 FULL_LOWERCASE_SHA256 \
  --backup /secure/path/yappa-before-upgrade-YYYY-MM-DD.tar.gz.age
```

It first verifies the running installation, creates and independently verifies
the encrypted backup, stops the stack, installs the checksum-pinned candidate
beside the active directory, copies the stopped state, checks its path, schema,
and SQLite integrity, then swaps directory names. The candidate must start and
pass operational verification. Otherwise, Yappa restores and verifies the
previous installation and retains the failed candidate for investigation.

## Rollback

Never point an older binary at a database that a newer version migrated. A
software rollback is a complete data restore:

1. Stop the Yappa stack.
2. Preserve the failed/newer installation for investigation.
3. Restore the pre-upgrade `.env` and `data/` together into an empty,
   access-controlled Yappa directory.
4. Apply mode `0600` to the restored `.env`.
5. Start the exact Yappa revision that created the backup.
6. Verify health, server identity, users, channels, messages, attachments,
   voice configuration, and the recorded schema version before reopening
   public access.

Do not merge selected tables from different schema versions. An encrypted
channel also cannot be rolled back in place to plaintext; restoring an older
whole-server backup intentionally loses all activity after that backup.

After a lifecycle upgrade, the pre-upgrade installation is retained as the
adjacent `.rollback` directory. An explicit rollback first backs up and
verifies the newer state, then swaps back and requires the older installation
to start and pass operational verification:

```bash
./install-yappa.sh rollback \
  --backup /secure/path/yappa-before-rollback-YYYY-MM-DD.tar.gz.age
```

The newer installation is retained as `.pre-rollback`, so post-upgrade
activity is not silently deleted. Rollback intentionally makes the older
snapshot active; reconcile or restore newer activity only through a separately
reviewed recovery procedure, never by merging databases.

## Requirements for future migrations

Every schema change must:

- increment `CURRENT_SCHEMA_VERSION`;
- run inside the existing initialization transaction;
- record its version only after success;
- preserve existing data unless a separately documented destructive migration
  has explicit operator confirmation and recovery instructions;
- include a fixture beginning at the previous schema version;
- test successful data preservation, failure rollback, and rejection by an
  older supported-version boundary;
- update `PROJECT_PLAN.md`, `SECURITY.md`, this document, and deployment
  release notes;
- be deployed only after an encrypted pre-upgrade backup is created and
  restorable.

Schema version `1` is the journaled baseline. Its migration tests cover a
legacy plaintext database, preservation and honest `legacy` labeling, the
one-way E2EE guard, future-version refusal without mutation, and complete DDL
rollback after an injected uniqueness failure.

Schema version `2` adds `client_operation_id` to opaque MLS delivery rows and a
partial unique index over `(uploader_device_id, client_operation_id)`. Existing
version-1 rows retain their wire bytes and receive `NULL`; all new API writes
require a bounded operation id. A version-1 fixture verifies the additive
migration and row preservation. Rollback to a version-1 binary requires the
normal complete pre-upgrade restore.

Schema version `3` adds `mls_device_credentials`, a bounded durable directory
of MLS leaf signature keys and their YUID authorization signatures. New
KeyPackage registration records the verified credential in the same
transaction as its private-material advertisement. Migration backfills
distinct bindings from existing KeyPackage history without changing or
restoring consumed KeyPackage wire bytes. Active authenticated clients may
read the directory; revoked devices and banned accounts are excluded. A
version-2 fixture proves the binding fields are preserved by the additive
backfill. Rollback to schema 2 requires the normal complete pre-upgrade
restore.

Schema version `4` establishes indefinite chat-attachment retention as the
only public-release policy. It changes fresh-server retention to `0`, resets
existing server settings to `0`, and clears `expires_at` from every active
ordinary and encrypted attachment so previously scheduled cleanup cannot
silently remove chat history after upgrade. Explicitly deleted rows remain
deleted and are not resurrected. A version-3 fixture proves the setting and
active attachment are preserved while their implicit expiry is removed.
Rollback to schema 3 requires the normal complete pre-upgrade restore; opening
the migrated database with a schema-3 binary is forbidden.

The distributable install manifest declares database schema 4. Upgrade,
fresh-restore, and install verification must use that manifest value; schema 5
or later fails closed until a matching backend migration is shipped.

The production Unraid database migrated from version 1 to version 2 on
2026-07-24 after its encrypted pre-upgrade archive checksum was verified.
Post-migration inspection confirmed schema 2, the operation column and index,
and preservation of one user and ten legacy messages.

The same production database migrated from version 2 to version 3 on
2026-07-24 after checksum verification of
`yappa-pre-schema3-20260724.tar.gz.enc`. Post-migration inspection confirmed
schema 3, the credential table, zero expected pre-activation credential rows,
and preservation of one user, ten legacy messages, and zero MLS deliveries.
The backend health check passed and the container remained UID/GID 1000 with
`no-new-privileges`.

Schema version 4 has not been deployed to production because approved Unraid
access is unavailable. Deployment requires the normal encrypted, verified
pre-upgrade backup and post-migration checks for schema version, zero active
attachment expiries, preserved attachment rows/files, SQLite integrity, and
backend health.

On 2026-07-24, the production schema-3 installation completed a real
passphrase-encrypted backup with checksum-verified `age` v1.3.1 and the bundled
isolated restore verifier. SQLite integrity, schema version 3, one user, ten
legacy messages, the required `.env`, and the persistent server identity all
passed. The verifier removed its restored copy, no partial backup remained,
and the production backend automatically resumed healthy.
