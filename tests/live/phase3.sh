#!/usr/bin/env bash
# Live checks after `hearthost init mariadb`.
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

printf '== live: phase3 ==\n'
check "mariadb or mysqld active" bash -c 'systemctl is-active --quiet mariadb || systemctl is-active --quiet mysqld'
check "root unix_socket ping" mysqladmin --protocol=socket -uroot ping
check "hearthost mariadb drop-in" bash -c 'test -f /etc/mysql/mariadb.conf.d/99-hearthost.cnf || test -f /etc/my.cnf.d/99-hearthost.cnf'
check "not listening on 0.0.0.0:3306" bash -c '! ss -lnt | grep -q "0.0.0.0:3306"'
check "certbot installed" command -v certbot
check "ACME system webroot" test -d /etc/hearthost/ssl/.well-known/acme-challenge
check "certbot deploy hook" test -x /etc/letsencrypt/renewal-hooks/deploy/hearthost.sh
check "php-fpm pma pool" bash -c 'test -f /etc/php/*/fpm/pool.d/hearthost-pma.conf || test -f /etc/php-fpm.d/hearthost-pma.conf'
check "hearthost-pma user" getent passwd hearthost-pma
check "phpMyAdmin files" bash -c 'test -d /usr/share/phpmyadmin || test -d /usr/share/phpMyAdmin'
check "pma config" test -f /etc/hearthost/phpmyadmin/config.inc.php
check "phpmyadmin vhost file" bash -c 'test -f /etc/nginx/sites-available/phpmyadmin.conf || test -f /etc/nginx/conf.d/vhost-phpmyadmin.conf'
check "apache2 not installed" bash -c '! dpkg -s apache2 >/dev/null 2>&1'

if ss -lnt | grep -q '127.0.0.1:3306'; then
  ok "MariaDB TCP on 127.0.0.1:3306"
else
  fail "MariaDB TCP on 127.0.0.1:3306"
fi

if mysql --protocol=socket -uroot -Nse "SHOW VARIABLES LIKE 'bind_address';" 2>/dev/null | grep -q '127.0.0.1'; then
  ok "bind_address=127.0.0.1"
else
  # MariaDB may report bind_address as 127.0.0.1 in a different variable name
  if mysql --protocol=socket -uroot -Nse "SHOW VARIABLES LIKE 'bind_address';" | grep -Eq '127.0.0.1|localhost'; then
    ok "bind_address loopback"
  else
    fail "bind_address not loopback"
  fi
fi

set +e
doctor_out="$("$ROOT/bin/hearthost" doctor 2>&1)"
doctor_rc=$?
set -e
if [[ "$doctor_rc" == "0" && "$doctor_out" == *"MariaDB active"* ]]; then
  ok "doctor sees MariaDB"
else
  fail "doctor MariaDB check"
  printf '%s\n' "$doctor_out"
fi
if [[ "$doctor_out" == *"certbot present"* ]]; then
  ok "doctor sees certbot"
else
  fail "doctor certbot check"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
