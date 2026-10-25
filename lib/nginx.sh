# Nginx install, snippets, default server, and vhost rendering.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_NGINX_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_NGINX_LOADED=1

hh_nginx_snippets_dir() { printf '/etc/nginx/snippets\n'; }
hh_nginx_confd_dir() { printf '/etc/nginx/conf.d\n'; }

hh_nginx_sites_available() {
  case "$(hh_os_family)" in
    debian) printf '/etc/nginx/sites-available\n' ;;
    *) printf '/etc/nginx/conf.d\n' ;;
  esac
}

hh_nginx_sites_enabled() {
  case "$(hh_os_family)" in
    debian) printf '/etc/nginx/sites-enabled\n' ;;
    *) printf '/etc/nginx/conf.d\n' ;;
  esac
}

hh_nginx_site_file() {
  local name="$1"
  case "$(hh_os_family)" in
    debian) printf '%s/%s.conf\n' "$(hh_nginx_sites_available)" "$name" ;;
    *) printf '%s/vhost-%s.conf\n' "$(hh_nginx_confd_dir)" "$name" ;;
  esac
}

hh_nginx_enable_site() {
  local name="$1"
  local src dest
  src="$(hh_nginx_site_file "$name")"
  case "$(hh_os_family)" in
    debian)
      dest="$(hh_nginx_sites_enabled)/${name}.conf"
      ln -sfn "$src" "$dest"
      ;;
    *)
      [[ -f "$src" ]] || return 1
      ;;
  esac
}

hh_nginx_disable_distro_default() {
  rm -f /etc/nginx/sites-enabled/default
  rm -f /etc/nginx/conf.d/default.conf
}

# Replace {{KEY}} tokens. Remaining args are KEY=value.
hh_nginx_subst() {
  local src="$1"
  local dest="$2"
  shift 2
  local content pair key value
  content="$(cat "$src")"
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    content="${content//\{\{$key\}\}/$value}"
  done
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "$content" >"$dest"
}

hh_nginx_version() {
  nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p'
}

# $1 = "default" to add default_server. Nginx 1.25+ uses `http2 on;`.
hh_nginx_ssl_listen_lines() {
  local ds=""
  if [[ "${1:-}" == "default" ]]; then
    ds=" default_server"
  fi
  local ver major minor
  ver="$(hh_nginx_version)"
  major="${ver%%.*}"
  minor="${ver#*.}"
  minor="${minor%%.*}"
  if [[ -n "$ver" ]] && ((major > 1 || (major == 1 && minor >= 25))); then
    printf '    listen 443 ssl%s;\n    listen [::]:443 ssl%s;\n    http2 on;\n' "$ds" "$ds"
  else
    printf '    listen 443 ssl http2%s;\n    listen [::]:443 ssl http2%s;\n' "$ds" "$ds"
  fi
}

hh_nginx_ensure_default_tls() {
  local dir=/etc/hearthost/tls
  mkdir -p "$dir"
  chmod 750 "$dir"
  if [[ -f "$dir/default.crt" && -f "$dir/default.key" ]]; then
    return 0
  fi
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "$dir/default.key" \
    -out "$dir/default.crt" \
    -subj "/CN=hearthost-default" >/dev/null 2>&1
  chmod 640 "$dir/default.key"
  chmod 644 "$dir/default.crt"
}

hh_nginx_test() {
  nginx -t >/dev/null 2>&1
}

hh_nginx_reload() {
  systemctl enable --now nginx >/dev/null
  systemctl reload nginx
}

hh_nginx_apply() {
  hh_require_root
  hh_os_load
  hh_os_supported || hh_die "unsupported OS: $(hh_os_pretty). Need $(hh_os_supported_list)"
  local root snip
  root="$(hearthost_root)"
  snip="$(hh_nginx_snippets_dir)"

  hh_info "installing nginx"
  hh_pkg_install nginx openssl

  mkdir -p "$snip" "$(hh_nginx_confd_dir)"
  mkdir -p "$(hh_nginx_sites_available)" "$(hh_nginx_sites_enabled)"
  hh_nginx_ensure_default_tls

  local modules_include="" sites_include=""
  if [[ -d /etc/nginx/modules-enabled ]]; then
    modules_include="include /etc/nginx/modules-enabled/*.conf;"
  fi
  if [[ -d /etc/nginx/sites-enabled ]]; then
    sites_include="    include /etc/nginx/sites-enabled/*;"
  fi
  hh_backup_file /etc/nginx/nginx.conf >/dev/null
  hh_nginx_subst "$root/templates/nginx/nginx.conf" /etc/nginx/nginx.conf \
    "WEB_USER=$(hh_os_web_user)" \
    "MODULES_INCLUDE=$modules_include" \
    "SITES_INCLUDE=$sites_include"
  chmod 644 /etc/nginx/nginx.conf
  hh_install_template "$root/templates/nginx/http.conf" \
    "$(hh_nginx_confd_dir)/00-hearthost.conf" 0644
  hh_install_template "$root/templates/nginx/ssl-params.conf" \
    "$snip/hearthost-ssl-params.conf" 0644
  hh_install_template "$root/templates/nginx/php.conf" \
    "$snip/hearthost-php.conf" 0644
  hh_install_template "$root/templates/nginx/headers.conf" \
    "$snip/hearthost-headers.conf" 0644
  hh_install_template "$root/templates/nginx/dotfiles.conf" \
    "$snip/hearthost-dotfiles.conf" 0644
  hh_install_template "$root/templates/nginx/acme.conf" \
    "$snip/hearthost-acme.conf" 0644
  hh_install_template "$root/templates/nginx/wordpress.conf" \
    "$snip/hearthost-wordpress.conf" 0644
  hh_install_template "$root/templates/nginx/laravel.conf" \
    "$snip/hearthost-laravel.conf" 0644

  local ssl_listen default_dest
  ssl_listen="$(hh_nginx_ssl_listen_lines default)"
  default_dest="$(hh_nginx_site_file hearthost-default)"
  hh_nginx_subst "$root/templates/nginx/default-server.conf" "$default_dest" \
    "SSL_LISTEN=$ssl_listen"
  hh_nginx_disable_distro_default
  hh_nginx_enable_site hearthost-default

  if ! nginx -t; then
    nginx -t
    hh_die "nginx -t failed; not reloading"
  fi
  hh_nginx_reload
  hh_info "Phase 2 nginx applied on $(hh_os_pretty)"
}

# Used by later site-add. Safe to unit-test without root.
hh_nginx_render_vhost() {
  local user="$1"
  local domain="$2"
  local docroot="$3"
  local app="$4"
  local log_dir="$5"
  local socket="${6:-}"
  local dest="${7:-}"
  local aliases="${8:-}"
  local root src
  root="$(hearthost_root)"
  src="$root/templates/nginx/vhost.conf"
  local ssl_listen
  ssl_listen="$(hh_nginx_ssl_listen_lines)"
  local alias_txt=""
  if [[ -n "$aliases" ]]; then
    alias_txt=" $aliases"
  fi
  [[ -n "$dest" ]] || dest="$(hh_nginx_site_file "$domain")"
  hh_nginx_subst "$src" "$dest" \
    "DOMAIN=$domain" \
    "ALIASES=$alias_txt" \
    "DOCROOT=$docroot" \
    "LOG_DIR=$log_dir" \
    "APP=$app" \
    "SSL_LISTEN=$ssl_listen" \
    "SSL_ROOT=$(hh_user_ssl_dir "$user")" \
    "SSL_CERT=$(hh_site_ssl_cert "$user" "$domain")" \
    "SSL_KEY=$(hh_site_ssl_key "$user" "$domain")" \
    "FPM_SOCKET=$socket"
}
