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

# Certificates and ACME webroot live with the account, not under /var/www.
hh_user_ssl_dir() {
  printf '%s/ssl\n' "$(hh_user_home "$1")"
}

hh_site_ssl_dir() {
  local user="$1"
  local domain="${2,,}"
  printf '%s/%s\n' "$(hh_user_ssl_dir "$user")" "$domain"
}

hh_site_ssl_cert() {
  printf '%s/fullchain.pem\n' "$(hh_site_ssl_dir "$1" "$2")"
}

hh_site_ssl_key() {
  printf '%s/privkey.pem\n' "$(hh_site_ssl_dir "$1" "$2")"
}

# System (phpMyAdmin and other admin hostnames), not a tenant home.
hh_system_ssl_dir() {
  printf '/etc/hearthost/ssl\n'
}

hh_system_ssl_site_dir() {
  local domain="${1,,}"
  printf '%s/%s\n' "$(hh_system_ssl_dir)" "$domain"
}

hh_system_ssl_cert() {
  printf '%s/fullchain.pem\n' "$(hh_system_ssl_site_dir "$1")"
}

hh_system_ssl_key() {
  printf '%s/privkey.pem\n' "$(hh_system_ssl_site_dir "$1")"
}

hh_ssl_map_dir() {
  printf '/etc/hearthost/ssl-map\n'
}

hh_ssl_map_file() {
  printf '%s/%s\n' "$(hh_ssl_map_dir)" "${1,,}"
}

hh_certbot_live_dir() {
  printf '/etc/letsencrypt/live/%s\n' "${1,,}"
}

hh_pma_user() { printf 'hearthost-pma\n'; }
hh_pma_home() { printf '/var/lib/hearthost-pma\n'; }
hh_pma_socket() { printf '/run/php/php-fpm-hearthost-pma.sock\n'; }
hh_pma_config() { printf '/etc/hearthost/phpmyadmin/config.inc.php\n'; }

hh_pma_docroot() {
  if [[ -d /usr/share/phpmyadmin ]]; then
    printf '/usr/share/phpmyadmin\n'
  elif [[ -d /usr/share/phpMyAdmin ]]; then
    printf '/usr/share/phpMyAdmin\n'
  else
    printf '/usr/share/phpmyadmin\n'
  fi
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
