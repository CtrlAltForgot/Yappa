# Known Limitations

- **Pre-alpha and unsigned:** published test builds are unsigned and unsupported.
- **Limited platform validation:** Linux and Windows have hosted build evidence;
  real hardware/desktop coverage remains incomplete, and macOS is not a current
  published user build.
- **No independent review:** security and cryptographic designs have not
  completed independent review; verified E2EE is not claimed.
- **Media verification gaps:** native two-client, wrong/no-key, SFU/traffic
  inspection, forced relay, and broader network tests remain incomplete.
- **Mixed message modes:** legacy text feeds and attachments can remain
  plaintext on the server; encrypted-feed paths are experimental.
- **At-rest exposure:** Yappa does not encrypt its server database/files at
  rest. Operators must protect disks, backups, credentials, and host access.
- **Deployment complexity:** public hosting requires correct TLS, firewall,
  port forwarding, LiveKit, storage, backup, and upgrade configuration.
- **Networking edge cases:** NAT loopback, restrictive networks, IP changes,
  and TURN/TLS behavior need broader validation.
- **Recovery boundaries:** recovery and backups are operationally sensitive;
  forward-only migrations require restoring matching software and data.
- **Compatibility:** prerelease schemas, protocols, and artifacts may change;
  no stable cross-version compatibility promise exists.

[Project home](../README.md) · [Status](PROJECT_STATUS.md) · [Security policy](../SECURITY.md)
