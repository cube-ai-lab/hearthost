# Hearthost CLI Reference

Complete command reference for hosting websites with Hearthost. All commands
run as root from anywhere — the CLI locates itself via `bin/hearthost`.

```bash
./bin/hearthost <command> [arguments]
```

---

## Table of Contents

1. [Server Setup (init)](#server-setup)
2. [Create a User](#create-a-user)
3. [Add a Site (Domain)](#add-a-site)
4. [Create a Database](#create-a-database)
5. [Install WordPress](#install-wordpress)
6. [Issue SSL Certificate](#issue-ssl-certificate)
7. [Resource Limits (Slices)](#resource-limits)
8. [FTP Access](#ftp-access)
9. [Backups](#backups)
10. [Health & Monitoring](#health--monitoring)
11. [Utility Commands](#utility-commands)

---

## Server Setup

Run these once, in order, on a fresh server.

### 1. Preflight Check

```bash
hearthost doctor
```

Checks OS compatibility, RAM, disk, required packages. Run this first to see
what the server needs before installation.

After all init steps, verify the full stack:

```bash
hearthost doctor --stack
```

### 2. Hardening (Phase 1)

```bash
hearthost init hardening --phpmyadmin-host pma.example.com
```

Configures: firewall (UFW or firewalld), SSH key-only + AllowGroups, sysctl
hardening, fail2ban, unattended upgrades. The phpMyAdmin hostname is stored
in `/etc/hearthost/hearthost.conf` for later phases.

| Flag | Description |
| --- | --- |
| `--phpmyadmin-host FQDN` | Dedicated hostname for phpMyAdmin (prompted interactively if omitted) |

### 3. Nginx + TLS (Phase 2)

```bash
hearthost init nginx
```

Installs Nginx, renders the default TLS catch-all vhost with a self-signed
certificate, creates snippet includes for SSL and security headers.

### 4. MariaDB + phpMyAdmin + Let's Encrypt (Phase 3)

```bash
hearthost init mariadb --phpmyadmin-host pma.example.com --letsencrypt-email ops@example.com
```

Installs MariaDB (unix_socket auth for root), phpMyAdmin on the dedicated
hostname, certbot with HTTP-01 webroot renewal, and the deploy hook that
copies certs into place.

| Flag | Description |
| --- | --- |
| `--phpmyadmin-host FQDN` | Reuses the value from Phase 1 if already set |
| `--letsencrypt-email EMAIL` | Used for certbot account registration |

### 5. SSL / Certbot (standalone)

```bash
hearthost init ssl
```

Installs certbot, HTTP-01 webroot config, and the renewal deploy hook.
Included in Phase 3 automatically — use this only if you skipped Phase 3.

### 6. PHP-FPM (Phase 4)

```bash
hearthost init php
```

Installs PHP versions 8.2, 8.3, 8.4, and 8.5 with FPM and common modules
(ondrej/php on Ubuntu, Remi on AlmaLinux). Default version: **8.3**.

### 7. SFTP Chroot (Phase 5)

```bash
hearthost init sftp
```

Adds the SSH `Match Group hearthost-sftp` block that chroots SFTP-only users
to their home directory. Reloads sshd.

### 8. FTP / vsftpd (Phase 5, optional)

```bash
hearthost init ftp
```

Installs vsftpd with FTPS support and passive-port firewall rules. Only
runs if `ftp_enable=yes` in `/etc/hearthost/hearthost.conf`.

### 9. Resource Slices (Phase 6)

```bash
hearthost init slices
```

Re-applies cgroup v2 caps (RAM / CPU / tasks) to every existing tenant.
Run this after a reboot or after changing default limits in config.

### 10. WP-CLI (Phase 7)

```bash
hearthost init wp
```

Downloads and installs `wp-cli.phar` to `/usr/local/bin/wp`.

### 11. Log Rotation (Phase 8)

```bash
hearthost init logrotate
```

Installs a logrotate config for per-tenant logs under `/home/*/logs/`.

### 12. Nightly Backups (Phase 8)

```bash
hearthost init backups
```

Creates a systemd timer that runs `hearthost backup run` nightly.

---

## Create a User

```bash
hearthost user add USERNAME [options]
```

Creates a Unix account, home directory layout, `hearthost-ssh` group
membership, MariaDB unix_socket grant (`username_%`), and a systemd cgroup
slice (1 GB RAM / 1 CPU by default).

| Flag | Description |
| --- | --- |
| `--sftp-only` | SFTP-only account (no shell); home is chroot-jailed |
| `--password PASSWORD` | Set an initial password (otherwise login is key-only) |
| `--no-db` | Skip the MariaDB grant |
| `--memory SIZE` | RAM cap, e.g. `512M`, `2G` (default: `1G`) |
| `--cpu PERCENT` | CPU cap, e.g. `100%` for 1 core, `200%` for 2 (default: `100%`) |

**Example — create a full-access tenant with 2 GB RAM:**

```bash
hearthost user add alice --memory 2G --cpu 200%
```

**Example — create an SFTP-only uploader:**

```bash
hearthost user add photographer --sftp-only --password 's3cret!'
```

### What it creates

| Item | Path / Detail |
| --- | --- |
| Home directory | `/home/USERNAME/` |
| Web directories | `public_html/`, `logs/`, `tmp/`, `ssl/` |
| DB grant | `USERNAME_%` (all databases prefixed with the username) |
| Cgroup slice | `user-<UID>.slice` with MemoryMax / CPUQuota / TasksMax |
| State file | `/etc/hearthost/users.d/USERNAME.yaml` |

### Remove a User

```bash
hearthost user del USERNAME [--purge]
```

Without `--purge`: disables the account, detaches sites, removes the slice
and PHP-FPM service. Home directory and databases are preserved.

With `--purge`: also deletes the home directory and drops all `username_%`
databases.

---

## Add a Site

```bash
hearthost site add USERNAME DOMAIN [options]
```

Provisions an Nginx vhost, a dedicated PHP-FPM master process (pinned to the
user's cgroup slice), the document root, and optionally requests a Let's
Encrypt certificate.

| Flag | Description |
| --- | --- |
| `--primary` | Use `public_html` as docroot instead of `/home/user/domain` |
| `--php VERSION` | PHP version for this site (default: `8.3`) |
| `--app wordpress\|laravel\|php` | Vhost template to use (default: `php`) |
| `--alias NAME` | Server alias (repeatable, e.g. `--alias www.example.com`) |
| `--no-ssl` | Skip Let's Encrypt; use the self-signed placeholder |
| `--microcache SECONDS` | Enable FastCGI microcache (e.g. `10` for 10s TTL) |

**Example — primary WordPress site with www alias and 10s microcache:**

```bash
hearthost site add alice example.com \
  --primary --app wordpress \
  --alias www.example.com \
  --microcache 10
```

**Example — addon domain (Laravel) on PHP 8.4:**

```bash
hearthost site add alice api.example.com --app laravel --php 8.4
```

### What it creates

| Item | Path / Detail |
| --- | --- |
| Document root | `/home/USERNAME/public_html` (primary) or `/home/USERNAME/DOMAIN` |
| Nginx vhost | `/etc/nginx/sites-available/DOMAIN.conf` → sites-enabled |
| PHP-FPM service | `hearthost-php<VER>-USERNAME.service` (dedicated master) |
| PHP-FPM pool config | `/etc/hearthost/php/USERNAME/DOMAIN.conf` |
| TLS certificate | `/home/USERNAME/ssl/DOMAIN/fullchain.pem` + `privkey.pem` |
| State file | `/etc/hearthost/sites.d/DOMAIN.yaml` |

### Remove a Site

```bash
hearthost site del DOMAIN [--purge]
```

Without `--purge`: removes vhost and PHP pool, keeps the document root.

With `--purge`: also deletes the document root directory.

---

## Create a Database

```bash
hearthost db create USERNAME DBNAME
```

Creates a MariaDB database named `USERNAME_DBNAME` and grants full access to
the tenant's Unix account (via unix_socket authentication). No password is
stored — the tenant connects as themselves over the local socket.

**Example:**

```bash
hearthost db create alice wordpress
# Creates database: alice_wordpress
# Grants:  ALL PRIVILEGES on alice_wordpress.* TO 'alice'@'localhost'
```

The tenant can connect from their shell:

```bash
# As user alice:
mysql alice_wordpress
```

---

## Install WordPress

```bash
hearthost wp install USERNAME DOMAIN [options]
```

Downloads WordPress core, creates `wp-config.php` with the correct database
credentials (unix_socket auth, no password), and runs the WP install. The
site must already exist (`site add` first) and a database must exist
(`db create` first).

| Flag | Description |
| --- | --- |
| `--title TITLE` | Site title (default: the domain name) |
| `--admin-user USER` | WordPress admin username (default: `admin`) |
| `--admin-email EMAIL` | Admin email (required for WP install) |
| `--admin-password PW` | Admin password (auto-generated if omitted) |

**Example — full WordPress setup from scratch:**

```bash
hearthost user add alice
hearthost site add alice example.com --primary --app wordpress --alias www.example.com
hearthost db create alice wordpress
hearthost wp install alice example.com \
  --title "Alice's Blog" \
  --admin-email alice@example.com
```

---

## Issue SSL Certificate

### For a tenant domain

```bash
hearthost ssl issue --user USERNAME DOMAIN
```

Requests a Let's Encrypt certificate via HTTP-01 and installs it to
`/home/USERNAME/ssl/DOMAIN/`. DNS must already point at this server.

### For a system service (phpMyAdmin, etc.)

```bash
hearthost ssl issue --system DOMAIN
```

Installs the certificate to `/etc/hearthost/ssl/DOMAIN/`.

**Note:** Certificates auto-renew via `certbot.timer`. The deploy hook copies
renewed certs into the correct location and reloads Nginx.

---

## Resource Limits

### Set per-user limits

```bash
hearthost slice apply USERNAME [--memory SIZE] [--cpu PERCENT] [--tasks N]
```

Updates the cgroup v2 limits for a tenant's `user-<UID>.slice`. Applies
immediately to the running slice and persists via a systemd drop-in.

| Flag | Default | Description |
| --- | --- | --- |
| `--memory SIZE` | `1G` | RAM cap (e.g. `512M`, `2G`) |
| `--cpu PERCENT` | `100%` | CPU quota (100% = 1 core) |
| `--tasks N` | `256` | Max concurrent processes |

**Example — give a heavy site 4 GB and 2 cores:**

```bash
hearthost slice apply alice --memory 4G --cpu 200%
```

### Re-apply all tenant limits

```bash
hearthost init slices
```

Reads each tenant's state file and re-applies their slice. Useful after a
reboot or config change.

---

## FTP Access

```bash
hearthost ftp allow USERNAME    # enable FTP for this tenant
hearthost ftp deny USERNAME     # disable FTP for this tenant
```

Adds or removes the user from the vsftpd allow-list. Requires `init ftp`
to have been run first.

---

## Backups

### Run a backup

```bash
hearthost backup run              # all tenants
hearthost backup run USERNAME     # one tenant
```

Backs up tenant home directories and all `username_%` databases into a
cPanel-style layout:

```
/backup/
  2026-10-25/
    accounts/
      alice.tar.gz
      bob.tar.gz
  2026-10-24/
    accounts/
      alice.tar.gz
      bob.tar.gz
```

Each `.tar.gz` contains the user's home (files, SSL certs, logs), database
dumps (`db/*.sql.gz`), and a `manifest.txt`. Old date directories beyond
`backup_keep` (default 7) are pruned automatically.

### List backups

```bash
hearthost backup list             # all tenants
hearthost backup list USERNAME    # one tenant
```

Shows available backup archives by date.

---

## Health & Monitoring

### Health check

```bash
hearthost health
```

Checks: systemd services (Nginx, MariaDB, PHP-FPM), per-tenant FPM pools,
TLS certificate expiry, disk usage. Exits non-zero if any problem is found.
Ideal for cron alerting.

### Security audit

```bash
hearthost audit
```

Read-only defensive scan: network exposure, tenant file permissions, PHP
confinement (open_basedir, disable_functions), group membership, database
bind address, SSH policy, per-tenant cgroup caps. Exits non-zero on any
risk.

---

## Utility Commands

### OS detection

```bash
hearthost os
```

Prints detected OS family, version, web user, and support status.

### PHP versions

```bash
hearthost php versions
```

Lists configured PHP versions (8.2, 8.3, 8.4, 8.5).

### Path helpers

```bash
hearthost path user alice                          # /home/alice
hearthost path docroot alice example.com --primary # /home/alice/public_html
hearthost path docroot alice blog.example.com      # /home/alice/blog.example.com
hearthost path ssl alice example.com               # /home/alice/ssl/example.com
hearthost path db alice wordpress                  # alice_wordpress
hearthost path owner alice                         # alice:alice
hearthost path perms home                          # 711
hearthost path perms webroot                       # 755
hearthost path perms secret                        # 640
```

### Validation

```bash
hearthost validate user alice         # exit 0 = valid
hearthost validate domain example.com
hearthost validate php 8.3
```

### Version

```bash
hearthost version
```

---

## Complete Workflow: New Website from Zero

Here is the full sequence to take a fresh server to a live WordPress site.

```bash
# 1. Check the server
hearthost doctor

# 2. Initialize the stack (run once)
hearthost init hardening --phpmyadmin-host pma.example.com
hearthost init nginx
hearthost init mariadb \
  --phpmyadmin-host pma.example.com \
  --letsencrypt-email ops@example.com
hearthost init php
hearthost init sftp
hearthost init wp
hearthost init logrotate
hearthost init backups

# 3. Verify the stack
hearthost doctor --stack

# 4. Create a tenant
hearthost user add alice --memory 1G --cpu 100%

# 5. Add the primary domain
hearthost site add alice example.com \
  --primary --app wordpress \
  --alias www.example.com \
  --microcache 10

# 6. Create the WordPress database
hearthost db create alice wordpress

# 7. Install WordPress
hearthost wp install alice example.com \
  --title "My Website" \
  --admin-email alice@example.com

# 8. (Optional) Issue SSL once DNS points here
hearthost ssl issue --user alice example.com

# 9. (Optional) Add more domains for the same user
hearthost site add alice blog.example.com --app php --php 8.4
hearthost db create alice blog

# 10. (Optional) Enable FTP
hearthost init ftp
hearthost ftp allow alice

# 11. Check everything
hearthost health
hearthost audit
```

---

## Configuration

Server-wide defaults live in `/etc/hearthost/hearthost.conf`, created by
`hearthost init hardening`. Key settings:

| Key | Default | Description |
| --- | --- | --- |
| `php_versions` | `8.2 8.3 8.4 8.5` | Available PHP versions |
| `php_default` | `8.3` | Default PHP version for new sites |
| `default_memory` | `1G` | Default RAM cap per tenant |
| `default_cpu` | `100%` | Default CPU cap per tenant |
| `ftp_enable` | `no` | Enable vsftpd (set to `yes` before `init ftp`) |
| `backup_dir` | `/backup` | Backup destination |
| `backup_keep` | `7` | Number of daily backups to retain |
| `cert_warn_days` | `14` | Health warns when cert expires within this many days |
| `disk_warn_pct` | `90` | Health warns when disk usage exceeds this percent |
