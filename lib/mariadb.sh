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
    hh_info "MariaDB listening on $bind"
  else
    hh_die "MariaDB installed but root unix_socket login failed"
  fi
}
