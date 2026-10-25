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
| `/home/{user}/logs` | Per-user logs |
| `/home/{user}/tmp` | PHP upload and session dir |
| `hearthost-{user}.slice` | cgroup v2 LVE: MemoryMax=1G, CPUQuota=100% |

## Request path

Client → host firewall (UFW on Ubuntu, firewalld on AlmaLinux; 22, 80, 443,
plus FTP when enabled) → Nginx → PHP-FPM unix socket running as the site
Unix user → MariaDB on 127.0.0.1.

SSH, SFTP, and FTP land in the same user slice so RAM/CPU caps apply.

## PHP versions

Per domain, from `8.2 8.3 8.4 8.5`. Default `8.3`.

LVE profile: one FPM service per `(php-version, user)` inside the user slice.
That is how 1 GB RAM actually includes PHP workers, not only SSH.

## Databases

MariaDB (MySQL protocol). Names are `{user}_{name}`.

| Login | Visible |
| --- | --- |
| root / admin | all databases |
| SSH username | `user_%` only |
| `{user}_{name}` | that one database |

phpMyAdmin listens on a dedicated hostname only, never on a customer vhost.
The hostname is not inferred from the server PTR. Set it with
`--phpmyadmin-host`, `HEARTHOST_PHPMYADMIN_HOST`, an existing
`/etc/hearthost/hearthost.conf`, or an interactive prompt during `hearthost init`.

## Phases

0. Repo, schema, doctor, unit tests
1. Hardening: firewall, SSH groups, sysctl, fail2ban — `hearthost init hardening`

## Distro notes

| | Ubuntu LTS | AlmaLinux 9/10 |
| --- | --- | --- |
| Packages | apt | dnf + EPEL |
| Firewall | UFW | firewalld |
| Auto-updates | unattended-upgrades | dnf-automatic |
| Nginx user | www-data | nginx |
| SSH unit | `ssh.service` | `sshd.service` |
| PHP later | ondrej/php | Remi (planned) |
| MAC | AppArmor | SELinux stays enforcing |
2. Nginx + TLS templates
3. MariaDB + phpMyAdmin
4. Multi-PHP FPM
5. `user` / `site` CLI, SFTP, vsftpd
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
