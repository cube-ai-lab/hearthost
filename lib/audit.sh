# Phase 9: defensive security scan. Read-only. Verifies the isolation the
# other phases set up actually holds on the live system: network exposure,
# tenant file ownership/modes, PHP confinement, group membership, DB bind,
# SSH policy, and per-tenant caps. Exits non-zero when findings exist.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_AUDIT_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_AUDIT_LOADED=1

# True when octal mode `actual` is no looser than `max` (actual perms are a
# subset of max perms, octet by octet). Pure.
hh_audit_mode_within() {
  local actual="$1" max="$2"
  [[ "$actual" =~ ^[0-7]{3,4}$ && "$max" =~ ^[0-7]{3,4}$ ]] || return 2
  # Normalize both to 4 octal digits (leading-zero pad).
  while (( ${#actual} < 4 )); do actual="0$actual"; done
  while (( ${#max} < 4 )); do max="0$max"; done
  local i a m
  for ((i = 0; i < 4; i++)); do
    a="${actual:i:1}"
    m="${max:i:1}"
    (( (a & ~m) == 0 )) || return 1
  done
  return 0
}

# Is a port allowed to listen on a public (non-loopback) address?
hh_audit_public_port_ok() {
  local port="$1"
  case "$port" in
    22|80|443) return 0 ;;
  esac
  if hh_conf_bool ftp_enable yes; then
    [[ "$port" == "$(hh_conf ftp_port 21)" ]] && return 0
    local pmin pmax
    pmin="$(hh_conf ftp_pasv_min 40000)"
    pmax="$(hh_conf ftp_pasv_max 40099)"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= pmin && port <= pmax )) && return 0
  fi
  return 1
}

hh_audit_run() {
  hh_require_root
  hh_os_load
  hh_config_load
  local findings=0 warns=0
  _a_ok() { printf '[ok]   %s\n' "$1"; }
  _a_bad() { printf '[RISK] %s\n' "$1"; findings=$((findings + 1)); }
  _a_warn() { printf '[warn] %s\n' "$1"; warns=$((warns + 1)); }

  printf 'Hearthost audit  v%s  (%s)\n\n' "$(hh_version)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 1. Network exposure: nothing but allowed ports on a non-loopback address.
  printf '# network\n'
  local line addr port bad_ports=""
  while read -r addr; do
    port="${addr##*:}"
    case "$addr" in
      127.0.0.*|\[::1\]*|127.0.0.53%*|127.0.0.54*) continue ;;
    esac
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    hh_audit_public_port_ok "$port" || bad_ports+=" $port($addr)"
  done < <(ss -lntuH 2>/dev/null | awk '{print $5}' | sort -u)
  if [[ -n "${bad_ports// }" ]]; then
    _a_bad "unexpected public listener(s):$bad_ports"
  else
    _a_ok "only expected ports listen publicly (22/80/443$(hh_conf_bool ftp_enable yes && printf ' + ftp'))"
  fi
  if ss -lntH 2>/dev/null | awk '{print $4}' | grep -vE '^127\.|^\[::1\]' | grep -q ':3306$'; then
    _a_bad "MariaDB 3306 is reachable on a non-loopback address"
  else
    _a_ok "MariaDB not exposed off loopback"
  fi

  # 2. Web daemon group has no tenant members.
  printf '# groups\n'
  local webgrp members
  webgrp="$(hh_os_web_user)"
  members="$(getent group "$webgrp" 2>/dev/null | awk -F: '{print $4}')"
  if [[ -n "${members// }" ]]; then
    _a_bad "group $webgrp has members ($members); tenants must never be in it"
  else
    _a_ok "group $webgrp has no tenant members"
  fi

  # 3. SSH policy.
  printf '# ssh\n'
  if grep -Eq '^[[:space:]]*AllowUsers[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null; then
    _a_bad "SSH AllowUsers is active (would override AllowGroups)"
  else
    _a_ok "no active SSH AllowUsers"
  fi
  if sshd -T 2>/dev/null | grep -q '^allowgroups '; then
    _a_ok "SSH AllowGroups enforced"
  else
    _a_warn "sshd AllowGroups not visible (run init hardening/sftp)"
  fi

  # 4. phpMyAdmin is not mounted on any tenant site.
  printf '# phpmyadmin\n'
  local pma_host sdir sf srv_names leaked=""
  pma_host="$(hh_conf phpmyadmin_host "")"
  sdir="$(dirname "$(hh_site_state x)")"
  if [[ -n "$pma_host" && -d "$sdir" ]]; then
    while IFS= read -r sf; do
      [[ -f "$sf" ]] || continue
      grep -qiE "server_name[^;]*\b${pma_host}\b" "$(hh_nginx_site_file "$(sed -n 's/^domain:[[:space:]]*//p' "$sf" | head -1)")" 2>/dev/null \
        && leaked+=" $(basename "$sf")"
    done < <(find "$sdir" -maxdepth 1 -type f -name '*.yaml')
  fi
  [[ -n "${leaked// }" ]] && _a_bad "phpMyAdmin host appears on tenant vhost(s):$leaked" \
    || _a_ok "phpMyAdmin confined to its dedicated host"

  # 5. sysctl hardening.
  printf '# kernel\n'
  [[ "$(sysctl -n kernel.kptr_restrict 2>/dev/null)" == "2" ]] \
    && _a_ok "kernel.kptr_restrict=2" || _a_warn "sysctl hardening not applied"

  # 6. Per-tenant checks.
  printf '# tenants\n'
  local dir f user home uid
  dir="$(dirname "$(hh_user_state x)")"
  if [[ -d "$dir" ]]; then
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      user="$(sed -n 's/^username:[[:space:]]*//p' "$f" | head -1)"
      [[ -n "$user" ]] && getent passwd "$user" >/dev/null || continue
      home="$(hh_user_home "$user")"

      # Home may be traversable by others (711) but never writable by
      # group/other and never readable (listable) by others. Max = 0751.
      local hmode
      hmode="$(stat -c '%a' "$home" 2>/dev/null)"
      if hh_audit_mode_within "$hmode" 0751; then
        _a_ok "$user home mode $hmode"
      else
        _a_bad "$user home mode $hmode is too open (group/other write or other read)"
      fi

      # World-writable files/dirs in the home.
      local ww
      ww="$(find "$home" -xdev \( -type f -o -type d \) -perm -0002 -not -type l 2>/dev/null | head -3)"
      [[ -n "$ww" ]] && _a_bad "$user has world-writable paths: $(echo "$ww" | tr '\n' ' ')" \
        || _a_ok "$user has no world-writable paths"

      # setuid/setgid files in the home.
      local su
      su="$(find "$home" -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | head -3)"
      [[ -n "$su" ]] && _a_bad "$user has setuid/setgid files: $(echo "$su" | tr '\n' ' ')" \
        || _a_ok "$user has no setuid/setgid files"

      # TLS private keys must be 600.
      local key kmode kbad=""
      while IFS= read -r key; do
        [[ -f "$key" ]] || continue
        kmode="$(stat -c '%a' "$key")"
        hh_audit_mode_within "$kmode" 0600 || kbad+=" $key($kmode)"
      done < <(find "$(hh_user_ssl_dir "$user")" -name 'privkey.pem' 2>/dev/null)
      [[ -n "${kbad// }" ]] && _a_bad "$user TLS key too open:$kbad" \
        || _a_ok "$user TLS keys are 600"

      # Dedicated PHP pool confinement.
      local pool pbad=""
      while IFS= read -r pool; do
        [[ -f "$pool" ]] || continue
        grep -q "^user = $user$" "$pool" || pbad+=" wrong-user"
        grep -q 'open_basedir\] = ' "$pool" || pbad+=" no-open_basedir"
        grep -q 'disable_functions\] = .*system' "$pool" || pbad+=" weak-disable_functions"
      done < <(find "$(hh_php_user_conf_dir "$user")" -name '*-pool.conf' 2>/dev/null)
      [[ -n "${pbad// }" ]] && _a_bad "$user PHP pool weak:$pbad" \
        || _a_ok "$user PHP pool confined (user, open_basedir, disable_functions)"

      # Resource cap present.
      uid="$(hh_user_uid "$user")"
      local cg="/sys/fs/cgroup/user.slice/user-${uid}.slice/memory.max"
      if [[ -f "$cg" && "$(cat "$cg" 2>/dev/null)" != "max" ]]; then
        _a_ok "$user slice capped (memory.max=$(cat "$cg"))"
      else
        _a_warn "$user slice cap not active yet (no live session/FPM, or run slice apply)"
      fi
    done < <(find "$dir" -maxdepth 1 -type f -name '*.yaml')
  fi

  printf '\n%d risk(s), %d warning(s)\n' "$findings" "$warns"
  (( findings == 0 ))
}
