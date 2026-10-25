#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export HEARTHOST_ROOT="$ROOT"
export HEARTHOST_CONF_FILE="$ROOT/etc/hearthost.conf.example"

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" == "$want" ]]; then
    printf '  ok   %s\n' "$msg"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %s\n       got:  %s\n       want: %s\n' "$msg" "$got" "$want"
    FAIL=$((FAIL + 1))
  fi
}

assert_ok() {
  local msg="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  ok   %s\n' "$msg"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %s (expected success)\n' "$msg"
    FAIL=$((FAIL + 1))
  fi
}

assert_fail() {
  local msg="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  FAIL %s (expected failure)\n' "$msg"
    FAIL=$((FAIL + 1))
  else
    printf '  ok   %s\n' "$msg"
    PASS=$((PASS + 1))
  fi
}

# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/config.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/validate.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/paths.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/quota.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/os.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/perms.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/hardening.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/nginx.sh"

hh_config_load

load_os_fixture() {
  HEARTHOST_OS_RELEASE="$ROOT/tests/fixtures/os-release/$1"
  hh_os_load
}

printf '== unit: os ==\n'
load_os_fixture ubuntu-22.04
assert_ok "Ubuntu 22.04 LTS supported" hh_os_supported
assert_eq "$(hh_os_family)" "debian" "22.04 family debian"
assert_eq "$(hh_os_web_user)" "www-data" "22.04 web user"
load_os_fixture ubuntu-24.04
assert_ok "Ubuntu 24.04 LTS supported" hh_os_supported
load_os_fixture ubuntu-26.04
assert_ok "Ubuntu 26.04 LTS supported" hh_os_supported
assert_eq "$(hh_os_major)" "26" "26.04 major"
load_os_fixture almalinux-9
assert_ok "AlmaLinux 9 supported" hh_os_supported
assert_eq "$(hh_os_family)" "rhel" "el9 family rhel"
assert_eq "$(hh_os_web_user)" "nginx" "el9 web user"
load_os_fixture almalinux-10
assert_ok "AlmaLinux 10 supported" hh_os_supported
load_os_fixture ubuntu-20.04
assert_fail "Ubuntu 20.04 not supported" hh_os_supported
load_os_fixture ubuntu-25.04
assert_fail "Ubuntu 25.04 interim not supported" hh_os_supported
load_os_fixture debian-12
assert_fail "Debian 12 not supported" hh_os_supported
unset HEARTHOST_OS_RELEASE
hh_os_load

printf '== unit: perms ==\n'
assert_eq "$(hh_perm_owner alice)" "alice:alice" "files owned by user:user"
assert_eq "$(hh_perm_home)" "711" "home 711"
assert_eq "$(hh_perm_webroot)" "755" "webroot 755"
assert_eq "$(hh_perm_file)" "644" "files 644"
assert_eq "$(hh_perm_secret)" "640" "secrets 640"
assert_eq "$(hh_perm_logs)" "750" "logs 750"
assert_eq "$(hh_perm_tmp)" "700" "tmp 700"
assert_ok "www-data is the daemon not a tenant owner" hh_perm_is_web_daemon www-data
assert_ok "nginx is the daemon not a tenant owner" hh_perm_is_web_daemon nginx
assert_fail "alice is not a web daemon" hh_perm_is_web_daemon alice
assert_fail "refuse chown to www-data" hh_perm_apply_dir /tmp www-data 755

printf '== unit: validate ==\n'
assert_ok "alice is a valid user" hh_valid_username alice
assert_ok "site_ops-1 is a valid user" hh_valid_username site_ops-1
assert_fail "root is reserved" hh_valid_username root
assert_fail "www-data is reserved" hh_valid_username www-data
assert_fail "mysql is reserved" hh_valid_username mysql
assert_fail "uppercase rejected" hh_valid_username Alice
assert_fail "path user rejected" hh_valid_username '../alice'
assert_fail "slash user rejected" hh_valid_username 'al/ice'
assert_fail "empty user rejected" hh_valid_username ''

assert_ok "example.com" hh_valid_domain example.com
assert_ok "blog.example.com" hh_valid_domain blog.example.com
assert_ok "idn xn--n3h.com" hh_valid_domain xn--n3h.com
assert_fail "bare hostname" hh_valid_domain localhost
assert_fail "dotdot domain" hh_valid_domain 'example..com'
assert_fail "path domain" hh_valid_domain 'example.com/foo'
assert_fail "scheme domain" hh_valid_domain 'https://example.com'
assert_fail "leading hyphen label" hh_valid_domain '-bad.com'

assert_ok "php 8.3" hh_valid_php 8.3
assert_ok "php 8.5" hh_php_allowed 8.5
assert_fail "php 7.4" hh_valid_php 7.4
assert_fail "php 8.1 not in default set" hh_php_allowed 8.1
assert_ok "app wordpress" hh_valid_app wordpress
assert_ok "app laravel" hh_valid_app laravel
assert_fail "app unknown" hh_valid_app joomla

printf '== unit: paths ==\n'
assert_eq "$(hh_user_home alice)" "/home/alice" "user home"
assert_eq "$(hh_site_docroot alice example.com yes)" "/home/alice/public_html" "primary docroot"
assert_eq "$(hh_site_docroot alice example.com no)" "/home/alice/example.com" "addon domain docroot"
assert_eq "$(hh_site_docroot alice blog.example.com no)" "/home/alice/blog.example.com" "subdomain docroot"
assert_eq "$(hh_site_docroot alice Example.COM no)" "/home/alice/example.com" "docroot lowercases domain"
assert_eq "$(hh_fpm_socket 8.3 alice)" "/run/php/php8.3-fpm-alice.sock" "fpm socket"
assert_eq "$(hh_user_slice alice)" "hearthost-alice.slice" "user slice"
assert_eq "$(hh_db_name alice wordpress)" "alice_wordpress" "db prefix added"
assert_eq "$(hh_db_name alice alice_wp)" "alice_wp" "db prefix not doubled"
assert_eq "$(hh_db_like alice)" "alice_%" "grant LIKE pattern"

printf '== unit: quota ==\n'
assert_eq "$(hh_parse_bytes 1G)" "1000000000" "1G SI"
assert_eq "$(hh_parse_bytes 1Gi)" "1073741824" "1Gi IEC"
assert_eq "$(hh_parse_bytes 256M)" "256000000" "256M"
assert_eq "$(hh_parse_bytes 256Mi)" "268435456" "256Mi"
assert_eq "$(hh_parse_cpu_quota 100%)" "100" "cpu 100%"
assert_eq "$(hh_parse_cpu_quota 1)" "100" "cpu 1 core"
assert_eq "$(hh_php_max_children 1G 256M)" "3" "1G / 256M => 3 children"
assert_eq "$(hh_php_max_children 256M 256M)" "1" "exact one child"
assert_fail "bad size" hh_parse_bytes lots

printf '== unit: hardening ==\n'
sshd_fix="$(mktemp)"
cat >"$sshd_fix" <<'EOF'
Include /etc/ssh/sshd_config.d/*.conf
PermitRootLogin yes
AllowUsers root
# AllowUsers already commented
EOF
hh_sshd_disable_allowusers_in_file "$sshd_fix"
assert_fail "AllowUsers no longer active" hh_sshd_has_active_allowusers "$sshd_fix"
if grep -q '# hearthost: AllowUsers root' "$sshd_fix"; then
  printf '  ok   AllowUsers commented in place\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL AllowUsers was not commented\n'
  FAIL=$((FAIL + 1))
fi
hh_sshd_disable_allowusers_in_file "$sshd_fix"
count="$(grep -c 'hearthost: AllowUsers' "$sshd_fix" || true)"
assert_eq "$count" "1" "commenting AllowUsers is idempotent"
rm -f "$sshd_fix"

printf '== unit: nginx ==\n'
ngin="$(mktemp)"
ngout="$(mktemp)"
printf 'root {{DOCROOT}};\nserver_name {{DOMAIN}};\n' >"$ngin"
hh_nginx_subst "$ngin" "$ngout" "DOCROOT=/home/alice/public_html" "DOMAIN=example.com"
assert_eq "$(tr '\n' ' ' <"$ngout" | sed 's/ *$//')" "root /home/alice/public_html; server_name example.com;" "vhost token subst"
assert_ok "wordpress denies PHP in uploads" grep -q uploads "$ROOT/templates/nginx/wordpress.conf"
assert_ok "wordpress denies wp-config" grep -q 'wp-config' "$ROOT/templates/nginx/wordpress.conf"
assert_ok "wordpress denies xmlrpc" grep -q 'xmlrpc.php' "$ROOT/templates/nginx/wordpress.conf"
assert_ok "tls min 1.2" grep -q 'TLSv1.2' "$ROOT/templates/nginx/nginx.conf"
assert_ok "acme challenge path" grep -q 'acme-challenge' "$ROOT/templates/nginx/acme.conf"
load_os_fixture ubuntu-24.04
assert_eq "$(hh_nginx_sites_available)" "/etc/nginx/sites-available" "ubuntu sites-available"
load_os_fixture almalinux-9
assert_eq "$(hh_nginx_sites_available)" "/etc/nginx/conf.d" "alma uses conf.d"
unset HEARTHOST_OS_RELEASE
hh_os_load
rm -f "$ngin" "$ngout"

printf '== unit: config ==\n'
cfg="$(mktemp)"
printf 'phpmyadmin_host=\n' >"$cfg"
HEARTHOST_CONF_FILE="$cfg"
hh_config_load
hh_prompt_phpmyadmin_host pma.example.com
assert_eq "$(hh_conf phpmyadmin_host)" "pma.example.com" "flag sets phpmyadmin_host"
assert_eq "$(grep '^phpmyadmin_host=' "$cfg")" "phpmyadmin_host=pma.example.com" "value persisted"
HEARTHOST_NONINTERACTIVE=1 hh_prompt_phpmyadmin_host >/dev/null
assert_eq "$(hh_conf phpmyadmin_host)" "pma.example.com" "existing host is not overwritten"
cfg_empty="$(mktemp)"
printf 'phpmyadmin_host=\n' >"$cfg_empty"
HEARTHOST_CONF_FILE="$cfg_empty"
unset HEARTHOST_PHPMYADMIN_HOST
hh_config_load
HEARTHOST_NONINTERACTIVE=1 hh_prompt_phpmyadmin_host
assert_eq "$(hh_conf phpmyadmin_host)" "" "non-interactive leaves empty host"
assert_fail "rejects invalid phpmyadmin host" hh_prompt_phpmyadmin_host 'not a host'
rm -f "$cfg" "$cfg_empty"
HEARTHOST_CONF_FILE="$ROOT/etc/hearthost.conf.example"
hh_config_load

printf '== unit: cli ==\n'
CLI="$ROOT/bin/hearthost"
assert_eq "$("$CLI" version)" "0.4.0" "cli version"
assert_eq "$("$CLI" path user alice)" "/home/alice" "cli path user"
assert_eq "$("$CLI" path docroot alice example.com --primary)" "/home/alice/public_html" "cli primary docroot"
assert_eq "$("$CLI" path docroot alice blog.example.com)" "/home/alice/blog.example.com" "cli addon docroot"
assert_eq "$("$CLI" path owner alice)" "alice:alice" "cli owner user:user"
assert_eq "$("$CLI" path perms home)" "711" "cli home mode"
assert_eq "$("$CLI" path perms secret)" "640" "cli secret mode"
assert_eq "$("$CLI" path db alice wp)" "alice_wp" "cli db name"
assert_eq "$("$CLI" quota children 1G)" "3" "cli children"
assert_ok "cli validate user" "$CLI" validate user alice
assert_fail "cli reject root" "$CLI" validate user root
assert_fail "cli reject php 8.1" "$CLI" validate php 8.1
assert_fail "cli unknown command" "$CLI" notacommand
assert_fail "init without target" "$CLI" init
if [[ "$("$CLI" os)" == *"supported=yes"* ]]; then
  printf '  ok   cli os reports supported on this host\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL cli os should report supported=yes on Ubuntu LTS or AlmaLinux\n'
  FAIL=$((FAIL + 1))
fi

printf '== unit: doctor preflight ==\n'
set +e
doctor_out="$("$CLI" doctor 2>&1)"
doctor_rc=$?
set -e
assert_eq "$doctor_rc" "0" "doctor preflight exit 0"
if [[ "$doctor_out" == *"cgroup v2"* ]]; then
  printf '  ok   doctor mentions cgroup v2\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL doctor missing cgroup line\n'
  FAIL=$((FAIL + 1))
fi
if [[ "$doctor_out" == *"Raise VPS RAM"* ]] || [[ "$doctor_out" == *"tenant(s) at"* ]]; then
  printf '  ok   doctor reports RAM vs 1G quota\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL doctor missing RAM guidance\n%s\n' "$doctor_out"
  FAIL=$((FAIL + 1))
fi
if [[ "$doctor_out" == *"plaintext"* ]]; then
  printf '  ok   doctor warns about classic FTP\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL doctor missing FTP warning\n'
  FAIL=$((FAIL + 1))
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
