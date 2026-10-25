# Tenant account lifecycle: create/remove the Unix user, home layout,
# group membership, MariaDB grant, and state record. Phase 5.
# Pure helpers (shell choice, layout spec, state YAML) are unit-testable;
# hh_user_add / hh_user_del are the root appliers.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_USER_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_USER_LOADED=1

hh_user_ssh_group() { hh_conf ssh_group hearthost-ssh; }
hh_user_sftp_group() { hh_conf sftp_group hearthost-sftp; }

# Login shell. SFTP-only tenants get nologin; sshd forces internal-sftp.
hh_user_shell() {
  case "${1:-shell}" in
    sftp-only|sftp) printf '/usr/sbin/nologin\n' ;;
    *) printf '/bin/bash\n' ;;
  esac
}

# Primary access group for the account.
hh_user_access_group() {
  case "${1:-shell}" in
    sftp-only|sftp) hh_user_sftp_group ;;
    *) hh_user_ssh_group ;;
  esac
}

# Home owner:mode. A chrooted SFTP jail needs a root-owned home inode;
# tenant *files* stay user-owned in the subdirs below. Shell tenants keep
# the cPanel-style user-owned home.
hh_user_home_owner() {
  case "${1:-shell}" in
    sftp-only|sftp) printf 'root\n' ;;
    *) printf '%s\n' "$2" ;;
  esac
}

hh_user_home_mode() {
  case "${1:-shell}" in
    sftp-only|sftp) printf '750\n' ;;
    *) hh_perm_home ;;
  esac
}

# Subdirectories every tenant home gets, as "relpath mode" lines. All user:user.
hh_user_layout_spec() {
  printf '%s %s\n' "$(hh_primary_dirname)" "$(hh_perm_webroot)"
  printf 'logs %s\n' "$(hh_perm_logs)"
  printf 'tmp %s\n' "$(hh_perm_tmp)"
  printf 'tmp/sessions %s\n' "$(hh_perm_tmp)"
  printf 'ssl %s\n' "$(hh_perm_ssl)"
}

hh_user_ensure_layout() {
  local user="$1"
  local home rel mode
  home="$(hh_user_home "$user")"
  while read -r rel mode; do
    [[ -n "$rel" ]] || continue
    mkdir -p "$home/$rel"
    hh_perm_apply_dir "$home/$rel" "$user" "$mode"
  done < <(hh_user_layout_spec)
}

# /etc/hearthost/users.d/{user}.yaml record. Pure.
hh_user_state_yaml() {
  local user="$1" mode="$2" shell="$3" memory="$4" cpu="$5" tasks="$6"
  printf 'username: %s\n' "$user"
  printf 'shell: %s\n' "$shell"
  printf 'ssh: %s\n' "$([[ "$mode" == sftp-only || "$mode" == sftp ]] && echo false || echo true)"
  printf 'sftp: true\n'
  printf 'ftp: %s\n' "$(hh_conf_bool ftp_enable yes && echo true || echo false)"
  printf 'memory: %s\n' "$memory"
  printf 'cpu: %s\n' "$cpu"
  printf 'tasks: %s\n' "$tasks"
  printf 'created: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# Create the MariaDB login (unix_socket) and user_% grant. Best effort:
# skips cleanly when MariaDB is not running.
hh_user_db_grant() {
  local user="$1"
  command -v mysql >/dev/null 2>&1 || { hh_warn "mysql client absent; skipping DB grant for $user"; return 0; }
  mysqladmin --protocol=socket -uroot ping >/dev/null 2>&1 || { hh_warn "MariaDB not reachable; skipping DB grant for $user"; return 0; }
  hh_db_tenant_grant_sql "$user" | mysql --protocol=socket -uroot \
    && hh_info "MariaDB login $user (unix_socket) can use $(hh_db_like "$user")"
}

hh_user_db_drop() {
  local user="$1"
  command -v mysql >/dev/null 2>&1 || return 0
  mysqladmin --protocol=socket -uroot ping >/dev/null 2>&1 || return 0
  mysql --protocol=socket -uroot -e "DROP USER IF EXISTS '${user}'@'localhost';" >/dev/null 2>&1 || true
}

# hearthost user add USER [--sftp-only] [--password PW] [--no-db]
#   [--memory M] [--cpu C]
hh_user_add() {
  hh_require_root
  hh_os_load
  hh_os_supported || hh_die "unsupported OS: $(hh_os_pretty). Need $(hh_os_supported_list)"
  hh_config_load

  local user="${1:-}"
  shift || true
  local mode=shell password="" want_db=yes memory cpu tasks
  memory="$(hh_conf default_memory 1G)"
  cpu="$(hh_conf default_cpu 100%)"
  tasks="$(hh_conf default_tasks 120)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sftp-only) mode=sftp-only ;;
      --password) password="${2:-}"; shift ;;
      --password=*) password="${1#*=}" ;;
      --no-db) want_db=no ;;
      --memory) memory="${2:-}"; shift ;;
      --memory=*) memory="${1#*=}" ;;
      --cpu) cpu="${2:-}"; shift ;;
      --cpu=*) cpu="${1#*=}" ;;
      *) hh_die "usage: hearthost user add USER [--sftp-only] [--password PW] [--no-db] [--memory M] [--cpu C]" ;;
    esac
    shift
  done

  [[ -n "$user" ]] || hh_die "usage: hearthost user add USER [...]"
  hh_valid_username "$user" || hh_die "invalid username: $user"
  ! getent passwd "$user" >/dev/null || hh_die "user $user already exists"

  local shell group home owner hmode
  shell="$(hh_user_shell "$mode")"
  group="$(hh_user_access_group "$mode")"
  home="$(hh_user_home "$user")"
  owner="$(hh_user_home_owner "$mode" "$user")"
  hmode="$(hh_user_home_mode "$mode")"

  hh_ensure_group "$group"
  hh_info "creating $user (mode=$mode shell=$shell group=$group)"
  useradd --create-home --home-dir "$home" --shell "$shell" --user-group "$user"
  usermod -aG "$group" "$user"

  chown "$owner:$user" "$home"
  chmod "$hmode" "$home"
  hh_user_ensure_layout "$user"

  if [[ -z "$password" && "$mode" == sftp-only ]]; then
    password="$(openssl rand -base64 18 2>/dev/null | tr -d '/+=' | cut -c1-20)"
    hh_info "generated password for $user: $password  (store it now; not saved)"
  fi
  if [[ -n "$password" ]]; then
    printf '%s:%s\n' "$user" "$password" | chpasswd
  else
    passwd -l "$user" >/dev/null 2>&1 || true
  fi

  [[ "$want_db" == yes ]] && hh_user_db_grant "$user"

  if hh_conf_bool ftp_enable yes && declare -F hh_ftp_allow_user >/dev/null; then
    hh_ftp_allow_user "$user"
  fi

  local state
  state="$(hh_user_state "$user")"
  mkdir -p "$(dirname "$state")"
  hh_user_state_yaml "$user" "$mode" "$shell" "$memory" "$cpu" "$tasks" >"$state"
  chmod 640 "$state"

  hh_info "user $user ready. Home $home. Add a site: hearthost site add $user DOMAIN --primary"
}

# hearthost user del USER [--purge]
hh_user_del() {
  hh_require_root
  hh_os_load
  hh_config_load

  local user="${1:-}"
  shift || true
  local purge=no
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge) purge=yes ;;
      *) hh_die "usage: hearthost user del USER [--purge]" ;;
    esac
    shift
  done

  [[ -n "$user" ]] || hh_die "usage: hearthost user del USER [--purge]"
  hh_valid_username "$user" || hh_die "refusing reserved or invalid username: $user"
  getent passwd "$user" >/dev/null || hh_die "user $user does not exist"

  # Remove the tenant's sites first so no vhost points at a gone account.
  local dir domain removed=0
  dir="$(dirname "$(hh_site_state "x")")"
  if [[ -d "$dir" ]]; then
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      if grep -qE "^user:[[:space:]]*${user}$" "$f"; then
        domain="$(sed -n 's/^domain:[[:space:]]*//p' "$f" | head -1)"
        [[ -n "$domain" ]] && { hh_site_del "$domain" --keep-data >/dev/null 2>&1 || true; removed=$((removed + 1)); }
      fi
    done < <(find "$dir" -maxdepth 1 -type f -name '*.yaml')
  fi

  hh_user_db_drop "$user"
  declare -F hh_ftp_deny_user >/dev/null && hh_ftp_deny_user "$user"

  if [[ "$purge" == yes ]]; then
    userdel --remove "$user" 2>/dev/null || userdel -r "$user"
    hh_warn "purged home $(hh_user_home "$user") and all tenant data for $user"
  else
    userdel "$user"
    hh_info "kept home $(hh_user_home "$user"); pass --purge to delete tenant data"
  fi

  rm -f "$(hh_user_state "$user")"
  hh_info "user $user removed ($removed site(s) detached)"
}
