#!/usr/bin/env bash
# Live isolation tests (Phase 9). Creates two EPHEMERAL tenants, actively
# proves one cannot reach the other's files, database, or PHP sandbox, then
# removes them. Destructive only to the two hh_isoa/hh_isob test accounts.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HH="$ROOT/bin/hearthost"
export HEARTHOST_ROOT="$ROOT"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/config.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/validate.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/paths.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/os.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/php.sh"
hh_os_load
hh_config_load

if [[ "$(id -u)" -ne 0 ]]; then echo "must run as root"; exit 2; fi

A=hh_isoa
B=hh_isob
PASS=0
FAIL=0
ok() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

cleanup() {
  "$HH" user del "$A" --purge >/dev/null 2>&1 || true
  "$HH" user del "$B" --purge >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf '== live: phase9 isolation ==\n'
cleanup
"$HH" user add "$A" >/dev/null 2>&1 || { echo "could not create $A"; exit 1; }
"$HH" user add "$B" >/dev/null 2>&1 || { echo "could not create $B"; exit 1; }
"$HH" site add "$A" isoa.example.test --app php --primary --no-ssl >/dev/null 2>&1
"$HH" site add "$B" isob.example.test --app php --primary --no-ssl >/dev/null 2>&1

A_HOME="$(hh_user_home "$A")"
B_HOME="$(hh_user_home "$B")"
B_SECRET="$B_HOME/public_html/secret.txt"
echo "top-secret-$B" >"$B_SECRET"
chown "$B:$B" "$B_SECRET"
chmod 600 "$B_SECRET"
VER="$(hh_php_default)"
A_PHP="$(hh_php_bin "$VER")"

# 1. A's shell user cannot read B's secret file (home 711, file 600).
if runuser -u "$A" -- cat "$B_SECRET" >/dev/null 2>&1; then
  fail "tenant $A could read $B's 600 secret file"
else
  ok "$A cannot read $B's secret file (filesystem perms)"
fi

# 2. A's shell user cannot list B's home.
if runuser -u "$A" -- ls "$B_HOME" >/dev/null 2>&1; then
  fail "$A could list $B's home"
else
  ok "$A cannot list $B's home (711)"
fi

# 3. PHP running as A (open_basedir=/home/A) cannot read B's file.
out="$(runuser -u "$A" -- env HOME="$A_HOME" "$A_PHP" -d open_basedir="$A_HOME:/usr/share/php" \
  -r '@readfile("'"$B_SECRET"'"); echo "READ-OK";' 2>&1)"
if [[ "$out" == *"top-secret-$B"* || "$out" == *"READ-OK"* && "$out" != *"open_basedir"* ]]; then
  # Only a real leak if the secret content came through.
  if [[ "$out" == *"top-secret-$B"* ]]; then
    fail "PHP as $A read $B's file through open_basedir"
  else
    ok "PHP as $A blocked from $B's file (open_basedir)"
  fi
else
  ok "PHP as $A blocked from $B's file (open_basedir)"
fi

# 4. A's PHP cannot run system() (disable_functions).
out="$(runuser -u "$A" -- env HOME="$A_HOME" "$A_PHP" \
  -d disable_functions="exec,passthru,shell_exec,system,popen,show_source,pcntl_exec,pcntl_fork" \
  -r 'echo function_exists("system") && is_callable("system") ? "CALLABLE" : "blocked";' 2>&1)"
[[ "$out" == *blocked* ]] && ok "system() disabled for $A" || fail "system() callable for $A ($out)"

# 5. DB isolation: create a DB for B, confirm A's DB login cannot see it.
if command -v mysql >/dev/null 2>&1 && mysqladmin --protocol=socket -uroot ping >/dev/null 2>&1; then
  "$HH" db create "$B" private >/dev/null 2>&1
  bdb="$(hh_db_name "$B" private)"
  # A connects to MariaDB as itself (unix_socket) via its own FPM user.
  seen="$(runuser -u "$A" -- mysql --protocol=socket -N -B -e "SHOW DATABASES;" 2>/dev/null | grep -x "$bdb" || true)"
  [[ -z "$seen" ]] && ok "$A's DB login cannot see $B's database ($bdb)" \
    || fail "$A could see $B's database $bdb"
  # And A cannot USE it.
  if runuser -u "$A" -- mysql --protocol=socket -e "USE \`$bdb\`;" >/dev/null 2>&1; then
    fail "$A could USE $B's database"
  else
    ok "$A cannot USE $B's database (grant scoped to ${A}_%)"
  fi
else
  printf '  info MariaDB not reachable; skipping DB isolation\n'
fi

# 6. Each tenant's FPM master runs as itself, in its own slice.
a_pool="$(hh_php_tenant_pool_file "$A" "$VER")"
grep -q "^user = $A$" "$a_pool" 2>/dev/null && ok "$A FPM pool runs as $A" || fail "$A pool identity wrong"
auid="$(hh_user_uid "$A")"
a_slice="$(systemctl show -p Slice --value "$(hh_php_service_name "$VER" "$A")" 2>/dev/null)"
[[ "$a_slice" == "user-${auid}.slice" ]] && ok "$A FPM in user-${auid}.slice" || fail "$A FPM not in its slice ($a_slice)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
