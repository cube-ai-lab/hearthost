# Phase 7: WP-CLI and WordPress install. WordPress runs as the tenant Unix
# user; it reaches MariaDB over the local socket with unix_socket auth, so no
# DB password is stored. Pure helpers (name/args) are unit-testable.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_WP_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_WP_LOADED=1

hh_wpcli_path() { printf '/usr/local/bin/wp\n'; }
hh_wpcli_url() { printf 'https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar\n'; }

# The WordPress database for a tenant: {user}_wp by default.
hh_wp_db_name() {
  hh_db_name "$1" "$(hh_conf wp_db_name wp)"
}

# WordPress reaches MariaDB via the socket; "localhost:<socket>" tells mysqli
# to use it (so unix_socket auth matches the FPM worker's Unix user).
hh_wp_db_host() {
  local sock
  for sock in /run/mysqld/mysqld.sock /var/run/mysqld/mysqld.sock /var/lib/mysql/mysql.sock; do
    [[ -S "$sock" ]] && { printf 'localhost:%s\n' "$sock"; return 0; }
  done
  printf 'localhost\n'
}

hh_wpcli_installed() {
  [[ -x "$(hh_wpcli_path)" ]]
}

hh_wpcli_install() {
  hh_require_root
  if hh_wpcli_installed; then
    hh_info "wp-cli already present ($("$(hh_wpcli_path)" --version --allow-root 2>/dev/null | head -1))"
    return 0
  fi
  command -v php >/dev/null 2>&1 || hh_die "php CLI not found; run hearthost init php"
  local dest tmp
  dest="$(hh_wpcli_path)"
  tmp="$(mktemp)"
  hh_info "downloading wp-cli"
  if ! curl -fsSL -o "$tmp" "$(hh_wpcli_url)"; then
    rm -f "$tmp"
    hh_die "could not download wp-cli from $(hh_wpcli_url)"
  fi
  php "$tmp" --info >/dev/null 2>&1 || { rm -f "$tmp"; hh_die "downloaded wp-cli phar failed its self-check"; }
  install -m 0755 "$tmp" "$dest"
  rm -f "$tmp"
  hh_info "wp-cli installed at $dest"
}

# Run wp as the tenant, from the docroot, under the site's PHP binary (so the
# version's mysqli/pdo_mysql are present), with HOME in the tenant home.
hh_wp_run() {
  local user="$1" docroot="$2" php_bin="$3"
  shift 3
  local home
  home="$(hh_user_home "$user")"
  runuser -u "$user" -- env HOME="$home" WP_CLI_PHP="$php_bin" \
    "$php_bin" "$(hh_wpcli_path)" --path="$docroot" "$@"
}

# hearthost wp install USER DOMAIN [--title T] [--admin-user U]
#   [--admin-email E] [--admin-password PW]
hh_wp_install() {
  hh_require_root
  hh_os_load
  hh_config_load
  hh_wpcli_installed || hh_die "wp-cli not installed; run hearthost init wp"

  local user="${1:-}" domain="${2:-}"
  shift 2 2>/dev/null || true
  local title="" admin_user="admin" admin_email="" admin_pw=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) title="${2:-}"; shift ;;
      --title=*) title="${1#*=}" ;;
      --admin-user) admin_user="${2:-}"; shift ;;
      --admin-user=*) admin_user="${1#*=}" ;;
      --admin-email) admin_email="${2:-}"; shift ;;
      --admin-email=*) admin_email="${1#*=}" ;;
      --admin-password) admin_pw="${2:-}"; shift ;;
      --admin-password=*) admin_pw="${1#*=}" ;;
      *) hh_die "usage: hearthost wp install USER DOMAIN [--title T] [--admin-user U] [--admin-email E] [--admin-password PW]" ;;
    esac
    shift
  done

  [[ -n "$user" && -n "$domain" ]] || hh_die "usage: hearthost wp install USER DOMAIN [...]"
  hh_valid_username "$user" || hh_die "invalid username: $user"
  getent passwd "$user" >/dev/null || hh_die "user $user does not exist"
  hh_valid_domain "$domain" || hh_die "invalid domain: $domain"
  domain="${domain,,}"

  local state docroot site_php php_bin
  state="$(hh_site_state "$domain")"
  [[ -f "$state" ]] || hh_die "no site $domain; run hearthost site add $user $domain --primary first"
  docroot="$(sed -n 's/^docroot:[[:space:]]*//p' "$state" | head -1)"
  [[ -n "$docroot" && -d "$docroot" ]] || hh_die "docroot for $domain not found"
  site_php="$(sed -n 's/^php:[[:space:]]*//p' "$state" | head -1 | tr -d '"')"
  hh_php_allowed "$site_php" || site_php="$(hh_php_default)"
  php_bin="$(hh_php_bin "$site_php")"
  [[ -x "$php_bin" ]] || php_bin="php$site_php"
  command -v "$php_bin" >/dev/null 2>&1 || php_bin="$(hh_php_bin "$site_php")"

  [[ -n "$title" ]] || title="$domain"
  [[ -n "$admin_email" ]] || admin_email="admin@$domain"
  [[ -n "$admin_pw" ]] || admin_pw="$(openssl rand -base64 18 2>/dev/null | tr -d '/+=' | cut -c1-20)"

  local dbname dbhost
  dbname="$(hh_wp_db_name "$user")"
  dbhost="$(hh_wp_db_host)"
  hh_db_create "$user" "$(hh_conf wp_db_name wp)" >/dev/null

  if hh_wp_run "$user" "$docroot" "$php_bin" core is-installed >/dev/null 2>&1; then
    hh_die "WordPress is already installed at $docroot"
  fi

  hh_info "downloading WordPress core into $docroot"
  hh_wp_run "$user" "$docroot" "$php_bin" core download --force >/dev/null \
    || hh_die "wp core download failed"

  hh_wp_run "$user" "$docroot" "$php_bin" config create \
    --dbname="$dbname" --dbuser="$user" --dbpass="" --dbhost="$dbhost" \
    --skip-check --force >/dev/null \
    || hh_die "wp config create failed"

  hh_info "installing WordPress at https://$domain/"
  hh_wp_run "$user" "$docroot" "$php_bin" core install \
    --url="https://$domain" --title="$title" \
    --admin_user="$admin_user" --admin_password="$admin_pw" \
    --admin_email="$admin_email" --skip-email >/dev/null \
    || hh_die "wp core install failed"

  hh_info "WordPress ready: https://$domain/wp-admin/"
  hh_info "  admin user:  $admin_user"
  hh_info "  admin email: $admin_email"
  hh_info "  admin pass:  $admin_pw  (store it now; not saved)"
}

hh_wp_cmd() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    install) hh_wp_install "$@" ;;
    *) hh_die "usage: hearthost wp install USER DOMAIN [--title T] [--admin-user U] [--admin-email E] [--admin-password PW]" ;;
  esac
}
