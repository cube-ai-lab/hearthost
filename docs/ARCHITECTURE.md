# Hearthost architecture

CLI-first multi-tenant hosting for Ubuntu LTS (22.04+) and AlmaLinux 9/10.
No web control panel.

Runtime state lives on the target server under `/etc/hearthost`. The clone
of this repository can sit anywhere; the CLI locates itself relative to
`bin/hearthost`.

## Layout

| Path | Role |
| --- | --- |
| clone tree | CLI, templates, tests |
| `/etc/hearthost/hearthost.conf` | Installed config (created by `hearthost init`) |
| `/home/{user}/public_html` | Primary website |
| `/home/{user}/{domain}` | Every other domain and subdomain |
| `/home/{user}/ssl` | ACME webroot (`/.well-known`) |
| `/home/{user}/ssl/{domain}/` | `fullchain.pem` + `privkey.pem` |
| `/home/{user}/logs` | Per-user logs |
| `/home/{user}/tmp` | PHP upload and session dir |
| `hearthost-{user}.slice` | cgroup v2 LVE: MemoryMax=1G, CPUQuota=100% |

## File ownership (cPanel-style)

Website files are **`{user}:{user}`**. Nginx (`www-data` on Ubuntu, `nginx` on
AlmaLinux) does not own them. PHP-FPM runs as the site Unix user, so WordPress
can write `wp-content` without world-writable directories.

| Path | Owner | Mode | Why |
| --- | --- | --- | --- |
| `/home/{user}` | user:user | 711 | Others can traverse to the docroot, not list the home |
| `/home/{user}/public_html` | user:user | 755 | Nginx reads static files |
| `/home/{user}/{domain}` | user:user | 755 | Same for addon domains and subdomains |
| files (css, php, uploads) | user:user | 644 | Owner writes; Nginx reads as “other” |
| `wp-config.php` and secrets | user:user | 640 | PHP-FPM as the user can read; neighbors cannot |
| `/home/{user}/ssl` | user:user | 711 | ACME challenges; Nginx workers traverse |
| `/home/{user}/ssl/{domain}/privkey.pem` | user:user | 600 | Nginx master (root) loads the key |
| `/home/{user}/logs` | user:user | 750 | Not web-served |
| `/home/{user}/tmp` | user:user | 700 | PHP sessions and uploads |
| FPM socket | user:www-data (or nginx) | 660 | Only place the web daemon appears |

Tenants are never added to the `www-data` / `nginx` group. That group exists so
Nginx can connect to the per-user PHP-FPM socket.

## Request path

Client → host firewall (UFW on Ubuntu, firewalld on AlmaLinux; 22, 80, 443,
plus FTP when enabled) → Nginx → PHP-FPM unix socket running as the site
Unix user → MariaDB on 127.0.0.1.

SSH, SFTP, and FTP land in the same user slice so RAM/CPU caps apply.

## PHP versions

Per domain, from `8.2 8.3 8.4 8.5`. Default `8.3`.

LVE profile: one FPM pool per `(php-version, user)` inside the user slice
(`hearthost init php` installs the FPM daemons; `user`/`site` attach pools
in Phase 5). That is how 1 GB RAM actually includes PHP workers, not only SSH.

```bash
hearthost init php
hearthost php versions
hearthost php pool alice 8.3
```

## Databases

MariaDB (MySQL protocol). Names are `{user}_{name}`.

| Login | Visible |
| --- | --- |
| root / admin | all databases |
| SSH username | `user_%` only |
| `{user}_{name}` | that one database |

phpMyAdmin listens on a dedicated hostname only, never on a customer vhost.
The hostname and Let's Encrypt account email are **not shipped in this
repository**. The server admin supplies them at install time with
`--phpmyadmin-host`, `--letsencrypt-email`, environment variables, a TTY
prompt, or `/etc/hearthost/hearthost.conf` on the target. They are never
inferred from the machine PTR. Cookie auth against MariaDB on 127.0.0.1.
PHP-FPM pool `hearthost-pma`.

## Let's Encrypt

HTTP-01 via certbot webroot. Certbot keeps the lineage under
`/etc/letsencrypt`. A deploy hook copies `fullchain.pem` and `privkey.pem`
into the published path and reloads Nginx.

| Name | ACME webroot | Published cert |
| --- | --- | --- |
| Tenant `{user}` / `{domain}` | `/home/{user}/ssl` | `/home/{user}/ssl/{domain}/` |
| phpMyAdmin / system | `/etc/hearthost/ssl` | `/etc/hearthost/ssl/{domain}/` |
| Unknown-host catch-all | (none) | `/etc/hearthost/tls/default.*` (self-signed) |

```bash
hearthost init ssl
hearthost init mariadb --phpmyadmin-host pma.example.com --letsencrypt-email ops@example.com
hearthost ssl issue --user alice example.com
hearthost ssl issue --system pma.example.com
```

DNS A/AAAA for the name must point at this server before issue succeeds.
Until then Nginx uses a self-signed placeholder so `nginx -t` still passes.
`certbot.timer` renews; `/etc/letsencrypt/renewal-hooks/deploy/hearthost.sh`
copies into the mapped dest from `/etc/hearthost/ssl-map/{domain}`.

## Distro notes

| | Ubuntu LTS | AlmaLinux 9/10 |
| --- | --- | --- |
| Packages | apt | dnf + EPEL |
| Firewall | UFW | firewalld |
| Auto-updates | unattended-upgrades | dnf-automatic |
| Nginx daemon (not file owner) | www-data | nginx |
| SSH unit | `ssh.service` | `sshd.service` |
| PHP | ondrej/php 8.2–8.5 | Remi parallel php82–php85 |
| MAC | AppArmor | SELinux stays enforcing |

## Phases

0. Repo, schema, doctor, unit tests
1. Hardening: firewall, SSH groups, sysctl, fail2ban — `hearthost init hardening`
2. Nginx + TLS templates — `hearthost init nginx`
3. MariaDB + phpMyAdmin + Let's Encrypt — `hearthost init mariadb`
4. Multi-PHP FPM 8.2–8.5 — `hearthost init php`
5. `user` / `site` CLI, SFTP chroot, vsftpd — `hearthost user add`,
   `site add`, `init sftp`, `init ftp`
6. systemd slices at 1G / 1 CPU
7. WP-CLI, OPcache, optional FastCGI microcache
8. Backups, logrotate
9. Isolation tests and defensive scans

## SSH after Phase 1

`AllowUsers root` is removed. Tenants must be in group `hearthost-ssh`.
Root is added to that group so admin access is kept. TCP forwarding stays on
for remote IDEs. FTP ports are not opened until vsftpd is installed.

`hearthost doctor` reports live RAM, CPU, and tenant fit for the machine it
runs on. Those numbers are not stored in this repository.
