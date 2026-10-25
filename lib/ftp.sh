# Classic FTP / FTPS via vsftpd. Opt-in (ftp_enable). Phase 5.
# Allow-list only: a tenant can log in over FTP only after user add (or
# `ftp allow`) writes them into /etc/hearthost/ftp.users.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_FTP_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_FTP_LOADED=1

hh_ftp_userlist() { printf '/etc/hearthost/ftp.users\n'; }
hh_ftp_cert() { printf '/etc/ssl/certs/hearthost-ftp.pem\n'; }
hh_ftp_key() { printf '/etc/ssl/private/hearthost-ftp.key\n'; }

hh_ftp_conf_path() {
  case "$(hh_os_family)" in
    rhel) printf '/etc/vsftpd/vsftpd.conf\n' ;;
    *) printf '/etc/vsftpd.conf\n' ;;
  esac
}

hh_ftp_service() { printf 'vsftpd\n'; }

# Idempotent allow-list edits. Never add a reserved/invalid name.
hh_ftp_allow_user() {
  local user="$1"
  hh_valid_username "$user" || { hh_error "refusing FTP for invalid user: $user"; return 1; }
  local f
  f="$(hh_ftp_userlist)"
  mkdir -p "$(dirname "$f")"
  touch "$f"
  grep -qxF "$user" "$f" || printf '%s\n' "$user" >>"$f"
  chmod 640 "$f"
}

hh_ftp_deny_user() {
  local user="$1"
  local f
  f="$(hh_ftp_userlist)"
  [[ -f "$f" ]] || return 0
  grep -vxF "$user" "$f" >"$f.tmp" 2>/dev/null || true
  mv -f "$f.tmp" "$f"
  chmod 640 "$f"
}

hh_ftp_ensure_cert() {
  local cert key
  cert="$(hh_ftp_cert)"
  key="$(hh_ftp_key)"
  [[ -f "$cert" && -f "$key" ]] && return 0
  mkdir -p "$(dirname "$cert")" "$(dirname "$key")"
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "$key" -out "$cert" -subj "/CN=hearthost-ftp" >/dev/null 2>&1
  chmod 600 "$key"
  chmod 644 "$cert"
}

hh_ftp_firewall_open() {
  local port="$1" pmin="$2" pmax="$3"
  case "$(hh_os_family)" in
    debian)
      command -v ufw >/dev/null 2>&1 || return 0
      ufw allow "${port}/tcp" comment "hearthost-ftp" >/dev/null 2>&1 || true
      ufw allow "${pmin}:${pmax}/tcp" comment "hearthost-ftp-pasv" >/dev/null 2>&1 || true
      ;;
    rhel)
      command -v firewall-cmd >/dev/null 2>&1 || return 0
      firewall-cmd --permanent --add-service=ftp >/dev/null 2>&1 || true
      firewall-cmd --permanent --add-port="${pmin}-${pmax}/tcp" >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
      ;;
  esac
}

hh_ftp_apply() {
  hh_require_root
  hh_os_load
  hh_os_supported || hh_die "unsupported OS: $(hh_os_pretty). Need $(hh_os_supported_list)"
  hh_config_load

  if ! hh_conf_bool ftp_enable yes; then
    hh_info "ftp_enable=no; skipping vsftpd. SFTP is the recommended upload path."
    return 0
  fi

  hh_info "installing vsftpd (FTPS enabled; classic FTP sends passwords in clear)"
  hh_pkg_install vsftpd openssl

  hh_ftp_ensure_cert

  local conf port pmin pmax
  conf="$(hh_ftp_conf_path)"
  port="$(hh_conf ftp_port 21)"
  pmin="$(hh_conf ftp_pasv_min 40000)"
  pmax="$(hh_conf ftp_pasv_max 40099)"
  hh_backup_file "$conf" >/dev/null
  hh_nginx_subst "$(hearthost_root)/templates/vsftpd/vsftpd.conf.snippet" "$conf" \
    "USERLIST=$(hh_ftp_userlist)" \
    "PASV_MIN=$pmin" \
    "PASV_MAX=$pmax" \
    "FTP_PORT=$port" \
    "CERT=$(hh_ftp_cert)" \
    "KEY=$(hh_ftp_key)"
  chmod 644 "$conf"

  local f
  f="$(hh_ftp_userlist)"
  mkdir -p "$(dirname "$f")"
  touch "$f"
  chmod 640 "$f"

  hh_ftp_firewall_open "$port" "$pmin" "$pmax"

  local svc
  svc="$(hh_ftp_service)"
  systemctl enable --now "$svc" >/dev/null 2>&1 || systemctl restart "$svc"
  systemctl restart "$svc"
  hh_info "vsftpd on port $port, PASV $pmin-$pmax, FTPS on. Allow a tenant: hearthost ftp allow USER"
}

hh_ftp_cmd() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    allow)
      hh_config_load
      [[ -n "${1:-}" ]] || hh_die "usage: hearthost ftp allow USER"
      hh_valid_username "$1" || hh_die "invalid username: $1"
      hh_ftp_allow_user "$1" && hh_info "FTP enabled for $1"
      ;;
    deny)
      hh_config_load
      [[ -n "${1:-}" ]] || hh_die "usage: hearthost ftp deny USER"
      hh_ftp_deny_user "$1" && hh_info "FTP disabled for $1"
      ;;
    *)
      hh_die "usage: hearthost ftp allow|deny USER"
      ;;
  esac
}
