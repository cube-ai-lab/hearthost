# Input validation. No filesystem side effects.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_VALIDATE_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_VALIDATE_LOADED=1

HH_RESERVED_USERS='root daemon bin sys sync games man lp mail news uucp proxy www-data backup list irc gnats nobody systemd-network systemd-resolve systemd-timesync messagebus syslog _apt uuidd tcpdump sshd mysql mariadb nginx apache2 postfix dovecot opendkim fail2ban clamav redis memcache memcached postgres ftp vsftpd proftpd hearthost admin ubuntu debian lxd pollinate landscape tss fwupd-refresh polkitd'

hh_valid_username() {
  local name="${1:-}"
  [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
  [[ "$name" != *".."* ]] || return 1
  local reserved
  for reserved in $HH_RESERVED_USERS; do
    if [[ "$name" == "$reserved" ]]; then
      return 1
    fi
  done
  return 0
}

hh_valid_domain() {
  local d="${1:-}"
  d="${d,,}"
  [[ ${#d} -ge 1 && ${#d} -le 253 ]] || return 1
  [[ "$d" != *..* ]] || return 1
  [[ "$d" != .* && "$d" != *. ]] || return 1
  [[ "$d" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]] || return 1
  [[ "$d" == *.* ]] || return 1
  return 0
}

hh_valid_php() {
  local v="${1:-}"
  [[ "$v" =~ ^8\.(2|3|4|5)$ ]]
}

hh_valid_app() {
  case "${1:-}" in
    wordpress|laravel|php) return 0 ;;
    *) return 1 ;;
  esac
}

hh_php_allowed() {
  local v="$1"
  local allowed csv
  csv="$(hh_conf php_versions "8.2,8.3,8.4,8.5")"
  hh_valid_php "$v" || return 1
  IFS=',' read -ra allowed <<<"$csv"
  local item
  for item in "${allowed[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [[ "$item" == "$v" ]]; then
      return 0
    fi
  done
  return 1
}
