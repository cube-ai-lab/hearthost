# Phase 8: per-tenant backups (files + databases) with retention, plus the
# nightly systemd timer. Databases are dumped through the root socket; files
# are tarred from the tenant home. Pure helpers (paths, retention) are
# unit-testable.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_BACKUP_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_BACKUP_LOADED=1

hh_backup_root() {
  hh_conf backup_dir /var/backups/hearthost
}

hh_backup_user_dir() {
  printf '%s/%s\n' "$(hh_backup_root)" "$1"
}

hh_backup_keep() {
  hh_conf backup_keep 7
}

hh_backup_stamp() {
  date -u +%Y%m%d-%H%M%S
}

# Given a newline list of snapshot dir names (any order) and a keep count,
# print the ones to delete (oldest beyond keep). Names sort lexically, which
# matches the YYYYMMDD-HHMMSS stamp. Pure.
hh_backup_prune_list() {
  local keep="$1"
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=7
  sort -r | awk -v k="$keep" 'NR>k'
}

hh_backup_prune() {
  local user="$1"
  local dir keep
  dir="$(hh_backup_user_dir "$user")"
  keep="$(hh_backup_keep)"
  [[ -d "$dir" ]] || return 0
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    rm -rf "${dir:?}/${name:?}"
  done < <(find "$dir" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | hh_backup_prune_list "$keep")
}

# Dump every user_% database to dest/db/. Best effort.
hh_backup_databases() {
  local user="$1" dest="$2"
  command -v mysqldump >/dev/null 2>&1 || { hh_warn "mysqldump absent; skipping DB backup for $user"; return 0; }
  mysqladmin --protocol=socket -uroot ping >/dev/null 2>&1 || { hh_warn "MariaDB unreachable; skipping DB backup for $user"; return 0; }
  mkdir -p "$dest/db"
  local like db count=0
  like="$(hh_db_like "$user")"
  like="${like/_/\\_}"
  while IFS= read -r db; do
    [[ -n "$db" ]] || continue
    if mysqldump --protocol=socket -uroot --single-transaction --quick \
      --routines --triggers "$db" 2>/dev/null | gzip >"$dest/db/${db}.sql.gz"; then
      count=$((count + 1))
    else
      hh_warn "mysqldump failed for $db"
      rm -f "$dest/db/${db}.sql.gz"
    fi
  done < <(mysql --protocol=socket -uroot -N -B -e "SHOW DATABASES LIKE '${like}';" 2>/dev/null)
  printf '%s\n' "$count"
}

# Tar the tenant home, minus volatile dirs. Keys are included (640/600) so a
# restore is complete; the archive itself is root-only (700 dir).
hh_backup_files() {
  local user="$1" dest="$2"
  local home_root home
  home_root="$(hh_home_root)"
  home="$(hh_user_home "$user")"
  [[ -d "$home" ]] || { hh_warn "home $home missing; skipping file backup"; return 0; }
  tar czf "$dest/home.tar.gz" \
    --exclude="./$user/tmp" \
    --exclude="./$user/.cache" \
    --warning=no-file-changed \
    -C "$home_root" "./$user" 2>/dev/null || true
  [[ -f "$dest/home.tar.gz" ]]
}

# Back up one tenant into backup_dir/<user>/<stamp>/.
hh_backup_tenant() {
  local user="$1"
  hh_valid_username "$user" || { hh_error "invalid username: $user"; return 1; }
  getent passwd "$user" >/dev/null || { hh_error "user $user does not exist"; return 1; }
  local base dest stamp dbcount
  base="$(hh_backup_user_dir "$user")"
  stamp="$(hh_backup_stamp)"
  dest="$base/$stamp"
  mkdir -p "$dest"
  chmod 700 "$(hh_backup_root)" "$base" "$dest"

  dbcount="$(hh_backup_databases "$user" "$dest")"
  hh_backup_files "$user" "$dest" || hh_warn "file archive incomplete for $user"
  {
    printf 'user=%s\n' "$user"
    printf 'stamp=%s\n' "$stamp"
    printf 'databases=%s\n' "${dbcount:-0}"
    printf 'host=%s\n' "$(hostname -f 2>/dev/null || hostname)"
  } >"$dest/manifest.txt"

  hh_backup_prune "$user"
  local size
  size="$(du -sh "$dest" 2>/dev/null | cut -f1)"
  hh_info "backup $user -> $dest (${size:-?}, ${dbcount:-0} db)"
}

# hearthost backup run [USER]  (no USER = every tenant with a state record)
hh_backup_run() {
  hh_require_root
  hh_os_load
  hh_config_load
  local user="${1:-}"
  if [[ -n "$user" ]]; then
    hh_backup_tenant "$user"
    return $?
  fi
  local dir f n=0
  dir="$(dirname "$(hh_user_state x)")"
  [[ -d "$dir" ]] || { hh_info "no tenants to back up"; return 0; }
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    user="$(sed -n 's/^username:[[:space:]]*//p' "$f" | head -1)"
    [[ -n "$user" ]] && getent passwd "$user" >/dev/null || continue
    hh_backup_tenant "$user" && n=$((n + 1))
  done < <(find "$dir" -maxdepth 1 -type f -name '*.yaml')
  hh_info "backed up $n tenant(s) to $(hh_backup_root)"
}

hh_backup_list() {
  hh_config_load
  local user="${1:-}"
  local root
  root="$(hh_backup_root)"
  [[ -d "$root" ]] || { hh_info "no backups yet ($root)"; return 0; }
  local base
  if [[ -n "$user" ]]; then
    base="$(hh_backup_user_dir "$user")"
    [[ -d "$base" ]] || { hh_info "no backups for $user"; return 0; }
    find "$base" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort -r
  else
    find "$root" -maxdepth 2 -mindepth 2 -type d -printf '%P\n' 2>/dev/null | sort
  fi
}

# Install + enable the nightly backup timer.
hh_backup_timer_apply() {
  hh_require_root
  hh_os_load
  hh_config_load
  local root bin
  root="$(hearthost_root)"
  bin="$root/bin/hearthost"
  hh_nginx_subst "$root/templates/systemd/hearthost-backup.service" \
    /etc/systemd/system/hearthost-backup.service "BIN=$bin"
  install -m 0644 "$root/templates/systemd/hearthost-backup.timer" \
    /etc/systemd/system/hearthost-backup.timer
  mkdir -p "$(hh_backup_root)"
  chmod 700 "$(hh_backup_root)"
  systemctl daemon-reload
  systemctl enable --now hearthost-backup.timer >/dev/null
  hh_info "nightly backup timer enabled (backup_dir=$(hh_backup_root), keep=$(hh_backup_keep))"
}

# Install the per-tenant logrotate config and verify it parses.
hh_logrotate_apply() {
  hh_require_root
  hh_os_load
  local root dest
  root="$(hearthost_root)"
  dest=/etc/logrotate.d/hearthost
  install -m 0644 "$root/templates/logrotate/hearthost" "$dest"
  if command -v logrotate >/dev/null 2>&1; then
    if ! logrotate -d "$dest" >/dev/null 2>&1; then
      hh_warn "logrotate config installed but failed a dry run; check $dest"
    fi
  else
    hh_warn "logrotate not installed; config written to $dest for later"
  fi
  hh_info "per-tenant log rotation installed ($dest)"
}

hh_backup_cmd() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    run) hh_backup_run "$@" ;;
    list|ls) hh_backup_list "$@" ;;
    *) hh_die "usage: hearthost backup run [USER] | backup list [USER]" ;;
  esac
}
