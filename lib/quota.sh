# RAM / CPU parsing and PHP child derivation.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_QUOTA_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_QUOTA_LOADED=1

# Convert 512M, 1G, 256MiB, 1024 into bytes. SI and IEC suffixes accepted.
hh_parse_bytes() {
  local raw="${1:-}"
  local num suffix
  if [[ ! "$raw" =~ ^([0-9]+)([KkMmGgTt]i?[Bb]?)?$ ]]; then
    return 1
  fi
  num="${BASH_REMATCH[1]}"
  suffix="${BASH_REMATCH[2]}"
  case "$suffix" in
    ""|B|b) printf '%s\n' "$num" ;;
    K|k|KB|kb) printf '%s\n' $((num * 1000)) ;;
    Ki|ki|KiB|kib) printf '%s\n' $((num * 1024)) ;;
    M|m|MB|mb) printf '%s\n' $((num * 1000 * 1000)) ;;
    Mi|mi|MiB|mib) printf '%s\n' $((num * 1024 * 1024)) ;;
    G|g|GB|gb) printf '%s\n' $((num * 1000 * 1000 * 1000)) ;;
    Gi|gi|GiB|gib) printf '%s\n' $((num * 1024 * 1024 * 1024)) ;;
    T|t|TB|tb) printf '%s\n' $((num * 1000 * 1000 * 1000 * 1000)) ;;
    Ti|ti|TiB|tib) printf '%s\n' $((num * 1024 * 1024 * 1024 * 1024)) ;;
    *) return 1 ;;
  esac
}

# 100% = one full core (systemd CPUQuota). 50% = half a core.
hh_parse_cpu_quota() {
  local raw="${1:-}"
  if [[ "$raw" =~ ^([0-9]+)%$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$raw" =~ ^([0-9]+(\.[0-9]+)?)$ ]]; then
    # cores -> percent
    awk -v n="$raw" 'BEGIN { printf "%d\n", int(n * 100 + 0.5) }'
    return 0
  fi
  return 1
}

# How many PHP-FPM children fit in MEMORY given per-process php_memory_limit.
# Always at least 1, never more than 32.
hh_php_max_children() {
  local memory="${1:-}"
  local proc_limit="${2:-}"
  [[ -n "$proc_limit" ]] || proc_limit="$(hh_conf php_memory_limit 256M)"
  local mem_b limit_b children
  mem_b="$(hh_parse_bytes "$memory")" || return 1
  limit_b="$(hh_parse_bytes "$proc_limit")" || return 1
  if (( limit_b <= 0 )); then
    return 1
  fi
  children=$((mem_b / limit_b))
  if (( children < 1 )); then
    children=1
  elif (( children > 32 )); then
    children=32
  fi
  printf '%s\n' "$children"
}

# Normalize an operator CPU spelling to systemd CPUQuota ("100%", "50%").
hh_systemd_cpu_quota() {
  local pct
  pct="$(hh_parse_cpu_quota "$1")" || return 1
  printf '%s%%\n' "$pct"
}

hh_systemd_memory_max() {
  # systemd accepts 1G, 512M natively; keep the operator spelling if parseable.
  local raw="$1"
  hh_parse_bytes "$raw" >/dev/null || return 1
  printf '%s\n' "$raw"
}
