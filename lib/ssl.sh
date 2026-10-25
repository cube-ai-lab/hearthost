# Let's Encrypt (certbot) webroot issuance. Cert lineage stays in
# /etc/letsencrypt; published files are /home/{user}/ssl/{domain}/ or
# /etc/hearthost/ssl/{domain}/ for system hostnames.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_SSL_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_SSL_LOADED=1

hh_ssl_acme_webroot_user() {
  printf '%s\n' "$(hh_user_ssl_dir "$1")"
}

hh_ssl_acme_webroot_system() {
  printf '%s\n' "$(hh_system_ssl_dir)"
}

# Print certbot account flags, one per line (safe to mapfile).
hh_ssl_certbot_account_args() {
  local email
  email="$(hh_conf letsencrypt_email "")"
  if [[ -n "$email" ]]; then
    printf '%s\n' --email "$email" --agree-tos --non-interactive
  else
    printf '%s\n' --register-unsafely-without-email --agree-tos --non-interactive
  fi
}

hh_ssl_ensure_webroot() {
  local root="$1"
  mkdir -p "$root/.well-known/acme-challenge"
  chmod "$(hh_perm_ssl)" "$root" 2>/dev/null || chmod 711 "$root"
  chmod 755 "$root/.well-known" "$root/.well-known/acme-challenge"
}

hh_ssl_map_write() {
  local domain="${1,,}"
  local dest="$2"
  local file
  file="$(hh_ssl_map_file "$domain")"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$dest" >"$file"
  chmod 640 "$file"
}

hh_ssl_map_read() {
  local file
  file="$(hh_ssl_map_file "$1")"
  [[ -f "$file" ]] || return 1
  tr -d '[:space:]' <"$file"
}

hh_ssl_copy_live() {
  local live="$1"
  local dest="$2"
  local owner="${3:-root}"
  [[ -f "$live/fullchain.pem" && -f "$live/privkey.pem" ]] || return 1
  mkdir -p "$dest"
  install -m 644 "$live/fullchain.pem" "$dest/fullchain.pem"
  install -m 600 "$live/privkey.pem" "$dest/privkey.pem"
  if [[ -n "$owner" && "$owner" != "root" ]]; then
    chown "$owner:$owner" "$dest" "$dest/fullchain.pem" "$dest/privkey.pem" 2>/dev/null || true
    chmod "$(hh_perm_ssl)" "$dest"
  fi
}

# Self-signed stand-in so nginx -t succeeds before the first ACME run.
hh_ssl_ensure_placeholder() {
  local dest="$1"
  mkdir -p "$dest"
  if [[ -f "$dest/fullchain.pem" && -f "$dest/privkey.pem" ]]; then
    return 0
  fi
  hh_nginx_ensure_default_tls
  install -m 644 /etc/hearthost/tls/default.crt "$dest/fullchain.pem"
  install -m 600 /etc/hearthost/tls/default.key "$dest/privkey.pem"
}

hh_ssl_enable_timer() {
  local unit
  for unit in certbot.timer certbot-renew.timer; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      systemctl enable --now "$unit" >/dev/null
      return 0
    fi
  done
  hh_warn "no certbot systemd timer found; install certbot or enable renewal manually"
  return 0
}

hh_ssl_apply() {
  hh_require_root
  hh_os_load
  hh_config_load
  hh_info "installing certbot"
  hh_pkg_install certbot
  hh_ssl_ensure_webroot "$(hh_ssl_acme_webroot_system)"
  chmod 755 "$(hh_system_ssl_dir)"
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy "$(hh_ssl_map_dir)"
  hh_install_template "$(hearthost_root)/templates/ssl/deploy-hook.sh" \
    /etc/letsencrypt/renewal-hooks/deploy/hearthost.sh 0755
  hh_ssl_enable_timer
  local email
  email="$(hh_conf letsencrypt_email "")"
  if [[ -z "$email" ]]; then
    hh_warn "letsencrypt_email is empty; certbot will register without an email. Set it with --letsencrypt-email"
  fi
  hh_info "Let's Encrypt webroot + renew hook installed"
}

# Issue or renew one name. $1=webroot $2=dest $3=domain $4=owner (optional)
hh_ssl_issue_webroot() {
  local webroot="$1"
  local dest="$2"
  local domain="${3,,}"
  local owner="${4:-root}"
  local staging="${HEARTHOST_SSL_STAGING:-}"
  hh_valid_domain "$domain" || { hh_error "invalid domain: $domain"; return 1; }
  hh_ssl_ensure_webroot "$webroot"
  hh_ssl_ensure_placeholder "$dest"
  hh_ssl_map_write "$domain" "$dest"
  if [[ "$owner" != "root" ]]; then
    chown "$owner:$owner" "$webroot" "$dest" 2>/dev/null || true
    chmod "$(hh_perm_ssl)" "$webroot" "$dest"
  fi

  local args=()
  mapfile -t args < <(hh_ssl_certbot_account_args)
  if [[ -n "$staging" ]]; then
    args+=(--staging)
  fi
  args+=(certonly --webroot -w "$webroot" --cert-name "$domain" -d "$domain" --keep-until-expiring --quiet)

  if ! command -v certbot >/dev/null 2>&1; then
    hh_error "certbot is not installed; run hearthost init ssl"
    return 1
  fi

  if ! certbot "${args[@]}"; then
    hh_warn "certbot did not issue $domain (DNS A/AAAA must point here; HTTP-01 on port 80). Keeping placeholder cert."
    return 1
  fi

  hh_ssl_copy_live "$(hh_certbot_live_dir "$domain")" "$dest" "$owner"
}

hh_ssl_issue_user() {
  local user="$1"
  local domain="$2"
  hh_valid_username "$user" || { hh_error "invalid username: $user"; return 1; }
  hh_ssl_issue_webroot \
    "$(hh_ssl_acme_webroot_user "$user")" \
    "$(hh_site_ssl_dir "$user" "$domain")" \
    "$domain" \
    "$user"
}

hh_ssl_issue_system() {
  local domain="$1"
  hh_ssl_issue_webroot \
    "$(hh_ssl_acme_webroot_system)" \
    "$(hh_system_ssl_site_dir "$domain")" \
    "$domain" \
    root
}
