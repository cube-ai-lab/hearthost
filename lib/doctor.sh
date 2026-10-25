# Preflight checks. Read-only.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_DOCTOR_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_DOCTOR_LOADED=1

hh_doctor_mem_kb() {
  awk '/^MemTotal:/ { print $2 }' /proc/meminfo
}

hh_doctor_mem_human() {
  local kb="$1"
  awk -v kb="$kb" 'BEGIN { printf "%.1f GiB", kb / 1024 / 1024 }'
}

hh_doctor_nproc() {
  nproc 2>/dev/null || printf '1'
}

hh_doctor_has_cgroup2() {
  [[ -f /sys/fs/cgroup/cgroup.controllers ]]
}

hh_doctor_controller() {
  local want="$1"
  grep -qw "$want" /sys/fs/cgroup/cgroup.controllers 2>/dev/null
}

hh_doctor_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s\n' "${ID}:${VERSION_ID}"
  else
    printf 'unknown\n'
  fi
}

hh_doctor_ram_users_supported() {
  local total_kb default_b overhead_b usable_b
  total_kb="$(hh_doctor_mem_kb)"
  default_b="$(hh_parse_bytes "$(hh_conf default_memory 1G)")" || default_b=1073741824
  # Keep ~1.5 GiB for OS, MariaDB, Nginx, PHP masters, Cursor/admin.
  overhead_b="$(hh_parse_bytes 1536M)"
  usable_b=$((total_kb * 1024 - overhead_b))
  if (( usable_b < 0 )); then
    printf '0\n'
    return 0
  fi
  printf '%s\n' $((usable_b / default_b))
}

hh_doctor_print() {
  local status="$1"
  local msg="$2"
  printf '%-8s %s\n' "[$status]" "$msg"
}

hh_doctor_run() {
  local mode="${1:-preflight}"
  local fail=0
  local warn=0
  local os mem_kb users_ok phpmyadmin_host

  hh_config_load

  printf 'Hearthost doctor  v%s  (%s)\n' "$(hh_version)" "$mode"
  printf 'root %s\n\n' "$(hearthost_root)"

  os="$(hh_doctor_os)"
  if [[ "$os" == ubuntu:24.04* || "$os" == ubuntu:24.* ]]; then
    hh_doctor_print ok "OS $os"
  else
    hh_doctor_print fail "OS $os (Ubuntu 24.04 required)"
    fail=$((fail + 1))
  fi

  if hh_doctor_has_cgroup2; then
    local missing=()
    hh_doctor_controller cpu || missing+=(cpu)
    hh_doctor_controller memory || missing+=(memory)
    hh_doctor_controller pids || missing+=(pids)
    if ((${#missing[@]})); then
      hh_doctor_print fail "cgroup v2 missing controllers: ${missing[*]}"
      fail=$((fail + 1))
    else
      hh_doctor_print ok "cgroup v2 cpu, memory, pids"
    fi
  else
    hh_doctor_print fail "cgroup v2 not mounted"
    fail=$((fail + 1))
  fi

  mem_kb="$(hh_doctor_mem_kb)"
  users_ok="$(hh_doctor_ram_users_supported)"
  if (( users_ok < 1 )); then
    hh_doctor_print warn "RAM $(hh_doctor_mem_human "$mem_kb"): default $(hh_conf default_memory 1G)/user does not fit. Raise VPS RAM before adding tenants."
    warn=$((warn + 1))
  else
    hh_doctor_print ok "RAM $(hh_doctor_mem_human "$mem_kb"): about $users_ok tenant(s) at $(hh_conf default_memory 1G) each"
  fi

  hh_doctor_print ok "CPU $(hh_doctor_nproc) cores; default quota $(hh_conf default_cpu 100%) per user"

  if [[ "$(hh_conf profile lve)" == "lve" ]]; then
    hh_doctor_print ok "profile=lve (dedicated PHP-FPM per user, 1G/1CPU default)"
  else
    hh_doctor_print warn "profile=$(hh_conf profile lve) (not the production default)"
    warn=$((warn + 1))
  fi

  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi 'Status: active'; then
      local ufw_missing=()
      ufw status 2>/dev/null | grep -Eq '22/tcp|OpenSSH' || ufw_missing+=(22)
      ufw status 2>/dev/null | grep -Eq '80/tcp' || ufw_missing+=(80)
      ufw status 2>/dev/null | grep -Eq '443/tcp' || ufw_missing+=(443)
      if ((${#ufw_missing[@]})); then
        hh_doctor_print warn "UFW active but missing ports: ${ufw_missing[*]}"
        warn=$((warn + 1))
      else
        hh_doctor_print ok "UFW active (22, 80, 443)"
      fi
    else
      hh_doctor_print warn "UFW installed but inactive (Phase 1)"
      warn=$((warn + 1))
    fi
  else
    hh_doctor_print warn "UFW not installed (Phase 1)"
    warn=$((warn + 1))
  fi

  local ssh_group
  ssh_group="$(hh_conf ssh_group hearthost-ssh)"
  if grep -Eq '^[[:space:]]*AllowUsers[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null; then
    hh_doctor_print warn "SSH AllowUsers is still active and will block tenant logins"
    warn=$((warn + 1))
  elif getent group "$ssh_group" >/dev/null && id -nG root 2>/dev/null | grep -qw "$ssh_group"; then
    if sshd -T 2>/dev/null | grep -Eq "^allowgroups .*${ssh_group}"; then
      hh_doctor_print ok "SSH AllowGroups $ssh_group (root is a member)"
    else
      hh_doctor_print warn "group $ssh_group exists but sshd is not using AllowGroups"
      warn=$((warn + 1))
    fi
  else
    hh_doctor_print warn "SSH group $ssh_group not ready (Phase 1)"
    warn=$((warn + 1))
  fi

  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    hh_doctor_print ok "fail2ban active"
  else
    hh_doctor_print warn "fail2ban not active (Phase 1)"
    warn=$((warn + 1))
  fi

  local kptr
  kptr="$(sysctl -n kernel.kptr_restrict 2>/dev/null || printf '0')"
  if [[ "$kptr" == "2" ]]; then
    hh_doctor_print ok "sysctl kernel.kptr_restrict=2"
  else
    hh_doctor_print warn "sysctl hardening not applied (Phase 1)"
    warn=$((warn + 1))
  fi

  if hh_conf_bool ftp_enable yes; then
    hh_doctor_print warn "Classic FTP on port $(hh_conf ftp_port 21) is enabled: credentials are plaintext unless the client upgrades to FTPS"
    warn=$((warn + 1))
  fi

  phpmyadmin_host="$(hh_conf phpmyadmin_host "")"
  if [[ -z "$phpmyadmin_host" ]]; then
    hh_doctor_print warn "phpmyadmin_host is empty; run init on a TTY or pass --phpmyadmin-host=pma.example.com"
    warn=$((warn + 1))
  else
    if hh_valid_domain "$phpmyadmin_host"; then
      hh_doctor_print ok "phpMyAdmin host $phpmyadmin_host"
    else
      hh_doctor_print fail "phpmyadmin_host is not a valid domain: $phpmyadmin_host"
      fail=$((fail + 1))
    fi
  fi

  local pkg
  for pkg in nginx php-fpm mysql mariadb; do
    if command -v "$pkg" >/dev/null 2>&1 || dpkg -s "$pkg" >/dev/null 2>&1 || dpkg -s "${pkg}-server" >/dev/null 2>&1; then
      hh_doctor_print ok "$pkg present"
    else
      if [[ "$mode" == "stack" ]]; then
        hh_doctor_print fail "$pkg missing"
        fail=$((fail + 1))
      else
        hh_doctor_print info "$pkg not installed yet (expected in preflight)"
      fi
    fi
  done

  printf '\n%d failure(s), %d warning(s)\n' "$fail" "$warn"
  if (( fail > 0 )); then
    return 1
  fi
  return 0
}
