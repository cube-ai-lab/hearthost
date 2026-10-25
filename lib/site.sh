# Site provisioning: vhost + per-user PHP pool + TLS for any user/domain/app.
# Phase 5. Pure helpers (docroot layout, state YAML) are unit-testable;
# hh_site_add is the root applier that wires the primitives together.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_SITE_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_SITE_LOADED=1

# Snippet name for the app. Unknown apps fall back to plain php.
hh_site_app_snippet() {
  case "${1:-php}" in
    wordpress|laravel|php) printf '%s\n' "$1" ;;
    *) printf 'php\n' ;;
  esac
}

# Render the /etc/hearthost/sites.d/{domain}.yaml record. Pure.
hh_site_state_yaml() {
  local user="$1" domain="${2,,}" primary="$3" php="$4" app="$5" ssl="$6" aliases="$7" microcache="${8:-0}"
  printf 'domain: %s\n' "$domain"
  printf 'user: %s\n' "$user"
  printf 'primary: %s\n' "$primary"
  printf 'php: "%s"\n' "$php"
  printf 'app: %s\n' "$app"
  printf 'ssl: %s\n' "$ssl"
  printf 'microcache: %s\n' "$microcache"
  printf 'docroot: %s\n' "$(hh_site_docroot "$user" "$domain" "$primary")"
  printf 'aliases: [%s]\n' "$aliases"
  printf 'created: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# server_name aliases ("www.example.com foo.example.com"), each validated.
hh_site_alias_list() {
  local domain="${1,,}"
  shift || true
  local a out=""
  for a in "$@"; do
    a="${a,,}"
    [[ -n "$a" ]] || continue
    hh_valid_domain "$a" || { hh_error "invalid alias: $a"; return 1; }
    [[ "$a" != "$domain" ]] || continue
    out+="${out:+ }$a"
  done
  printf '%s\n' "$out"
}

# Create docroot and the account's logs/tmp/ssl dirs as USER:USER.
hh_site_ensure_dirs() {
  local user="$1" docroot="$2" label="${3:-$2}"
  local home logs tmp sessions ssl
  home="$(hh_user_home "$user")"
  logs="$(hh_user_logs "$user")"
  tmp="$(hh_user_tmp "$user")"
  sessions="$(hh_user_sessions "$user")"
  ssl="$(hh_user_ssl_dir "$user")"
  [[ -d "$home" ]] || { hh_error "home $home does not exist (run hearthost user add $user first)"; return 1; }
  mkdir -p "$docroot" "$logs" "$tmp" "$sessions" "$ssl"
  hh_perm_apply_dir "$docroot" "$user" "$(hh_perm_webroot)"
  hh_perm_apply_dir "$logs" "$user" "$(hh_perm_logs)"
  hh_perm_apply_dir "$tmp" "$user" "$(hh_perm_tmp)"
  hh_perm_apply_dir "$sessions" "$user" "$(hh_perm_tmp)"
  hh_perm_apply_dir "$ssl" "$user" "$(hh_perm_ssl)"
  # A landing page so the vhost serves something before the tenant uploads.
  if ! compgen -G "$docroot/index.*" >/dev/null; then
    printf '<!doctype html><title>%s</title><h1>%s</h1><p>Hosted by Hearthost.</p>\n' \
      "$label" "$label" >"$docroot/index.html"
    chown "$user:$user" "$docroot/index.html"
    chmod "$(hh_perm_file)" "$docroot/index.html"
  fi
}

# hearthost site add USER DOMAIN [--php V] [--app A] [--primary]
#   [--alias NAME]... [--no-ssl]
hh_site_add() {
  hh_require_root
  hh_os_load
  hh_os_supported || hh_die "unsupported OS: $(hh_os_pretty). Need $(hh_os_supported_list)"
  hh_config_load

  local user="${1:-}" domain="${2:-}"
  shift 2 2>/dev/null || true
  local php app primary=no ssl=yes microcache
  php="$(hh_php_default)"
  app=wordpress
  microcache="$(hh_conf microcache_seconds 0)"
  local -a aliases=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --php) php="${2:-}"; shift ;;
      --php=*) php="${1#*=}" ;;
      --app) app="${2:-}"; shift ;;
      --app=*) app="${1#*=}" ;;
      --primary) primary=yes ;;
      --alias) aliases+=("${2:-}"); shift ;;
      --alias=*) aliases+=("${1#*=}") ;;
      --no-ssl) ssl=no ;;
      --microcache) microcache="${2:-}"; shift ;;
      --microcache=*) microcache="${1#*=}" ;;
      *) hh_die "usage: hearthost site add USER DOMAIN [--php V] [--app wordpress|laravel|php] [--primary] [--alias NAME]... [--no-ssl] [--microcache SECONDS]" ;;
    esac
    shift
  done
  [[ "$microcache" =~ ^[0-9]+$ ]] || hh_die "--microcache must be a non-negative integer (seconds)"

  [[ -n "$user" && -n "$domain" ]] || hh_die "usage: hearthost site add USER DOMAIN [...]"
  hh_valid_username "$user" || hh_die "invalid username: $user"
  getent passwd "$user" >/dev/null || hh_die "user $user does not exist (run hearthost user add $user first)"
  hh_valid_domain "$domain" || hh_die "invalid domain: $domain"
  hh_php_allowed "$php" || hh_die "PHP $php is not in php_versions"
  app="$(hh_site_app_snippet "$app")"

  domain="${domain,,}"
  local alias_txt
  alias_txt="$(hh_site_alias_list "$domain" "${aliases[@]}")" || hh_die "invalid alias"

  local docroot socket log_dir site_file ssl_dir
  docroot="$(hh_site_docroot "$user" "$domain" "$primary")"
  socket="$(hh_fpm_socket "$php" "$user")"
  log_dir="$(hh_user_logs "$user")"
  site_file="$(hh_nginx_site_file "$domain")"
  ssl_dir="$(hh_site_ssl_dir "$user" "$domain")"

  hh_info "site add $domain -> $docroot (user=$user php=$php app=$app)"
  hh_site_ensure_dirs "$user" "$docroot" "$domain" || hh_die "could not prepare directories"
  # Phase 6: dedicated FPM master in the tenant slice, then cap the slice.
  hh_php_service_apply "$user" "$php" || hh_die "could not attach PHP $php master for $user"
  hh_slice_apply "$user" >/dev/null || hh_warn "could not apply slice cap for $user"

  # Placeholder cert so nginx -t passes before DNS/ACME works.
  hh_ssl_ensure_placeholder "$ssl_dir"
  chown "$user:$user" "$ssl_dir" "$ssl_dir/fullchain.pem" "$ssl_dir/privkey.pem" 2>/dev/null || true
  chmod "$(hh_perm_ssl)" "$ssl_dir"

  (( microcache > 0 )) && hh_nginx_ensure_microcache_zone
  hh_backup_file "$site_file" >/dev/null
  hh_nginx_render_vhost "$user" "$domain" "$docroot" "$app" "$log_dir" "$socket" "$site_file" "$alias_txt" "$microcache"
  hh_nginx_enable_site "$domain"

  if ! nginx -t; then
    rm -f "$site_file"
    case "$(hh_os_family)" in debian) rm -f "$(hh_nginx_sites_enabled)/${domain}.conf" ;; esac
    hh_die "nginx -t failed; removed $domain vhost, not reloading"
  fi
  hh_nginx_reload

  local state
  state="$(hh_site_state "$domain")"
  mkdir -p "$(dirname "$state")"
  hh_site_state_yaml "$user" "$domain" "$primary" "$php" "$app" "$ssl" "$alias_txt" "$microcache" >"$state"
  chmod 640 "$state"

  if [[ "$ssl" == yes ]]; then
    if hh_ssl_issue_user "$user" "$domain"; then
      hh_info "TLS issued for $domain"
    else
      hh_warn "Let's Encrypt not issued yet. Point DNS A/AAAA for $domain here, then: hearthost ssl issue --user $user $domain"
    fi
  fi

  hh_info "site $domain is live (https://$domain/)"
}

# hearthost site del DOMAIN [--purge | --keep-data]
# Removes the vhost and state record. Tenant files under the docroot are kept
# unless --purge. The shared per-user PHP pool is left (other sites use it).
hh_site_del() {
  hh_require_root
  hh_os_load
  hh_config_load

  local domain="${1:-}"
  shift || true
  local purge=no
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge) purge=yes ;;
      --keep-data) purge=no ;;
      *) hh_die "usage: hearthost site del DOMAIN [--purge]" ;;
    esac
    shift
  done

  [[ -n "$domain" ]] || hh_die "usage: hearthost site del DOMAIN [--purge]"
  hh_valid_domain "$domain" || hh_die "invalid domain: $domain"
  domain="${domain,,}"

  local site_file state user docroot
  site_file="$(hh_nginx_site_file "$domain")"
  state="$(hh_site_state "$domain")"

  case "$(hh_os_family)" in
    debian) rm -f "$(hh_nginx_sites_enabled)/${domain}.conf" ;;
  esac
  rm -f "$site_file"
  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
      hh_nginx_reload
    else
      hh_warn "nginx -t failed after removing $domain; check other vhosts"
    fi
  fi

  if [[ "$purge" == yes && -f "$state" ]]; then
    user="$(sed -n 's/^user:[[:space:]]*//p' "$state" | head -1)"
    docroot="$(sed -n 's/^docroot:[[:space:]]*//p' "$state" | head -1)"
    if [[ -n "$user" && -n "$docroot" && "$docroot" == "$(hh_user_home "$user")"/* ]]; then
      rm -rf "${docroot:?}"
      hh_warn "purged docroot $docroot"
    fi
  fi

  rm -f "$state"
  hh_info "site $domain removed"
}
