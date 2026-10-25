#!/usr/bin/env bash
# Live checks after `hearthost init php`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export HEARTHOST_ROOT="$ROOT"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/os.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/config.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/php.sh"
hh_os_load
hh_config_load

PASS=0
FAIL=0
ok() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() {
  local msg="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    ok "$msg"
  else
    fail "$msg"
  fi
}

printf '== live: phase4 ==\n'
check "/run/php exists" test -d /run/php
check "pma pool still on default PHP" bash -c 'test -f /etc/php/8.3/fpm/pool.d/hearthost-pma.conf || test -f /etc/opt/remi/php83/php-fpm.d/hearthost-pma.conf'
check "default www pool stays disabled" bash -c '! test -f /etc/php/8.3/fpm/pool.d/www.conf'

while IFS= read -r ver; do
  [[ -n "$ver" ]] || continue
  svc="$(hh_php_fpm_service "$ver")"
  if systemctl is-active --quiet "$svc"; then
    ok "PHP $ver ($svc) active"
  else
    fail "PHP $ver ($svc) active"
  fi
  if hh_php_version_installed "$ver"; then
    ok "PHP $ver binary or package present"
  else
    fail "PHP $ver binary or package present"
  fi
done < <(hh_php_versions)

set +e
doctor_out="$("$ROOT/bin/hearthost" doctor 2>&1)"
doctor_rc=$?
set -e
if [[ "$doctor_rc" == "0" && "$doctor_out" == *"PHP 8.3 FPM present"* ]]; then
  ok "doctor sees PHP 8.3"
else
  fail "doctor PHP 8.3 check"
  printf '%s\n' "$doctor_out"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
