# Phase 8: cron-friendly health check. Reports service, per-tenant FPM, disk,
# and certificate-expiry problems; exits non-zero when any are found so a
# timer/monitor can alert. Read-only.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_HEALTH_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_HEALTH_LOADED=1

# Days until a PEM certificate expires, or empty if unreadable. Pure-ish.
hh_health_cert_days() {
  local cert="$1"
  [[ -f "$cert" ]] || return 1
  local end end_s now_s
  end="$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null)" || return 1
  end="${end#notAfter=}"
  end_s="$(date -d "$end" +%s 2>/dev/null)" || return 1
  now_s="$(date +%s)"
  printf '%s\n' $(( (end_s - now_s) / 86400 ))
}

# Root-filesystem use percent as an integer.
hh_health_disk_pct() {
  df -P "${1:-/}" 2>/dev/null | awk 'NR==2 { gsub(/%/,"",$5); print $5 }'
}

hh_health_run() {
  hh_os_load
  hh_config_load
  local problems=0
  local line_ok line_bad
  _h_ok() { printf '[ok]   %s\n' "$1"; }
  _h_bad() { printf '[FAIL] %s\n' "$1"; problems=$((problems + 1)); }
  _h_warn() { printf '[warn] %s\n' "$1"; }

  printf 'Hearthost health  v%s  (%s)\n\n' "$(hh_version)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Core services.
  local svc
  for svc in nginx "$(hh_mariadb_service)"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      _h_ok "service $svc active"
    else
      _h_bad "service $svc not active"
    fi
  done
  if command -v nginx >/dev/null 2>&1; then
    nginx -t >/dev/null 2>&1 && _h_ok "nginx config valid" || _h_bad "nginx -t failed"
  fi

  # Per-tenant dedicated FPM masters.
  local dir f user ver tenants=0
  dir="$(dirname "$(hh_user_state x)")"
  if [[ -d "$dir" ]]; then
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      user="$(sed -n 's/^username:[[:space:]]*//p' "$f" | head -1)"
      [[ -n "$user" ]] && getent passwd "$user" >/dev/null || continue
      tenants=$((tenants + 1))
      while IFS= read -r ver; do
        [[ -n "$ver" ]] || continue
        local unit svc2
        unit="$(hh_php_service_unit "$ver" "$user")"
        svc2="$(hh_php_service_name "$ver" "$user")"
        [[ -f "$unit" ]] || continue
        if systemctl is-active --quiet "$svc2" 2>/dev/null; then
          _h_ok "FPM $svc2 active"
        else
          _h_bad "FPM $svc2 down (site(s) on PHP $ver for $user return 502)"
        fi
      done < <(hh_php_versions)
    done < <(find "$dir" -maxdepth 1 -type f -name '*.yaml')
  fi
  _h_ok "$tenants tenant(s) checked"

  # Certificate expiry for every configured site.
  local sdir sf domain owner cert days warn_days
  warn_days="$(hh_conf cert_warn_days 14)"
  sdir="$(dirname "$(hh_site_state x)")"
  if [[ -d "$sdir" ]]; then
    while IFS= read -r sf; do
      [[ -f "$sf" ]] || continue
      domain="$(sed -n 's/^domain:[[:space:]]*//p' "$sf" | head -1)"
      owner="$(sed -n 's/^user:[[:space:]]*//p' "$sf" | head -1)"
      [[ -n "$domain" && -n "$owner" ]] || continue
      cert="$(hh_site_ssl_cert "$owner" "$domain")"
      days="$(hh_health_cert_days "$cert")" || { _h_warn "no readable cert for $domain (placeholder?)"; continue; }
      if (( days < 0 )); then
        _h_bad "cert for $domain expired ${days#-} day(s) ago"
      elif (( days < warn_days )); then
        _h_warn "cert for $domain expires in $days day(s)"
      else
        _h_ok "cert for $domain valid ($days day(s) left)"
      fi
    done < <(find "$sdir" -maxdepth 1 -type f -name '*.yaml')
  fi

  # Disk.
  local pct warn_pct
  pct="$(hh_health_disk_pct /)"
  warn_pct="$(hh_conf disk_warn_pct 85)"
  if [[ -n "$pct" ]] && (( pct >= warn_pct )); then
    _h_bad "disk / at ${pct}% (threshold ${warn_pct}%)"
  else
    _h_ok "disk / at ${pct:-?}%"
  fi

  # Any failed systemd units at all. --plain drops the leading bullet column.
  local failed
  failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk 'NF{print $1}' | tr '\n' ' ' || true)"
  if [[ -n "${failed// }" ]]; then
    _h_bad "failed systemd units: $failed"
  else
    _h_ok "no failed systemd units"
  fi

  printf '\n%d problem(s)\n' "$problems"
  (( problems == 0 ))
}
