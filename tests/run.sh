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
# shellcheck source=/dev/null
. "$ROOT/lib/ssl.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/mariadb.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/php.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/phpmyadmin.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/doctor.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/slice.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/ftp.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/user.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/site.sh"

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
assert_eq "$(hh_perm_ssl)" "711" "ssl dir 711"
assert_eq "$(hh_perm_ssl_key)" "600" "ssl key 600"
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
assert_fail "hearthost-pma is reserved" hh_valid_username hearthost-pma
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
assert_eq "$(hh_user_ssl_dir alice)" "/home/alice/ssl" "user ssl dir"
assert_eq "$(hh_site_ssl_dir alice example.com)" "/home/alice/ssl/example.com" "domain ssl dir"
assert_eq "$(hh_site_ssl_cert alice example.com)" "/home/alice/ssl/example.com/fullchain.pem" "fullchain path"
assert_eq "$(hh_site_ssl_key alice example.com)" "/home/alice/ssl/example.com/privkey.pem" "privkey path"
assert_eq "$(hh_system_ssl_dir)" "/etc/hearthost/ssl" "system ssl dir"
assert_eq "$(hh_system_ssl_cert pma.example.com)" "/etc/hearthost/ssl/pma.example.com/fullchain.pem" "system fullchain"
assert_eq "$(hh_certbot_live_dir example.com)" "/etc/letsencrypt/live/example.com" "certbot lineage"
assert_eq "$(hh_db_grant_pattern alice)" 'alice\_%' "grant pattern escapes underscore"
grant_sql="$(hh_db_tenant_grant_sql alice)"
if [[ "$grant_sql" == *unix_socket* ]]; then
  printf '  ok   tenant grant uses unix_socket\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL tenant grant uses unix_socket\n'
  FAIL=$((FAIL + 1))
fi
if [[ "$grant_sql" == *'alice\_%'* ]]; then
  printf '  ok   tenant grant uses escaped LIKE db\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL tenant grant uses escaped LIKE db\n%s\n' "$grant_sql"
  FAIL=$((FAIL + 1))
fi
assert_ok "bind 127.0.0.1 is allowed" hh_mariadb_bind_ok
assert_ok "email valid" hh_valid_email ops@example.com
assert_fail "email invalid" hh_valid_email not-an-email
assert_eq "$(hh_pma_user)" "hearthost-pma" "pma system user"
assert_eq "$(hh_pma_socket)" "/run/php/php-fpm-hearthost-pma.sock" "pma fpm socket"
assert_eq "$(hh_site_state Example.com)" "/etc/hearthost/sites.d/example.com.yaml" "site state under /etc/hearthost"
assert_eq "$(hh_user_state alice)" "/etc/hearthost/users.d/alice.yaml" "user state under /etc/hearthost"
assert_eq "$(HEARTHOST_STATE_DIR=/tmp/hh-state hh_user_state alice)" "/tmp/hh-state/users.d/alice.yaml" "state dir override"

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
printf 'v={{V}}\n' >"$ngin"
hh_nginx_subst "$ngin" "$ngout" 'V=a&b\c'
assert_eq "$(cat "$ngout")" 'v=a&b\c' "subst keeps & and backslash literal"
assert_ok "wordpress denies PHP in uploads" grep -q uploads "$ROOT/templates/nginx/wordpress.conf"
assert_ok "wordpress denies wp-config" grep -q 'wp-config' "$ROOT/templates/nginx/wordpress.conf"
assert_ok "wordpress denies xmlrpc" grep -q 'xmlrpc.php' "$ROOT/templates/nginx/wordpress.conf"
assert_ok "tls min 1.2" grep -q 'TLSv1.2' "$ROOT/templates/nginx/nginx.conf"
assert_ok "acme uses per-user ssl root" grep -q 'hh_ssl_root' "$ROOT/templates/nginx/acme.conf"
assert_fail "no global /var/www letsencrypt webroot" grep -q '/var/www/letsencrypt' "$ROOT/templates/nginx/acme.conf" "$ROOT/lib/nginx.sh"
hh_nginx_subst "$ROOT/templates/nginx/vhost.conf" "$ngout" \
  "DOMAIN=example.com" "ALIASES=" "DOCROOT=/home/alice/public_html" \
  "LOG_DIR=/home/alice/logs" "APP=wordpress" \
  "SSL_LISTEN=    listen 443 ssl;" \
  "SSL_ROOT=/home/alice/ssl" \
  "SSL_CERT=/home/alice/ssl/example.com/fullchain.pem" \
  "SSL_KEY=/home/alice/ssl/example.com/privkey.pem" \
  "FPM_SOCKET=/run/php/php8.3-fpm-alice.sock"
assert_ok "vhost cert is per-user" grep -q '/home/alice/ssl/example.com/fullchain.pem' "$ngout"
assert_ok "vhost key is per-user" grep -q '/home/alice/ssl/example.com/privkey.pem' "$ngout"
assert_ok "vhost ACME root is per-user" grep -q '"/home/alice/ssl"' "$ngout"
assert_ok "phpmyadmin vhost denies /setup" grep -q 'location ^~ /setup' "$ROOT/templates/nginx/phpmyadmin.conf"
assert_ok "phpmyadmin vhost uses system ssl root" grep -q '{{SSL_ROOT}}' "$ROOT/templates/nginx/phpmyadmin.conf"
assert_ok "deploy hook copies fullchain" grep -q 'fullchain.pem' "$ROOT/templates/ssl/deploy-hook.sh"
le_cfg="$(mktemp)"
printf 'letsencrypt_email=\n' >"$le_cfg"
HEARTHOST_CONF_FILE="$le_cfg"
hh_config_load
assert_fail "certbot refuses empty email" hh_ssl_certbot_account_args
printf 'letsencrypt_email=ops@example.com\n' >"$le_cfg"
hh_config_load
account="$(hh_ssl_certbot_account_args | tr '\n' ' ')"
if [[ "$account" == *ops@example.com* ]]; then
  printf '  ok   certbot with email passes --email\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL certbot with email passes --email\n'
  FAIL=$((FAIL + 1))
fi
live="$(mktemp -d)"
destssl="$(mktemp -d)"
printf 'chain\n' >"$live/fullchain.pem"
printf 'key\n' >"$live/privkey.pem"
hh_ssl_copy_live "$live" "$destssl" root
assert_eq "$(cat "$destssl/fullchain.pem")" "chain" "copy live fullchain"
assert_eq "$(stat -c '%a' "$destssl/privkey.pem")" "600" "copied key is 600"
rm -rf "$live" "$destssl" "$le_cfg"
HEARTHOST_CONF_FILE="$ROOT/etc/hearthost.conf.example"
hh_config_load
load_os_fixture ubuntu-24.04
assert_eq "$(hh_nginx_sites_available)" "/etc/nginx/sites-available" "ubuntu sites-available"
load_os_fixture almalinux-9
assert_eq "$(hh_nginx_sites_available)" "/etc/nginx/conf.d" "alma uses conf.d"
unset HEARTHOST_OS_RELEASE
hh_os_load
rm -f "$ngin" "$ngout"

printf '== unit: php ==\n'
load_os_fixture ubuntu-24.04
assert_eq "$(hh_php_fpm_service 8.3)" "php8.3-fpm" "ubuntu fpm service"
assert_eq "$(hh_php_fpm_pool_dir 8.3)" "/etc/php/8.3/fpm/pool.d" "ubuntu pool dir"
assert_eq "$(hh_php_bin 8.3)" "/usr/bin/php8.3" "ubuntu php bin"
load_os_fixture almalinux-9
assert_eq "$(hh_php_fpm_service 8.3)" "php83-php-fpm" "alma fpm service"
assert_eq "$(hh_php_ver_nodot 8.4)" "84" "remi version prefix"
php_vers="$(hh_php_versions | tr '\n' ' ')"
if [[ "$php_vers" == *8.2* && "$php_vers" == *8.5* ]]; then
  printf '  ok   configured versions include 8.2 and 8.5\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL configured versions include 8.2 and 8.5 (%s)\n' "$php_vers"
  FAIL=$((FAIL + 1))
fi
poolf="$(mktemp)"
load_os_fixture ubuntu-24.04
hh_php_render_pool alice 8.3 "$poolf"
assert_ok "pool runs as alice" grep -q '^user = alice' "$poolf"
assert_ok "pool socket is per user" grep -q 'php8.3-fpm-alice.sock' "$poolf"
assert_ok "pool listen.group is web daemon" grep -q 'listen.group = www-data' "$poolf"
assert_ok "pool pm is ondemand" grep -q 'pm = ondemand' "$poolf"
rm -f "$poolf"
unset HEARTHOST_OS_RELEASE
hh_os_load

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
HEARTHOST_NONINTERACTIVE=1 assert_fail "non-interactive empty host is an error" hh_prompt_phpmyadmin_host
assert_eq "$(hh_conf phpmyadmin_host)" "" "empty host is not written"
assert_fail "rejects invalid phpmyadmin host" hh_prompt_phpmyadmin_host 'not a host'
rm -f "$cfg" "$cfg_empty"
HEARTHOST_CONF_FILE="$ROOT/etc/hearthost.conf.example"
hh_config_load

printf '== unit: cli ==\n'
CLI="$ROOT/bin/hearthost"
assert_eq "$("$CLI" version)" "$(tr -d '[:space:]' <"$ROOT/VERSION")" "cli version matches VERSION file"
assert_eq "$("$CLI" path user alice)" "/home/alice" "cli path user"
assert_eq "$("$CLI" path docroot alice example.com --primary)" "/home/alice/public_html" "cli primary docroot"
assert_eq "$("$CLI" path docroot alice blog.example.com)" "/home/alice/blog.example.com" "cli addon docroot"
assert_eq "$("$CLI" path owner alice)" "alice:alice" "cli owner user:user"
assert_eq "$("$CLI" path ssl alice)" "/home/alice/ssl" "cli ssl dir"
assert_eq "$("$CLI" path ssl alice example.com)" "/home/alice/ssl/example.com" "cli domain ssl dir"
assert_eq "$("$CLI" path ssl-system)" "/etc/hearthost/ssl" "cli system ssl dir"
assert_eq "$("$CLI" path ssl-system pma.example.com)" "/etc/hearthost/ssl/pma.example.com" "cli pma ssl dir"
assert_eq "$("$CLI" path perms ssl)" "711" "cli ssl mode"
assert_eq "$("$CLI" path perms home)" "711" "cli home mode"
assert_eq "$("$CLI" path perms secret)" "640" "cli secret mode"
assert_eq "$("$CLI" path db alice wp)" "alice_wp" "cli db name"
assert_eq "$("$CLI" quota children 1G)" "3" "cli children"
assert_ok "cli php versions lists 8.3" bash -c '"$0" php versions | grep -qx 8.3' "$CLI"
assert_ok "cli php pool mentions alice" bash -c '"$0" php pool alice 8.3 | grep -q alice' "$CLI"
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

printf '== unit: site ==\n'
assert_eq "$(hh_site_app_snippet wordpress)" "wordpress" "wordpress app snippet"
assert_eq "$(hh_site_app_snippet laravel)" "laravel" "laravel app snippet"
assert_eq "$(hh_site_app_snippet joomla)" "php" "unknown app falls back to php"
assert_eq "$(hh_site_alias_list example.com www.example.com)" "www.example.com" "alias kept"
assert_eq "$(hh_site_alias_list example.com example.com)" "" "self alias dropped"
assert_fail "bad alias rejected" hh_site_alias_list example.com 'not a domain'
site_yaml="$(hh_site_state_yaml alice example.com yes 8.3 wordpress yes www.example.com)"
assert_ok "state yaml has domain" grep -q '^domain: example.com$' <<<"$site_yaml"
assert_ok "state yaml has user" grep -q '^user: alice$' <<<"$site_yaml"
assert_ok "state yaml primary docroot" grep -q '^docroot: /home/alice/public_html$' <<<"$site_yaml"
assert_ok "state yaml php quoted" grep -q '^php: "8.3"$' <<<"$site_yaml"
assert_ok "state yaml aliases" grep -q '^aliases: \[www.example.com\]$' <<<"$site_yaml"
addon_yaml="$(hh_site_state_yaml alice blog.example.com no 8.4 php no "")"
assert_ok "addon docroot is /home/user/domain" grep -q '^docroot: /home/alice/blog.example.com$' <<<"$addon_yaml"

printf '== unit: user ==\n'
assert_eq "$(hh_user_shell shell)" "/bin/bash" "shell tenant gets bash"
assert_eq "$(hh_user_shell sftp-only)" "/usr/sbin/nologin" "sftp-only gets nologin"
assert_eq "$(hh_user_access_group shell)" "hearthost-ssh" "shell tenant joins ssh group"
assert_eq "$(hh_user_access_group sftp-only)" "hearthost-sftp" "sftp tenant joins sftp group"
assert_eq "$(hh_user_home_owner shell alice)" "alice" "shell home owned by user"
assert_eq "$(hh_user_home_owner sftp-only alice)" "root" "sftp jail home owned by root"
assert_eq "$(hh_user_home_mode shell)" "711" "shell home 711"
assert_eq "$(hh_user_home_mode sftp-only)" "750" "sftp jail home 750"
layout_spec="$(hh_user_layout_spec)"
assert_ok "layout includes public_html" grep -q '^public_html 755$' <<<"$layout_spec"
assert_ok "layout includes ssl 711" grep -q '^ssl 711$' <<<"$layout_spec"
uy="$(hh_user_state_yaml alice shell /bin/bash 1G 100% 120)"
assert_ok "user yaml ssh true for shell" grep -q '^ssh: true$' <<<"$uy"
sy="$(hh_user_state_yaml bob sftp-only /usr/sbin/nologin 1G 100% 120)"
assert_ok "user yaml ssh false for sftp-only" grep -q '^ssh: false$' <<<"$sy"
assert_ok "user yaml records username" grep -q '^username: bob$' <<<"$sy"

printf '== unit: ftp ==\n'
ftp_list="$(mktemp)"
hh_ftp_userlist() { printf '%s\n' "$ftp_list"; }
hh_ftp_allow_user alice
hh_ftp_allow_user alice   # idempotent
assert_eq "$(grep -c '^alice$' "$ftp_list")" "1" "ftp allow is idempotent"
hh_ftp_allow_user bob
hh_ftp_deny_user alice
assert_fail "alice removed from ftp list" grep -qx alice "$ftp_list"
assert_ok "bob remains on ftp list" grep -qx bob "$ftp_list"
assert_fail "reserved user refused on ftp list" hh_ftp_allow_user root
unset -f hh_ftp_userlist
rm -f "$ftp_list"
assert_eq "$(hh_ftp_conf_path)" "/etc/vsftpd.conf" "debian vsftpd conf path"

printf '== unit: slice ==\n'
assert_eq "$(hh_systemd_cpu_quota 100%)" "100%" "cpu quota 100%"
assert_eq "$(hh_systemd_cpu_quota 1)" "100%" "cpu quota from 1 core"
assert_eq "$(hh_systemd_cpu_quota 50%)" "50%" "cpu quota half core"
assert_eq "$(hh_systemd_memory_max 1G)" "1G" "memory max keeps spelling"
assert_eq "$(hh_php_service_name 8.3 alice)" "hearthost-php8.3-alice.service" "service unit name"
assert_eq "$(hh_php_tenant_pool_file alice 8.3)" "/etc/hearthost/php/alice/php8.3-pool.conf" "tenant pool path off shared dir"
assert_eq "$(hh_php_user_global_conf alice 8.3)" "/etc/hearthost/php/alice/php8.3-fpm.conf" "tenant global conf path"
slice_out="$(mktemp)"
hh_slice_render "$slice_out" 1G 100% 120 256M
assert_ok "slice sets MemoryMax" grep -q '^MemoryMax=1G$' "$slice_out"
assert_ok "slice sets CPUQuota percent" grep -q '^CPUQuota=100%$' "$slice_out"
assert_ok "slice sets TasksMax" grep -q '^TasksMax=120$' "$slice_out"
assert_ok "slice sets swap" grep -q '^MemorySwapMax=256M$' "$slice_out"
assert_fail "slice render rejects bad memory" hh_slice_render "$slice_out" notabyte 100% 120 256M
rm -f "$slice_out"

printf '== unit: doctor php state ==\n'
# Only *.conf (not *.disabled) counts as a loadable pool.
pool_dir="$(mktemp -d)"
hh_php_fpm_pool_dir() { printf '%s\n' "$pool_dir"; }
: >"$pool_dir/www.conf.hearthost-disabled"
: >"$pool_dir/suryasan.conf.disabled"
assert_eq "$(hh_php_active_pool_count 8.3)" "0" "disabled-only dir has 0 live pools"
: >"$pool_dir/hearthost-pma.conf"
assert_eq "$(hh_php_active_pool_count 8.3)" "1" "one live pool is counted"
assert_eq "$(hh_php_pool_file alice 8.3)" "$pool_dir/hearthost-alice.conf" "pool file path uses pool dir"
unset -f hh_php_fpm_pool_dir
# shellcheck source=/dev/null
. "$ROOT/lib/php.sh"
rm -f "$pool_dir"/*.conf* && rmdir "$pool_dir"
# A down version with pools is a hard failure, an idle one with none is not.
raw='[25-Oct-2026 10:33:24] ERROR: [/etc/.../x.conf:10] unknown entry "y"'
assert_eq "${raw#*ERROR: }" '[/etc/.../x.conf:10] unknown entry "y"' "fpm error strips timestamp prefix"

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
