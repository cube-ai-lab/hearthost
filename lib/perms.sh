# cPanel-style ownership: website files are always USER:USER.
# www-data / nginx never owns tenant files. That account only:
#   1. runs the Nginx worker
#   2. is the PHP-FPM socket group so Nginx can connect
# shellcheck shell=bash

if [[ -n "${HEARTHOST_PERMS_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_PERMS_LOADED=1

# Directory / file modes (octal, no leading-zero arithmetic).
hh_perm_home() { printf '711\n'; }       # traverse, no listing for others
hh_perm_webroot() { printf '755\n'; }    # Nginx can read static files
hh_perm_dir() { printf '755\n'; }
hh_perm_file() { printf '644\n'; }
hh_perm_secret() { printf '640\n'; }     # wp-config.php and similar
hh_perm_logs() { printf '750\n'; }
hh_perm_tmp() { printf '700\n'; }
hh_perm_ssl() { printf '711\n'; }        # Nginx workers traverse for ACME
hh_perm_ssl_key() { printf '600\n'; }    # master process is root, can still load

# Owner:group for tenant paths. Always the Unix account, never the web daemon.
hh_perm_owner() {
  local user="$1"
  printf '%s:%s\n' "$user" "$user"
}

# True when a username is the Nginx/Apache daemon, not a tenant.
hh_perm_is_web_daemon() {
  local name="$1"
  case "$name" in
    www-data|nginx|apache|apache2|httpd|nobody) return 0 ;;
    *) return 1 ;;
  esac
}

hh_perm_apply_dir() {
  local path="$1"
  local user="$2"
  local mode="$3"
  [[ -n "$path" && -n "$user" && -n "$mode" ]] || return 1
  hh_perm_is_web_daemon "$user" && return 1
  chown "$user:$user" "$path"
  chmod "$mode" "$path"
}
