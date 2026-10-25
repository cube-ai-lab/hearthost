# Shared helpers. Sourced by bin/hearthost and tests.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_COMMON_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_COMMON_LOADED=1

hearthost_root() {
  if [[ -n "${HEARTHOST_ROOT:-}" ]]; then
    printf '%s\n' "$HEARTHOST_ROOT"
    return 0
  fi
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  printf '%s\n' "$here"
}

hh_version() {
  local f
  f="$(hearthost_root)/VERSION"
  if [[ -f "$f" ]]; then
    tr -d '[:space:]' <"$f"
  else
    printf '0.0.0\n'
  fi
}

hh_log() {
  local level="$1"
  shift
  printf '[%s] %s\n' "$level" "$*" >&2
}

hh_info() { hh_log "info" "$@"; }
hh_warn() { hh_log "warn" "$@"; }
hh_error() { hh_log "error" "$@"; }

hh_die() {
  hh_error "$@"
  exit 1
}

hh_ok() {
  printf 'ok\n'
}
