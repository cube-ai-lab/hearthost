# Phase 1 hardening. Sourced by the CLI. File helpers are unit-testable.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_HARDENING_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_HARDENING_LOADED=1

hh_require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    hh_die "this command must run as root"
  fi
}

hh_backup_file() {
  local src="$1"
  local dir="${HEARTHOST_BACKUP_DIR:-/etc/hearthost/backups}"
  [[ -f "$src" ]] || return 0
  mkdir -p "$dir"
  local base dest
  base="$(basename "$src")"
  dest="$dir/${base}.$(date +%Y%m%d%H%M%S)"
  cp -a "$src" "$dest"
  printf '%s\n' "$dest"
}

# Comment active AllowUsers lines. OpenSSH ANDs AllowUsers with AllowGroups,
# and AllowUsers root would block every tenant.
hh_sshd_disable_allowusers_in_file() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local tmp
  tmp="$(mktemp)"
  awk '
    /^[[:space:]]*AllowUsers[[:space:]]+/ && $0 !~ /^[[:space:]]*#/ {
      print "# hearthost: " $0
      next
    }
    { print }
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

hh_sshd_has_active_allowusers() {
  local file="$1"
  grep -Eq '^[[:space:]]*AllowUsers[[:space:]]+' "$file" 2>/dev/null
}

hh_ensure_group() {
  local name="$1"
  if getent group "$name" >/dev/null; then
    return 0
  fi
  groupadd --system "$name"
}

hh_ensure_in_group() {
  local user="$1"
  local group="$2"
  id -nG "$user" | grep -qw "$group" && return 0
  usermod -aG "$group" "$user"
}

hh_install_template() {
  local src="$1"
  local dest="$2"
  local mode="${3:-0644}"
  mkdir -p "$(dirname "$dest")"
  install -m "$mode" "$src" "$dest"
}

hh_ufw_allow_tcp() {
  local port="$1"
  ufw status 2>/dev/null | grep -Eq "^${port}/tcp[[:space:]]+ALLOW" && return 0
  ufw allow "${port}/tcp" comment "hearthost"
}

hh_harden_packages() {
  case "$(hh_os_family)" in
    debian)
      hh_info "installing packages (fail2ban, ufw, unattended-upgrades)"
      hh_pkg_install fail2ban ufw unattended-upgrades
      ;;
    rhel)
      hh_info "installing packages (fail2ban, firewalld, dnf-automatic)"
      hh_pkg_install fail2ban firewalld dnf-automatic
      ;;
    *)
      hh_die "unsupported OS family $(hh_os_family)"
      ;;
  esac
}

hh_harden_firewall() {
  case "$(hh_os_family)" in
    debian)
      hh_info "UFW: deny incoming, allow 22/80/443"
      ufw default deny incoming >/dev/null
      ufw default allow outgoing >/dev/null
      ufw allow OpenSSH comment "hearthost-ssh" >/dev/null
      hh_ufw_allow_tcp 80 >/dev/null
      hh_ufw_allow_tcp 443 >/dev/null
      ufw --force enable >/dev/null
      ;;
    rhel)
      hh_info "firewalld: ssh, http, https"
      systemctl enable --now firewalld >/dev/null
      firewall-cmd --permanent --add-service=ssh >/dev/null
      firewall-cmd --permanent --add-service=http >/dev/null
      firewall-cmd --permanent --add-service=https >/dev/null
      firewall-cmd --reload >/dev/null
      ;;
  esac
}

hh_harden_autoupdates() {
  local root
  root="$(hearthost_root)"
  case "$(hh_os_family)" in
    debian)
      hh_info "unattended upgrades"
      hh_install_template "$root/templates/apt/20auto-upgrades" \
        /etc/apt/apt.conf.d/20auto-upgrades 0644
      systemctl enable unattended-upgrades >/dev/null
      ;;
    rhel)
      hh_info "dnf-automatic security updates"
      local auto=/etc/dnf/automatic.conf
      if [[ -f "$auto" ]]; then
        hh_backup_file "$auto" >/dev/null
        if grep -q '^apply_updates' "$auto"; then
          sed -i 's/^apply_updates.*/apply_updates = yes/' "$auto"
        else
          printf '\napply_updates = yes\n' >>"$auto"
        fi
        if grep -q '^upgrade_type' "$auto"; then
          sed -i 's/^upgrade_type.*/upgrade_type = security/' "$auto"
        fi
      else
        hh_install_template "$root/templates/dnf/automatic.conf.snippet" "$auto" 0644
      fi
      systemctl enable --now dnf-automatic.timer >/dev/null 2>&1 \
        || systemctl enable --now dnf-automatic-install.timer >/dev/null
      ;;
  esac
}

# Phase 5 SFTP chroot: ensure both groups exist, (re)install the sshd policy
# drop-in (which now carries the Match Group hearthost-sftp jail) and reload.
hh_sftp_apply() {
  hh_require_root
  hh_os_load
  hh_os_supported || hh_die "unsupported OS: $(hh_os_pretty). Need $(hh_os_supported_list)"
  hh_config_load
  local root ssh_group sftp_group
  root="$(hearthost_root)"
  ssh_group="$(hh_conf ssh_group hearthost-ssh)"
  sftp_group="$(hh_conf sftp_group hearthost-sftp)"
  hh_ensure_group "$ssh_group"
  hh_ensure_group "$sftp_group"
  mkdir -p /etc/ssh/sshd_config.d
  hh_backup_file /etc/ssh/sshd_config.d/60-hearthost.conf >/dev/null
  hh_install_template "$root/templates/ssh/60-hearthost.conf" \
    /etc/ssh/sshd_config.d/60-hearthost.conf 0644
  if ! sshd -t; then
    hh_die "sshd -t failed with the SFTP policy; not reloading"
  fi
  hh_sshd_reload
  hh_info "SFTP chroot policy active (group $sftp_group; create jailed tenants with user add --sftp-only)"
}

hh_harden_apply() {
  hh_require_root
  hh_os_load
  hh_os_supported || hh_die "unsupported OS: $(hh_os_pretty). Need $(hh_os_supported_list)"
  hh_config_load

  local root ssh_group sftp_group
  root="$(hearthost_root)"
  ssh_group="$(hh_conf ssh_group hearthost-ssh)"
  sftp_group="$(hh_conf sftp_group hearthost-sftp)"

  mkdir -p /etc/hearthost/backups "$(hh_state_dir)/users.d" "$(hh_state_dir)/sites.d"
  mkdir -p /etc/ssh/sshd_config.d
  if [[ ! -f /etc/hearthost/hearthost.conf ]]; then
    install -m 0640 "$root/etc/hearthost.conf.example" /etc/hearthost/hearthost.conf
  fi
  hh_config_load
  hh_prompt_phpmyadmin_host "${HEARTHOST_PHPMYADMIN_HOST_FLAG:-}" \
    || hh_die "invalid or missing phpmyadmin_host"

  hh_harden_packages

  hh_info "ensuring groups $ssh_group $sftp_group"
  hh_ensure_group "$ssh_group"
  hh_ensure_group "$sftp_group"
  hh_ensure_in_group root "$ssh_group"

  hh_info "writing SSH drop-in and disabling AllowUsers"
  hh_backup_file /etc/ssh/sshd_config >/dev/null
  hh_sshd_disable_allowusers_in_file /etc/ssh/sshd_config
  hh_install_template "$root/templates/ssh/60-hearthost.conf" \
    /etc/ssh/sshd_config.d/60-hearthost.conf 0644

  if ! sshd -t; then
    hh_error "sshd -t failed; restoring sshd_config from newest backup"
    local newest
    newest="$(ls -1t /etc/hearthost/backups/sshd_config.* 2>/dev/null | head -1 || true)"
    [[ -n "$newest" ]] && cp -a "$newest" /etc/ssh/sshd_config
    hh_die "SSH config rejected; not reloading sshd"
  fi
  hh_sshd_reload

  hh_info "sysctl hardening"
  hh_install_template "$root/templates/sysctl/99-hearthost.conf" \
    /etc/sysctl.d/99-hearthost.conf 0644
  sysctl --system >/dev/null

  hh_info "fail2ban sshd jail"
  hh_install_template "$root/templates/fail2ban/jail.d/hearthost-sshd.conf" \
    /etc/fail2ban/jail.d/hearthost-sshd.conf 0644
  systemctl enable --now fail2ban >/dev/null
  systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban

  hh_harden_autoupdates
  hh_harden_firewall

  hh_info "Phase 1 hardening applied on $(hh_os_pretty)"
}
