# Path and naming conventions.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_PATHS_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_PATHS_LOADED=1

hh_home_root() {
  hh_conf home_root /home
}

hh_user_home() {
  local user="$1"
  printf '%s/%s\n' "$(hh_home_root)" "$user"
}

hh_primary_dirname() {
  hh_conf primary_docroot public_html
}

# Usage: hh_site_docroot USER DOMAIN PRIMARY
# PRIMARY is "yes"/"true"/"1" for the account's main site.
hh_site_docroot() {
  local user="$1"
  local domain="$2"
  local primary="${3:-no}"
  local home
  home="$(hh_user_home "$user")"
  case "${primary,,}" in
    1|yes|true|on|primary)
      printf '%s/%s\n' "$home" "$(hh_primary_dirname)"
      ;;
    *)
      printf '%s/%s\n' "$home" "${domain,,}"
      ;;
  esac
}

hh_user_logs() {
  printf '%s/logs\n' "$(hh_user_home "$1")"
}

hh_user_tmp() {
  printf '%s/tmp\n' "$(hh_user_home "$1")"
}

hh_user_sessions() {
  printf '%s/tmp/sessions\n' "$(hh_user_home "$1")"
}

hh_fpm_socket() {
  local php="$1"
  local user="$2"
  printf '/run/php/php%s-fpm-%s.sock\n' "$php" "$user"
}

hh_user_slice() {
  local user="$1"
  printf 'hearthost-%s.slice\n' "$user"
}

# Database name for a tenant. If NAME already has the user prefix, keep it.
hh_db_name() {
  local user="$1"
  local name="$2"
  local sep
  sep="$(hh_conf mysql_prefix_separator _)"
  if [[ "$name" == "${user}${sep}"* ]]; then
    printf '%s\n' "$name"
  else
    printf '%s%s%s\n' "$user" "$sep" "$name"
  fi
}

hh_db_user() {
  hh_db_name "$@"
}

hh_db_like() {
  local user="$1"
  local sep
  sep="$(hh_conf mysql_prefix_separator _)"
  printf '%s%s%%\n' "$user" "$sep"
}

hh_site_state() {
  local domain="${1,,}"
  printf '%s/etc/sites.d/%s.yaml\n' "$(hearthost_root)" "$domain"
}

hh_user_state() {
  local user="$1"
  printf '%s/etc/users.d/%s.yaml\n' "$(hearthost_root)" "$user"
}
