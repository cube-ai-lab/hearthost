# phpMyAdmin on a dedicated hostname, PHP-FPM pool hearthost-pma.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_PHPMYADMIN_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_PHPMYADMIN_LOADED=1

hh_pma_open_basedir() {
  local share home
  share="$(hh_pma_docroot)"
  home="$(hh_pma_home)"
  printf '%s:/etc/phpmyadmin:/etc/phpMyAdmin:/var/lib/phpmyadmin:/etc/hearthost/phpmyadmin:%s:/usr/share/php:/usr/share/javascript:/tmp\n' \
    "$share" "$home"
}

hh_distro_php_fpm_pool_dir() {
  if declare -F hh_php_fpm_pool_dir >/dev/null; then
    hh_php_fpm_pool_dir "$(hh_php_default)"
    return 0
  fi
  local dirs=(/etc/php/*/fpm/pool.d)
  if [[ -d "${dirs[0]:-}" ]]; then
    printf '%s\n' "${dirs[0]}"
    return 0
  fi
  if [[ -d /etc/php-fpm.d ]]; then
    printf '/etc/php-fpm.d\n'
    return 0
  fi
  return 1
}

hh_distro_php_fpm_service() {
  if declare -F hh_php_fpm_service >/dev/null; then
    hh_php_fpm_service "$(hh_php_default)"
    return 0
  fi
  local unit
  for unit in php8.5-fpm php8.4-fpm php8.3-fpm php8.2-fpm php-fpm; do
    if systemctl cat "${unit}.service" >/dev/null 2>&1; then
      printf '%s\n' "$unit"
      return 0
    fi
  done
  printf 'php-fpm\n'
}

hh_pma_disable_default_pool() {
  local dir="$1"
  local www="$dir/www.conf"
  [[ -f "$www" ]] || return 0
  mv -f "$www" "$dir/www.conf.hearthost-disabled"
}

hh_pma_ensure_user() {
  local user home
  user="$(hh_pma_user)"
  home="$(hh_pma_home)"
  if ! getent passwd "$user" >/dev/null; then
    useradd --system --home-dir "$home" --create-home \
      --shell /usr/sbin/nologin --comment "Hearthost phpMyAdmin" "$user"
  fi
  mkdir -p "$home/tmp"
  chown -R "$user:$user" "$home"
  chmod 700 "$home" "$home/tmp"
}

hh_pma_blowfish() {
  local file=/etc/hearthost/phpmyadmin/blowfish
  mkdir -p /etc/hearthost/phpmyadmin
  if [[ ! -s "$file" ]]; then
    openssl rand -hex 32 >"$file"
    chmod 640 "$file"
  fi
  tr -d '\n' <"$file"
}

hh_pma_write_config() {
  local host="$1"
  local dest blowfish
  dest="$(hh_pma_config)"
  blowfish="$(hh_pma_blowfish)"
  mkdir -p "$(dirname "$dest")"
  hh_nginx_subst "$(hearthost_root)/templates/phpmyadmin/config.inc.php" "$dest" \
    "BLOWFISH=$blowfish" \
    "PMA_HOST=$host" \
    "PMA_HOME=$(hh_pma_home)"
  chmod 640 "$dest"
  chown "root:$(hh_pma_user)" "$dest"

  local share
  share="$(hh_pma_docroot)"
  if [[ -d "$share" ]]; then
    ln -sfn "$dest" "$share/config.inc.php"
  fi
}

hh_pma_write_pool() {
  local dir dest
  dir="$(hh_distro_php_fpm_pool_dir)" || hh_die "php-fpm pool directory not found"
  dest="$dir/hearthost-pma.conf"
  hh_nginx_subst "$(hearthost_root)/templates/php-fpm/pma-pool.conf" "$dest" \
    "PMA_USER=$(hh_pma_user)" \
    "FPM_SOCKET=$(hh_pma_socket)" \
    "WEB_USER=$(hh_os_web_user)" \
    "PMA_HOME=$(hh_pma_home)" \
    "OPEN_BASEDIR=$(hh_pma_open_basedir)"
  chmod 644 "$dest"
  hh_pma_disable_default_pool "$dir"
}

hh_pma_render_vhost() {
  local domain="$1"
  local dest="${2:-}"
  [[ -n "$dest" ]] || dest="$(hh_nginx_site_file phpmyadmin)"
  local ssl_listen
  ssl_listen="$(hh_nginx_ssl_listen_lines)"
  hh_nginx_subst "$(hearthost_root)/templates/nginx/phpmyadmin.conf" "$dest" \
    "DOMAIN=$domain" \
    "SSL_LISTEN=$ssl_listen" \
    "SSL_ROOT=$(hh_ssl_acme_webroot_system)" \
    "SSL_CERT=$(hh_system_ssl_cert "$domain")" \
    "SSL_KEY=$(hh_system_ssl_key "$domain")" \
    "DOCROOT=$(hh_pma_docroot)" \
    "FPM_SOCKET=$(hh_pma_socket)"
}

hh_pma_apply() {
  hh_require_root
  hh_os_load
  hh_config_load

  if ! hh_conf_bool phpmyadmin_enable yes; then
    hh_info "phpmyadmin_enable=no; skipping phpMyAdmin"
    return 0
  fi

  hh_prompt_phpmyadmin_host "${HEARTHOST_PHPMYADMIN_HOST_FLAG:-}" \
    || hh_die "invalid phpmyadmin_host"

  hh_info "installing php-fpm and phpMyAdmin"
  case "$(hh_os_family)" in
    rhel)
      hh_pkg_install php-fpm php-mysqlnd php-mbstring php-xml php-json php-gd php-zip phpMyAdmin \
        || hh_pkg_install php-fpm php-mysqlnd php-mbstring php-xml php-json php-gd php-zip
      ;;
    *)
      export DEBIAN_FRONTEND=noninteractive
      echo 'phpmyadmin phpmyadmin/reconfigure-webserver multiselect' | debconf-set-selections
      echo 'phpmyadmin phpmyadmin/dbconfig-install boolean false' | debconf-set-selections
      hh_pkg_install php-fpm php-mysql php-mbstring php-xml php-curl php-zip php-gd phpmyadmin
      ;;
  esac

  hh_pma_ensure_user
  hh_pma_write_pool

  local fpm
  fpm="$(hh_distro_php_fpm_service)"
  systemctl enable --now "$fpm" >/dev/null
  systemctl restart "$fpm"

  local host
  host="$(hh_conf phpmyadmin_host "")"
  if [[ -z "$host" ]]; then
    hh_die "phpmyadmin_host is required. Pass --phpmyadmin-host FQDN (admin-provided; not stored in the installer repo)"
  fi

  hh_pma_write_config "$host"
  hh_ssl_ensure_placeholder "$(hh_system_ssl_site_dir "$host")"
  hh_pma_render_vhost "$host"
  hh_nginx_enable_site phpmyadmin

  if ! nginx -t; then
    nginx -t
    hh_die "nginx -t failed after phpMyAdmin vhost"
  fi
  hh_nginx_reload

  hh_install_template "$(hearthost_root)/templates/fail2ban/filter.d/hearthost-phpmyadmin.conf" \
    /etc/fail2ban/filter.d/hearthost-phpmyadmin.conf 0644
  hh_install_template "$(hearthost_root)/templates/fail2ban/jail.d/hearthost-phpmyadmin.conf" \
    /etc/fail2ban/jail.d/hearthost-phpmyadmin.conf 0644
  systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban || true

  if ! hh_ssl_issue_system "$host"; then
    hh_warn "Let's Encrypt not issued for $host yet. Point DNS here, then: hearthost ssl issue --system $host"
  fi

  hh_info "phpMyAdmin on https://$host/ (cookie auth, MariaDB 127.0.0.1)"
}

hh_db_stack_apply() {
  hh_config_load
  if [[ -z "$(hh_conf letsencrypt_email "")" ]]; then
    hh_die "letsencrypt_email is required. Pass --letsencrypt-email (admin-provided; not stored in the installer repo)"
  fi
  hh_ssl_apply
  hh_mariadb_apply
  hh_pma_apply
  hh_info "Phase 3 MariaDB + phpMyAdmin + Let's Encrypt applied on $(hh_os_pretty)"
}
