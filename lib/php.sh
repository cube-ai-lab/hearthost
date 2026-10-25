# Multi-PHP FPM (8.2–8.5). Tenant pools run as the Unix user.
# phpMyAdmin keeps its own hearthost-pma pool on default_php.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_PHP_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_PHP_LOADED=1

hh_php_versions() {
  local csv item
  csv="$(hh_conf php_versions "8.2,8.3,8.4,8.5")"
  IFS=',' read -ra items <<<"$csv"
  local item
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] || continue
    printf '%s\n' "$item"
  done
}

hh_php_default() {
  hh_conf default_php 8.3
}

# Remi package prefix: 8.3 -> 83
hh_php_ver_nodot() {
  local v="$1"
  printf '%s\n' "${v//./}"
}

hh_php_fpm_service() {
  local v="$1"
  case "$(hh_os_family)" in
    rhel) printf 'php%s-php-fpm\n' "$(hh_php_ver_nodot "$v")" ;;
    *) printf 'php%s-fpm\n' "$v" ;;
  esac
}

hh_php_fpm_pool_dir() {
  local v="${1:-}"
  [[ -n "$v" ]] || v="$(hh_php_default)"
  case "$(hh_os_family)" in
    rhel)
      local d="/etc/opt/remi/php$(hh_php_ver_nodot "$v")/php-fpm.d"
      if [[ -d "$d" ]]; then
        printf '%s\n' "$d"
      else
        printf '/etc/php-fpm.d\n'
      fi
      ;;
    *)
      printf '/etc/php/%s/fpm/pool.d\n' "$v"
      ;;
  esac
}

hh_php_pool_file() {
  local user="$1"
  local v="$2"
  printf '%s/hearthost-%s.conf\n' "$(hh_php_fpm_pool_dir "$v")" "$user"
}

hh_php_bin() {
  local v="$1"
  case "$(hh_os_family)" in
    rhel) printf '/opt/remi/php%s/root/usr/bin/php\n' "$(hh_php_ver_nodot "$v")" ;;
    *) printf '/usr/bin/php%s\n' "$v" ;;
  esac
}

hh_php_fpm_bin() {
  local v="$1"
  case "$(hh_os_family)" in
    rhel) printf '/opt/remi/php%s/root/usr/sbin/php-fpm\n' "$(hh_php_ver_nodot "$v")" ;;
    *) printf '/usr/sbin/php-fpm%s\n' "$v" ;;
  esac
}

# Print the first error from `php-fpm -t`. Returns 1 when the config is valid
# or the binary is missing.
hh_php_fpm_config_error() {
  local v="$1"
  local bin out
  bin="$(hh_php_fpm_bin "$v")"
  [[ -x "$bin" ]] || return 1
  out="$("$bin" -t 2>&1)" && return 1
  out="$(printf '%s\n' "$out" | grep -m1 'ERROR' || printf '%s\n' "$out" | head -1)"
  # Drop the "[25-Oct-2026 10:33:24] ERROR: " prefix.
  printf '%s\n' "${out#*ERROR: }"
}

hh_php_packages() {
  local v="$1"
  case "$(hh_os_family)" in
    rhel)
      local p="php$(hh_php_ver_nodot "$v")-php"
      printf '%s-fpm %s-cli %s-mysqlnd %s-mbstring %s-xml %s-gd %s-opcache %s-intl %s-bcmath %s-soap %s-process %s-pdo\n' \
        "$p" "$p" "$p" "$p" "$p" "$p" "$p" "$p" "$p" "$p" "$p" "$p"
      ;;
    *)
      printf 'php%s-fpm php%s-cli php%s-mysql php%s-xml php%s-mbstring php%s-curl php%s-zip php%s-gd php%s-intl php%s-bcmath php%s-soap php%s-opcache php%s-readline\n' \
        "$v" "$v" "$v" "$v" "$v" "$v" "$v" "$v" "$v" "$v" "$v" "$v" "$v"
      ;;
  esac
}

# Count loadable pool files for a version (*.conf, excluding *.disabled).
hh_php_active_pool_count() {
  local v="$1"
  local dir
  dir="$(hh_php_fpm_pool_dir "$v")"
  [[ -d "$dir" ]] || { printf '0\n'; return 0; }
  local n
  n="$(find "$dir" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | wc -l)"
  printf '%s\n' "$n"
}

hh_php_disable_www() {
  local v="$1"
  local dir www
  dir="$(hh_php_fpm_pool_dir "$v")"
  www="$dir/www.conf"
  [[ -f "$www" ]] || return 0
  mv -f "$www" "$dir/www.conf.hearthost-disabled"
}

hh_php_ensure_run_dir() {
  mkdir -p /run/php
  chmod 755 /run/php
  printf 'd /run/php 0755 root root -\n' >/etc/tmpfiles.d/hearthost-php.conf
}

hh_php_render_pool() {
  local user="$1"
  local ver="$2"
  local dest="${3:-}"
  hh_valid_username "$user" || return 1
  hh_php_allowed "$ver" || return 1
  [[ -n "$dest" ]] || dest="$(hh_php_pool_file "$user" "$ver")"
  local mem children home
  mem="$(hh_conf default_memory 1G)"
  children="$(hh_php_max_children "$mem")"
  home="$(hh_user_home "$user")"
  hh_nginx_subst "$(hearthost_root)/templates/php-fpm/pool.conf.snippet" "$dest" \
    "USER=$user" \
    "FPM_SOCKET=$(hh_fpm_socket "$ver" "$user")" \
    "WEB_USER=$(hh_os_web_user)" \
    "MAX_CHILDREN=$children" \
    "HOME=$home" \
    "PHP_MEMORY_LIMIT=$(hh_conf php_memory_limit 256M)"
}

# Render a tenant pool for one version and load it: validate the FPM config,
# then reload (not restart) so other tenants on this version keep serving.
# Root. Returns non-zero without touching the service if the config is bad.
hh_php_pool_apply() {
  local user="$1"
  local ver="$2"
  hh_valid_username "$user" || { hh_error "invalid username: $user"; return 1; }
  hh_php_allowed "$ver" || { hh_error "PHP $ver not in php_versions"; return 1; }
  hh_php_version_installed "$ver" || { hh_error "PHP $ver FPM is not installed; run hearthost init php"; return 1; }
  hh_php_ensure_run_dir
  local dest svc err
  dest="$(hh_php_pool_file "$user" "$ver")"
  hh_php_render_pool "$user" "$ver" "$dest" || { hh_error "failed to render pool $dest"; return 1; }
  chmod 644 "$dest"
  if err="$(hh_php_fpm_config_error "$ver")"; then
    hh_error "PHP $ver pool config rejected: $err"
    rm -f "$dest"
    return 1
  fi
  svc="$(hh_php_fpm_service "$ver")"
  systemctl enable --now "$svc" >/dev/null 2>&1 || true
  systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc"
  hh_info "PHP $ver pool for $user active ($svc)"
}

hh_php_ensure_ubuntu_repo() {
  if compgen -G '/etc/apt/sources.list.d/*ondrej*php*' >/dev/null; then
    return 0
  fi
  hh_pkg_install software-properties-common ca-certificates gnupg
  add-apt-repository -y ppa:ondrej/php >/dev/null
}

hh_php_ensure_almalinux_repo() {
  if hh_pkg_installed remi-release; then
    return 0
  fi
  local release
  release="$(hh_os_major)"
  dnf -y install "https://rpms.remirepo.net/enterprise/remi-release-${release}.rpm" >/dev/null
}

hh_php_install_version() {
  local v="$1"
  # shellcheck disable=SC2046
  hh_pkg_install $(hh_php_packages "$v")
}

hh_php_version_installed() {
  local v="$1"
  local bin svc
  bin="$(hh_php_bin "$v")"
  svc="$(hh_php_fpm_service "$v")"
  [[ -x "$bin" ]] || command -v "php$v" >/dev/null 2>&1 || hh_pkg_installed "php$v-fpm" \
    || hh_pkg_installed "php$(hh_php_ver_nodot "$v")-php-fpm"
}

hh_php_apply() {
  hh_require_root
  hh_os_load
  hh_os_supported || hh_die "unsupported OS: $(hh_os_pretty). Need $(hh_os_supported_list)"
  hh_config_load

  hh_info "installing PHP-FPM $(hh_php_versions | tr '\n' ' ')"
  case "$(hh_os_family)" in
    debian) hh_php_ensure_ubuntu_repo ;;
    rhel) hh_php_ensure_almalinux_repo ;;
  esac

  hh_php_ensure_run_dir

  local v installed=0
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    if hh_php_install_version "$v"; then
      hh_php_disable_www "$v"
      local svc
      svc="$(hh_php_fpm_service "$v")"
      systemctl enable --now "$svc" >/dev/null 2>&1 || systemctl restart "$svc"
      installed=$((installed + 1))
      hh_info "PHP $v FPM ready ($svc)"
    else
      hh_warn "PHP $v packages are not available on $(hh_os_pretty)"
    fi
  done < <(hh_php_versions)

  if (( installed < 1 )); then
    hh_die "no PHP-FPM versions installed"
  fi

  # Keep phpMyAdmin on default_php after extra versions appear.
  if declare -F hh_pma_write_pool >/dev/null; then
    hh_pma_write_pool
    systemctl restart "$(hh_php_fpm_service "$(hh_php_default)")" >/dev/null 2>&1 || true
  fi

  hh_info "Phase 4 PHP-FPM applied ($installed version(s)) on $(hh_os_pretty)"
}
