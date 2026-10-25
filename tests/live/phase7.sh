#!/usr/bin/env bash
# Live checks for Phase 7: wp-cli present, tenant OPcache on, and (if a site
# opted in) the FastCGI microcache zone exists.
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
# shellcheck source=/dev/null
. "$ROOT/lib/wp.sh"
hh_os_load
hh_config_load

PASS=0
FAIL=0
ok() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

printf '== live: phase7 ==\n'
if hh_wpcli_installed; then
  ok "wp-cli present ($("$(hh_wpcli_path)" --version --allow-root 2>/dev/null | head -1))"
else
  fail "wp-cli not installed (run hearthost init wp)"
fi

# Any tenant pool should carry the OPcache directives.
pool="$(find /etc/hearthost/php -maxdepth 2 -name '*-pool.conf' 2>/dev/null | head -1)"
if [[ -n "$pool" ]]; then
  grep -q 'opcache.enable\] = On' "$pool" && ok "tenant pool enables OPcache ($pool)" \
    || fail "tenant pool missing OPcache ($pool)"
else
  printf '  info no tenant pools yet\n'
fi

if [[ -f /etc/nginx/conf.d/01-hearthost-microcache.conf ]]; then
  grep -q 'keys_zone=hearthost_microcache' /etc/nginx/conf.d/01-hearthost-microcache.conf \
    && ok "microcache zone defined" || fail "microcache zone file malformed"
else
  printf '  info microcache zone not created yet (no --microcache site)\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
