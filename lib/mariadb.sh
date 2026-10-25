# MariaDB install and isolation helpers.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_MARIADB_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_MARIADB_LOADED=1

hh_mariadb_bind_address() {
  hh_conf mysql_bind 127.0.0.1
}

hh_mariadb_bind_ok() {
  case "$(hh_mariadb_bind_address)" in
    127.0.0.1|::1|localhost) return 0 ;;
    *) return 1 ;;
  esac
}

# GRANT pattern: alice\_%  (underscore escaped so it is not a LIKE wildcard)
hh_db_grant_pattern() {
  local user="$1"
  local sep
  sep="$(hh_conf mysql_prefix_separator _)"
  printf '%s\\%s%%\n' "$user" "$sep"
}

hh_db_tenant_grant_sql() {
  local user="$1"
  local pattern
  pattern="$(hh_db_grant_pattern "$user")"
  printf "CREATE USER IF NOT EXISTS '%s'@'localhost' IDENTIFIED VIA unix_socket;\n" "$user"
  printf "GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'localhost';\n" "$pattern" "$user"
}

hh_db_single_grant_sql() {
  local dbuser="$1"
  local dbname="$2"
  printf "GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'localhost';\n" "$dbname" "$dbuser"
}

hh_mariadb_conf_dir() {
  case "$(hh_os_family)" in
    rhel) printf '/etc/my.cnf.d\n' ;;
    *) printf '/etc/mysql/mariadb.conf.d\n' ;;
  esac
}

hh_mariadb_service() {
  if systemctl cat mariadb.service >/dev/null 2>&1; then
    printf 'mariadb\n'
  elif systemctl cat mysqld.service >/dev/null 2>&1; then
    printf 'mysqld\n'
  else
    printf 'mariadb\n'
  fi
}

hh_mysql() {
  mysql --protocol=socket -uroot "$@"
}

# CREATE DATABASE {user}_{name} and ensure the tenant's unix_socket login +
# user_% grant exist. Root. Idempotent.
hh_db_create() {
  hh_require_root
  hh_os_load
  hh_config_load
  local user="${1:-}" name="${2:-}"
  [[ -n "$user" && -n "$name" ]] || hh_die "usage: hearthost db create USER NAME"
  hh_valid_username "$user" || hh_die "invalid username: $user"
  getent passwd "$user" >/dev/null || hh_die "user $user does not exist"
  # Strip any user_ prefix the caller already applied before validating.
  local sep bare
  sep="$(hh_conf mysql_prefix_separator _)"
  bare="$name"
  [[ "$bare" == "${user}${sep}"* ]] && bare="${bare#"${user}${sep}"}"
  hh_valid_dbname "$bare" || hh_die "invalid database name: $bare (use a-z 0-9 _)"
  mysqladmin --protocol=socket -uroot ping >/dev/null 2>&1 || hh_die "MariaDB not reachable"

  local dbname
  dbname="$(hh_db_name "$user" "$bare")"
  {
    printf "CREATE DATABASE IF NOT EXISTS \`%s\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n" "$dbname"
    hh_db_tenant_grant_sql "$user"
    printf "FLUSH PRIVILEGES;\n"
  } | mysql --protocol=socket -uroot || hh_die "failed to create database $dbname"
  hh_info "database $dbname ready (login $user via unix_socket)"
  printf '%s\n' "$dbname"
}

hh_db_user_create() {
  hh_require_root
  hh_os_load
  hh_config_load

  local user="" dbname="" dbuser="" password=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --password) password="${2:-}"; shift ;;
      --password=*) password="${1#*=}" ;;
      *)
        if [[ -z "$user" ]]; then user="$1"
        elif [[ -z "$dbname" ]]; then dbname="$1"
        elif [[ -z "$dbuser" ]]; then dbuser="$1"
        else hh_die "usage: hearthost db user TENANT DBNAME DBUSER [--password PW]"
        fi ;;
    esac
    shift
  done

  [[ -n "$user" && -n "$dbname" && -n "$dbuser" ]] || \
    hh_die "usage: hearthost db user TENANT DBNAME DBUSER [--password PW]"
  hh_valid_username "$user" || hh_die "invalid tenant: $user"
  getent passwd "$user" >/dev/null || hh_die "tenant $user does not exist"
  mysqladmin --protocol=socket -uroot ping >/dev/null 2>&1 || hh_die "MariaDB not reachable"

  local sep bare fulldb
  sep="$(hh_conf mysql_prefix_separator _)"
  bare="$dbname"
  [[ "$bare" == "${user}${sep}"* ]] && bare="${bare#"${user}${sep}"}"
  fulldb="$(hh_db_name "$user" "$bare")"

  mysql --protocol=socket -uroot -N -B -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$fulldb';" \
    | grep -q . || hh_die "database $fulldb does not exist (create it first: hearthost db create $user $bare)"

  local fulluser="${user}${sep}${dbuser}"
  [[ ${#fulluser} -le 80 ]] || hh_die "db username too long: $fulluser (max 80)"

  if [[ -z "$password" ]]; then
    password="$(openssl rand -base64 18)"
  fi

  mysql --protocol=socket -uroot <<SQL || hh_die "failed to create db user $fulluser"
CREATE USER IF NOT EXISTS '${fulluser}'@'localhost' IDENTIFIED BY '${password}';
ALTER USER '${fulluser}'@'localhost' IDENTIFIED BY '${password}';
GRANT ALL PRIVILEGES ON \`${fulldb}\`.* TO '${fulluser}'@'localhost';
FLUSH PRIVILEGES;
SQL

  hh_info "db user $fulluser created with access to $fulldb"
  printf 'database=%s\nusername=%s\npassword=%s\nhost=localhost\n' "$fulldb" "$fulluser" "$password"
}

hh_db_user_list() {
  hh_require_root
  hh_config_load
  local user="${1:-}"
  [[ -n "$user" ]] || hh_die "usage: hearthost db user list TENANT"
  hh_valid_username "$user" || hh_die "invalid tenant: $user"
  mysqladmin --protocol=socket -uroot ping >/dev/null 2>&1 || hh_die "MariaDB not reachable"

  local sep pattern
  sep="$(hh_conf mysql_prefix_separator _)"
  pattern="${user}${sep}%"

  mysql --protocol=socket -uroot -N -B -e \
    "SELECT u.User, GROUP_CONCAT(d.Db ORDER BY d.Db SEPARATOR ', ')
     FROM mysql.user u
     LEFT JOIN mysql.db d ON d.User = u.User AND d.Host = u.Host
     WHERE u.User LIKE '$pattern' AND u.Host = 'localhost'
     GROUP BY u.User;" 2>/dev/null
}

hh_db_user_del() {
  hh_require_root
  hh_config_load
  local user="${1:-}" dbuser="${2:-}"
  [[ -n "$user" && -n "$dbuser" ]] || hh_die "usage: hearthost db user del TENANT DBUSER"
  hh_valid_username "$user" || hh_die "invalid tenant: $user"
  mysqladmin --protocol=socket -uroot ping >/dev/null 2>&1 || hh_die "MariaDB not reachable"

  local sep fulluser
  sep="$(hh_conf mysql_prefix_separator _)"
  fulluser="${user}${sep}${dbuser}"

  mysql --protocol=socket -uroot -e "DROP USER IF EXISTS '${fulluser}'@'localhost'; FLUSH PRIVILEGES;" \
    || hh_die "failed to drop db user $fulluser"
  hh_info "db user $fulluser removed"
}

hh_mariadb_apply() {
  hh_require_root
  hh_os_load
  hh_os_supported || hh_die "unsupported OS: $(hh_os_pretty). Need $(hh_os_supported_list)"
  hh_config_load
  hh_mariadb_bind_ok || hh_die "mysql_bind must be 127.0.0.1 (refusing $(hh_mariadb_bind_address))"

  hh_info "installing MariaDB"
  case "$(hh_os_family)" in
    rhel) hh_pkg_install mariadb-server mariadb ;;
    *) hh_pkg_install mariadb-server mariadb-client ;;
  esac

  local confd dest root bind
  root="$(hearthost_root)"
  confd="$(hh_mariadb_conf_dir)"
  dest="$confd/99-hearthost.cnf"
  bind="$(hh_mariadb_bind_address)"
  mkdir -p "$confd"
  hh_nginx_subst "$root/templates/mariadb/99-hearthost.cnf" "$dest" "BIND=$bind"
  chmod 644 "$dest"

  local svc
  svc="$(hh_mariadb_service)"
  systemctl enable --now "$svc" >/dev/null
  systemctl restart "$svc"

  if mysqladmin --protocol=socket -uroot ping >/dev/null 2>&1; then
    mysql --protocol=socket -uroot -e "DELETE FROM mysql.user WHERE User=''; DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES;" >/dev/null 2>&1 || true
    hh_mariadb_root_password
    hh_info "MariaDB listening on $bind"
  else
    hh_die "MariaDB installed but root unix_socket login failed"
  fi
}

hh_mariadb_root_password() {
  local passfile=/etc/hearthost/mariadb_root_pass
  local mycnf=/root/.my.cnf
  local pass

  if [[ -s "$passfile" ]]; then
    pass="$(tr -d '\n' <"$passfile")"
  else
    pass="$(openssl rand -base64 18)"
    mkdir -p /etc/hearthost
    printf '%s' "$pass" >"$passfile"
    chmod 600 "$passfile"
  fi

  mysql --protocol=socket -uroot -e \
    "ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('$pass') OR unix_socket; FLUSH PRIVILEGES;" \
    2>/dev/null || true

  cat >"$mycnf" <<EOF
[client]
user=root
password=$pass
EOF
  chmod 600 "$mycnf"
  hh_info "root MySQL password set (/root/.my.cnf)"
}
