#!/usr/bin/env bash
# Live checks after `hearthost init nginx`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export HEARTHOST_ROOT="$ROOT"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/os.sh"
hh_os_load

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

printf '== live: phase2 ==\n'
check "nginx installed" command -v nginx
check "nginx -t" nginx -t
check "nginx active" systemctl is-active --quiet nginx
check "http snippet" test -f /etc/nginx/conf.d/00-hearthost.conf
check "ssl params" test -f /etc/nginx/snippets/hearthost-ssl-params.conf
check "wordpress snippet" test -f /etc/nginx/snippets/hearthost-wordpress.conf
check "laravel snippet" test -f /etc/nginx/snippets/hearthost-laravel.conf
check "acme snippet uses \$hh_ssl_root" grep -q 'hh_ssl_root' /etc/nginx/snippets/hearthost-acme.conf
check "default TLS cert is system catch-all only" test -f /etc/hearthost/tls/default.crt
check "distro default site gone" bash -c '! test -e /etc/nginx/sites-enabled/default'

code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: invalid.example' http://127.0.0.1/ || true)"
if [[ "$code" == "404" ]]; then
  ok "unknown host returns 404"
else
  fail "unknown host HTTP $code (want 404)"
fi

hdr="$(curl -sI -H 'Host: invalid.example' http://127.0.0.1/ || true)"
if echo "$hdr" | grep -qi '^Server: nginx/'; then
  fail "nginx version leaked in Server header"
else
  ok "server_tokens off (no version in Server)"
fi

set +e
doctor_out="$("$ROOT/bin/hearthost" doctor 2>&1)"
doctor_rc=$?
set -e
if [[ "$doctor_rc" == "0" && "$doctor_out" == *"nginx active"* ]]; then
  ok "doctor sees nginx"
else
  fail "doctor nginx check"
  printf '%s\n' "$doctor_out"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
