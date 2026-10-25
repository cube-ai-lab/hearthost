---
name: hearthost-phase
description: Implement or extend a Hearthost phase (new `hearthost init X` / `user` / `site` / `db` / `wp` subcommand, new lib/*.sh, new template). Use when adding a feature to /root/hearthost, starting the next phase, or wiring a new service (vsftpd, systemd slices, backups, etc.).
---

# Implementing a Hearthost phase

Follow CLAUDE.md code rules. This skill is the order of work.

## 1. Locate with the graph, not by reading

```bash
cd /root/hearthost
~/.local/bin/graphify update .                 # make sure graph matches HEAD
~/.local/bin/graphify query "<what the phase touches>" --budget 1500
~/.local/bin/graphify explain "hh_<function>()"
~/.local/bin/graphify affected "hh_<function>()"   # who breaks if I change it
```

Read only the line ranges the graph points to. Read `templates/` files
directly (not in the graph).

## 2. Layering

| Layer | Where | Rule |
| --- | --- | --- |
| Names / paths | `lib/paths.sh` | pure `printf`, add here first |
| Modes / owners | `lib/perms.sh` | pure |
| Input checks | `lib/validate.sh` | pure, return 0/1 |
| Render | `lib/<area>.sh` `hh_<area>_render_*` | writes only to a `dest` arg |
| Apply | `lib/<area>.sh` `hh_<area>_apply` | root, packages, systemctl |
| CLI | `bin/hearthost` `hh_cmd_<area>` | arg parsing + validation only |
| State | `/etc/hearthost/{users,sites}.d/*.yaml` | shapes in `schemas/` |

## 3. Per-feature checklist

- [ ] Both `debian` and `rhel` branches (packages, service names, paths, web user).
- [ ] Every user-supplied value goes through `hh_valid_*` before templates/SQL/shell.
- [ ] Back up, render, validate (`nginx -t` / `sshd -t` / `php-fpmX -t`), then reload; never reload on failed validation.
- [ ] Idempotent: re-running `apply` on a configured host changes nothing.
- [ ] Unit tests in `tests/run.sh` for every pure helper and renderer (render into `mktemp`, assert on content). Use fixtures in `tests/fixtures/os-release/` for both families.
- [ ] `tests/live/phaseN.sh` (chmod 755) for the real-server checks.
- [ ] `hearthost doctor` gains checks for the new service (stack mode fails, preflight informs).
- [ ] `hh_usage` text, README Status, docs/ARCHITECTURE.md, `VERSION`, Cursor canvas updated.

## 4. Verify

```bash
./tests/run.sh
shellcheck -x bin/hearthost lib/*.sh   # if installed
~/.local/bin/graphify update .
```

On the live server, run the new `init`/command, then `tests/live/phaseN.sh`
and `./bin/hearthost doctor --stack`.

## Known traps

- Tenants run a dedicated `hearthost-php<ver>-<user>.service` (Phase 6)
  built by `hh_php_service_apply` from a private config under
  `/etc/hearthost/php/<user>/`, pinned `Slice=user-<uid>.slice`. Do NOT drop
  tenant pools into the shared `/etc/php/X/fpm/pool.d` — that runs them under
  the shared daemon's cgroup, outside the cap, and double-binds the socket.
  `hh_php_pool_file` is the shared path (phpMyAdmin only);
  `hh_php_tenant_pool_file` is the per-tenant one.
- The cap lives on `user-<uid>.slice` via a drop-in
  (`hh_user_slice_dropin`); `slice apply` writes it and `set-property`s the
  live slice. `suryasan` still uses the legacy shared pool — migrate it with
  `site add suryasan suryasankara.in ...` before relying on its cap.
- In `${var//pat/rep}` keep the replacement quoted (`/"$value"}`) as
  `hh_nginx_subst` does; unquoted, bash ≥ 5.2 expands `&` to the match.
- Tenant state goes through `hh_user_state` / `hh_site_state`
  (`/etc/hearthost/{users,sites}.d`). Set `HEARTHOST_STATE_DIR` in tests.
- SFTP chroot: `AllowGroups` lists both `hearthost-ssh` and
  `hearthost-sftp`; `Match Group hearthost-sftp` chroots to `%h`, which
  requires the home *inode* owned by root (`user add --sftp-only` sets
  root:user 750). Shell tenants keep user:user 711 and full SSH.
- `user del` detaches the tenant's sites (via `hh_site_del --keep-data`)
  before `userdel`; both keep tenant files unless `--purge`.
