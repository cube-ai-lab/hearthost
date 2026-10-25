# Security policy

Report vulnerabilities privately. Do not open a public issue with an exploit.

This stack is multi-tenant. A valid report usually means one of:

- Tenant A can read or write Tenant B's files, sockets, or databases
- Unauthenticated PHP execution outside a site docroot
- phpMyAdmin showing databases the logged-in MySQL user cannot grant-select
- Escape from `open_basedir`, SFTP/FTP chroot, or the systemd memory/CPU slice
- Remote MariaDB, or root SSH with password after Phase 1 hardening

Classic FTP (port 21) is enabled by operator choice. Credentials are plaintext
unless the client uses FTPS. Prefer SFTP. That is accepted risk, not a bug,
unless chroot fails.

## What we test

Unit tests cover path rules, username/domain validation, and quota math.

Later phases add isolation tests (user A vs user B) and defensive scanners
against a local fixture WordPress site (headers, PHP-in-uploads denied,
xmlrpc denied). We do not ship exploit payloads.
