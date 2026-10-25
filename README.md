# Hearthost

Command-line multi-tenant web hosting for Ubuntu LTS and AlmaLinux. Hearthost
turns a fresh VPS into a shared host where each customer is an isolated Unix
account with its own sites, PHP version, database access, and RAM/CPU limits,
all managed from a single `hearthost` command. There is no web control panel.

- **Isolation by default:** one Unix user per customer, a dedicated PHP-FPM
  master per user, and systemd cgroup v2 caps (1 GB RAM / 1 CPU by default).
- **WordPress and Laravel first:** WP-CLI install, OPcache tuning, optional
  FastCGI microcache.
- **Batteries included:** Nginx, MariaDB, phpMyAdmin on a dedicated hostname,
  Let's Encrypt, SFTP, optional FTPS, nightly backups, log rotation, health
  checks, and a read-only security audit.
- **Repeatable:** every step is a command, so the same sequence works on any
  server. Nothing is hand-edited.

## Supported systems

| Family | Versions | Firewall | Auto-updates |
| --- | --- | --- | --- |
| Ubuntu LTS | 22.04, 24.04, and later even-year `.04` releases | UFW | unattended-upgrades |
| AlmaLinux | 9.x, 10.x | firewalld | dnf-automatic |

Interim Ubuntu releases (for example 25.04) and other distributions are
rejected by design. Debian, Rocky Linux, and RHEL are not claimed as supported.

Requirements: a root shell, a public IPv4 address, and roughly
`1 GB × tenants + 1.5 GB` of RAM for system overhead.

## Quick start

```bash
git clone https://github.com/cube-ai-lab/hearthost.git
cd hearthost
./tests/run.sh                  # unit tests, no root needed
sudo ./bin/hearthost doctor     # preflight: OS, RAM, cgroups, ports
```

Then bring up the stack once, in order:

```bash
sudo ./bin/hearthost init hardening --phpmyadmin-host pma.example.com
sudo ./bin/hearthost init nginx
sudo ./bin/hearthost init mariadb --phpmyadmin-host pma.example.com --letsencrypt-email ops@example.com
sudo ./bin/hearthost init php
sudo ./bin/hearthost init sftp
sudo ./bin/hearthost init slices
sudo ./bin/hearthost init wp
sudo ./bin/hearthost init logrotate
sudo ./bin/hearthost init backups
sudo ./bin/hearthost doctor --stack   # verify the full stack
```

Optional: `sudo ./bin/hearthost init ftp` after setting `ftp_enable=yes`.

The phpMyAdmin hostname and Let's Encrypt email are never stored in this
repository. Pass them as flags, set them in `/etc/hearthost/hearthost.conf`,
or enter them at the interactive prompt.

## Adding a customer and a website

```bash
# 1. Create the account (1 GB RAM / 1 CPU by default)
sudo hearthost user add alice

# 2. Add the primary site with a www alias and a 10-second microcache
sudo hearthost site add alice example.com --app wordpress --primary \
     --alias www.example.com --microcache 10

# 3. Create a database and a database-only login
sudo hearthost db create alice shop
sudo hearthost db user create alice shop shopuser --password 'S3cret!'

# 4. Install WordPress (optional)
sudo hearthost wp install alice example.com --title "Example" --admin-email me@example.com

# 5. Issue the TLS certificate once DNS points at this server
sudo hearthost ssl issue --user alice example.com
```

Point the domain's A/AAAA record at the server before step 5. Until the
certificate is issued, Nginx serves a self-signed placeholder so the
configuration still validates.

Files are uploaded over SFTP as the account user, into
`/home/alice/public_html` for the primary site, or `/home/alice/{domain}` for
additional domains.

## Command overview

| Area | Commands |
| --- | --- |
| Accounts | `user add`, `user del [--purge]` |
| Sites | `site add`, `site del [--purge]` |
| Databases | `db create`, `db user create\|list\|del` |
| WordPress | `wp install` |
| TLS | `ssl issue --user U D`, `ssl issue --system D` |
| Resources | `slice apply`, `init slices` |
| Operations | `backup run\|list`, `health`, `audit`, `doctor [--stack]` |
| Services | `init hardening\|nginx\|mariadb\|php\|sftp\|ftp\|slices\|wp\|logrotate\|backups` |
| Utilities | `php versions\|pool`, `ftp allow\|deny`, `path …`, `quota …`, `validate …`, `os`, `version` |

Run `hearthost help` for usage, or see the full
[CLI reference](docs/CLI-REFERENCE.md).

## Backups

Backups follow the cPanel layout:

```
/backup/
  2026-10-25/
    accounts/
      alice.tar.gz      # home directory + database dumps + manifest
```

The nightly timer (`init backups`) runs `backup run` for every account and
keeps the newest `backup_keep` days (default 7). `backup_dir` is configurable.

## Configuration

Server settings live in `/etc/hearthost/hearthost.conf`, created by
`init hardening`. A commented example is in
[etc/hearthost.conf.example](etc/hearthost.conf.example). Common keys:

| Key | Default | Meaning |
| --- | --- | --- |
| `php_versions` | `8.2 8.3 8.4 8.5` | PHP versions offered per site |
| `php_default` | `8.3` | Version for new sites |
| `default_memory` / `default_cpu` | `1G` / `100%` | Per-account caps |
| `ftp_enable` | `no` | Enable vsftpd (FTPS) |
| `backup_dir` / `backup_keep` | `/backup` / `7` | Backup location and retention |
| `cert_warn_days` / `disk_warn_pct` | `14` / `90` | Thresholds for `health` |

## Security model

- Tenant files are owned by the tenant (`user:user`). The web server never
  owns them and tenants are never added to its group.
- Each tenant's PHP runs as that user, with `open_basedir`, disabled
  dangerous functions, and its own socket.
- Database logins are scoped to the `{user}_%` pattern. Database-only logins
  see a single database.
- SSH is restricted to the `hearthost-ssh` group. SFTP-only accounts are
  chrooted to their home.
- `hearthost audit` checks exposure, file modes, PHP confinement, group
  membership, database bind address, and SSH policy. It exits non-zero on risk.

Report vulnerabilities privately as described in [docs/SECURITY.md](docs/SECURITY.md).

## Documentation

- [CLI reference](docs/CLI-REFERENCE.md): every command, flag, and example
- [Architecture](docs/ARCHITECTURE.md): layout, ownership rules, request path
- [Security](docs/SECURITY.md): threat model and reporting
- [GitHub setup](docs/GITHUB.md): repository and branch conventions

## Development

```bash
./tests/run.sh          # must pass before every commit
shellcheck -x bin/hearthost lib/*.sh
```

- Shell only. Entry point is `bin/hearthost`, logic in `lib/*.sh`, config
  rendered from `templates/`.
- Functions are named `hh_<area>_<verb>`. Output uses `printf`, never `echo`.
- Pure helpers (rendering, validation, SQL text) stay separate from root-only
  appliers so they can be unit-tested without root.
- Every user-supplied value passes through `lib/validate.sh` before it reaches
  a template, SQL, or a shell command.
- Each phase ships a live check in `tests/live/phaseN.sh`, which must be run
  on a real server.

## Status

Version 1.0.0. All nine planned phases are complete: hardening, Nginx and TLS,
MariaDB and phpMyAdmin, multi-PHP, tenant and site lifecycle, per-tenant
resource slices, WordPress tooling, backups and health checks, and isolation
tests with the audit scan.

## Contributing

Issues and pull requests are welcome. Please keep changes small, add unit
tests for new pure helpers, and never commit machine addresses, hostnames,
credentials, or customer data. Sample values in docs and tests should use
`example.com` and documentation IP ranges.

## License

MIT. See [LICENSE](LICENSE).
