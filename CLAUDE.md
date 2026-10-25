# Hearthost

CLI-first multi-tenant hosting (Bash) for Ubuntu even-year LTS ≥ 22.04 and
AlmaLinux 9/10. Entry point `bin/hearthost`; logic in `lib/*.sh`; config
files rendered from `templates/`. Phases 0–4 are done (see
docs/ARCHITECTURE.md "Phases"); the next one is Phase 5 (user/site CLI).

## Code rules

- Every `lib/*.sh` starts with `# shellcheck shell=bash` and a load guard
  (`HEARTHOST_<NAME>_LOADED`). New libs are sourced in `bin/hearthost` and
  `tests/run.sh`.
- Functions are `hh_<area>_<verb>`. Output via `printf`, never `echo`.
  Logging via `hh_info`/`hh_warn`/`hh_error`/`hh_die` (stderr).
- Paths come from `lib/paths.sh`, modes and owners from `lib/perms.sh`,
  settings from `hh_conf KEY default`. Don't hardcode `/home/...` or modes
  in other libs.
- Tenant files are always `user:user`. `www-data`/`nginx` never owns tenant
  files and tenants are never added to its group; it only appears as
  `listen.group` on the FPM socket.
- Distro differences branch on `hh_os_family` (`debian` | `rhel`). Every
  new feature handles both: apt/UFW/unattended-upgrades vs dnf/firewalld/
  dnf-automatic, `www-data` vs `nginx`, ondrej vs Remi paths.
- `*_apply` functions start with `hh_require_root`, `hh_os_load`,
  `hh_os_supported || hh_die`, `hh_config_load`; back up files with
  `hh_backup_file` before editing; validate (`nginx -t`, `sshd -t`,
  `php-fpm -t`) before any reload, and never reload on failure.
- Templates use `{{KEY}}` tokens rendered by `hh_nginx_subst`. Validate
  every value with `lib/validate.sh` before it reaches a template or SQL.
- Keep side-effect-free helpers (render to a `dest` argument, build SQL as
  text) separate from appliers so they are unit-testable without root.

## Tests

- `./tests/run.sh` (unit, no root, uses `tests/fixtures/os-release/*` via
  `HEARTHOST_OS_RELEASE`) must pass before every commit.
- Each phase adds `tests/live/phaseN.sh` (chmod 755) for checks on a real
  server after `hearthost init ...`.

## Never commit

Machine IPs, PTR hostnames, the phpMyAdmin hostname, Let's Encrypt email,
`/etc/hearthost/hearthost.conf`, user/site YAML, keys, or passwords. These
are admin-supplied at install time (flag, env, TTY prompt, or the target's
config file).

## Finishing a phase

Bump `VERSION`, update the README "Status" section, the `hh_usage` text, the
phase list in docs/ARCHITECTURE.md, and the Cursor canvas at
`/root/.cursor/projects/root/canvases/hearthost-architecture.canvas.tsx`.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- When graphify-out/graph.json exists, run `graphify query "<question>"` before your first grep, search or source-file read for a codebase question, and put this rule in every subagent prompt that explores code. Read raw files only for lines the graph or an earlier read already located. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
- A committed graphify-out/graph.json is rewritten whole on every build, so a large diff to it in a pull request is expected. Do not flag it as churn or suggest skipping the graph rebuild or its hooks.
- `graphify` lives in `/root/.local/bin`, which is not on the default PATH; call it as `~/.local/bin/graphify`.
- The graph covers `.sh` code and markdown only. Files under `templates/` (`.conf`, `.snippet`, etc.) are not in it, so read them directly.
