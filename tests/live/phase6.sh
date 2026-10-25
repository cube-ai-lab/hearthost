#!/usr/bin/env bash
# Live checks after a tenant exists: the per-user slice cap is enforced and
# the tenant's PHP-FPM master runs inside that slice.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export HEARTHOST_ROOT="$ROOT"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/config.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/validate.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/quota.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/paths.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/os.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/php.sh"
hh_os_load
hh_config_load

USER_UNDER_TEST="${1:-}"
[[ -n "$USER_UNDER_TEST" ]] || { echo "usage: tests/live/phase6.sh USER"; exit 2; }

PASS=0
FAIL=0
ok() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

printf '== live: phase6 (%s) ==\n' "$USER_UNDER_TEST"
uid="$(id -u "$USER_UNDER_TEST")"
cg="/sys/fs/cgroup/user.slice/user-${uid}.slice"

if [[ -f "$cg/memory.max" && "$(cat "$cg/memory.max")" != "max" ]]; then
  ok "memory.max is set on user-${uid}.slice ($(cat "$cg/memory.max") bytes)"
else
  fail "memory.max not enforced on user-${uid}.slice"
fi

if grep -q '[0-9]' "$cg/cpu.max" 2>/dev/null && [[ "$(cut -d' ' -f1 "$cg/cpu.max")" != "max" ]]; then
  ok "cpu.max is set ($(cat "$cg/cpu.max"))"
else
  fail "cpu.max not enforced"
fi

found=0
while IFS= read -r ver; do
  [[ -n "$ver" ]] || continue
  svc="$(hh_php_service_name "$ver" "$USER_UNDER_TEST")"
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    found=1
    slice="$(systemctl show -p Slice --value "$svc")"
    if [[ "$slice" == "user-${uid}.slice" ]]; then
      ok "$svc runs in user-${uid}.slice"
    else
      fail "$svc is in $slice, not user-${uid}.slice"
    fi
  fi
done < <(hh_php_versions)
[[ "$found" == 1 ]] && ok "tenant has a dedicated PHP-FPM master" \
  || printf '  info no PHP master yet (add a site first)\n'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
