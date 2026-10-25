# Hearthost

CLI-first multi-tenant hosting for Ubuntu LTS and AlmaLinux. No control panel.

Each customer is a Unix user. The primary site is `/home/{user}/public_html`.
Every extra domain or subdomain is `/home/{user}/{domain}`. TLS certificates
and ACME challenges live in `/home/{user}/ssl`. PHP version is chosen per
site. RAM and CPU are capped per user with systemd cgroup v2 (CloudLinux
LVE-style): **1 GB RAM and 1 CPU by default**, overridable as root.

WordPress and Laravel are first-class. MariaDB, phpMyAdmin, SFTP, and FTP
are included. Nginx terminates TLS.

This repository is generic installer source. Do not commit a machine IP,
hostname, or hardware inventory.

## Supported operating systems

| Family | Versions |
| --- | --- |
| Ubuntu LTS | 22.04, 24.04, 26.04, and later even-year `.04` releases |
| AlmaLinux | 9.x, 10.x |

Interim Ubuntu releases (for example 25.04) and other distros are rejected.
Debian, Rocky, and RHEL are not claimed as supported even when they look similar.

On Ubuntu, Phase 1 uses UFW and unattended-upgrades. On AlmaLinux it uses
firewalld and dnf-automatic. Site files are always `{user}:{user}` (cPanel
style). Nginx runs as `www-data` or `nginx` only to serve static files and
connect to that user’s PHP-FPM socket.

## Status

Phase 7 is available: apps and performance. `hearthost init wp` installs
wp-cli; `wp install USER DOMAIN` sets up WordPress in the docroot (DB over
unix_socket, no stored password); `db create USER NAME` makes a `{user}_{name}`
database. OPcache is tuned per tenant, and `site add --microcache N` enables a
FastCGI microcache for anonymous GET. Earlier phases: per-tenant RAM/CPU slices
(dedicated PHP-FPM master in `user-<uid>.slice`), tenant/site lifecycle
(`user add`, `site add`, `init sftp`, `init ftp`), hardening, Nginx + TLS,
MariaDB + phpMyAdmin + Let's Encrypt, multi-PHP 8.2–8.5.

```bash
./bin/hearthost os
./bin/hearthost init hardening --phpmyadmin-host pma.example.com
./bin/hearthost init nginx
./bin/hearthost init mariadb --phpmyadmin-host pma.example.com --letsencrypt-email ops@example.com
./bin/hearthost init php
./bin/hearthost init sftp
./bin/hearthost init ftp            # only if ftp_enable=yes
./bin/hearthost init slices         # (re)apply per-tenant RAM/CPU caps
./bin/hearthost init wp             # install wp-cli
./bin/hearthost user add alice
./bin/hearthost site add alice example.com --app wordpress --primary --alias www.example.com --microcache 10
./bin/hearthost wp install alice example.com --title "My Site" --admin-email me@example.com
./tests/run.sh
```

On an interactive SSH session, omit `--phpmyadmin-host` and the command
will ask for a dedicated FQDN if it is not already in `/etc/hearthost/hearthost.conf`.

## Requirements

- A supported OS from the table above
- Root shell
- Enough RAM for `1G × tenants + ~1.5G` system overhead

## Quick start

```bash
git clone https://github.com/cube-ai-lab/hearthost.git
cd hearthost
./tests/run.sh
./bin/hearthost doctor
./bin/hearthost path docroot alice example.com --primary
# /home/alice/public_html
```

## Defaults

| Item | Value |
| --- | --- |
| PHP | 8.2, 8.3, 8.4, 8.5 (default 8.3) |
| Quota | 1G RAM, 100% CPU (one core), overridable per user |
| Uploads | SFTP + classic FTP on port 21 |
| phpMyAdmin | dedicated hostname + HTTPS + fail2ban (prompted at install) |
| TLS | Let's Encrypt HTTP-01 → `/home/{user}/ssl/{domain}/` |

Classic FTP sends passwords in the clear. FTPS is offered on the same daemon.
Prefer SFTP.

## Layout

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
