# Troubleshooting

## Client does not start

- Confirm you extracted the complete archive and kept native libraries beside
  the executable.
- Record the build tag/commit, operating system, desktop environment, and the
  exact sanitized error.
- Remember that unsigned pre-alpha builds may be blocked by platform policy.

## Cannot connect

- Confirm the server is healthy using its documented verification command.
- Check the entered public IP/domain, TLS certificate, router rules, and host
  firewall without exposing credentials or addresses in public reports.
- Do not work around a server-identity warning or downgrade public HTTPS to HTTP.

## Voice, camera, or screen sharing fails

- Record whether text/realtime connectivity works, which devices were
  selected, and whether the problem changes after restart.
- Consult [screen-sharing validation notes](../platform/SCREEN_SHARING.md).
- Media compatibility is incomplete; absence of a crash is not proof of secure
  media encryption.

## Reporting a bug

Use the bug form and attach only sanitized diagnostics. Never upload passwords,
tokens, keys, private messages, attachments, databases, private hostnames/IPs,
or other people's personal data. Security issues belong in
[private vulnerability reporting](../../SECURITY.md).

[Support](../../SUPPORT.md) · [Project home](../../README.md) · [Documentation index](../README.md)
