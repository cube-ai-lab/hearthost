# KEY=value config loader.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_CONFIG_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_CONFIG_LOADED=1

declare -Ag HEARTHOST_CONF=()

hh_config_files() {
  local root
  root="$(hearthost_root)"
  printf '%s\n' "$root/etc/hearthost.conf.example"
  if [[ -n "${HEARTHOST_CONF_FILE:-}" && -f "${HEARTHOST_CONF_FILE}" ]]; then
    printf '%s\n' "$HEARTHOST_CONF_FILE"
  elif [[ -f /etc/hearthost/hearthost.conf ]]; then
    printf '%s\n' /etc/hearthost/hearthost.conf
  elif [[ -f "$root/etc/hearthost.conf" ]]; then
    printf '%s\n' "$root/etc/hearthost.conf"
  fi
}

hh_config_load() {
  HEARTHOST_CONF=()
  local file line key value
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%$'\r'}"
      [[ -z "$line" || "$line" == \#* ]] && continue
      if [[ "$line" != *=* ]]; then
        continue
      fi
      key="${line%%=*}"
      value="${line#*=}"
      key="${key%"${key##*[![:space:]]}"}"
      key="${key#"${key%%[![:space:]]*}"}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
      fi
      HEARTHOST_CONF["$key"]="$value"
    done <"$file"
  done < <(hh_config_files)
}

hh_conf() {
  local key="$1"
  local default="${2:-}"
  if [[ -v HEARTHOST_CONF[$key] ]]; then
    printf '%s\n' "${HEARTHOST_CONF[$key]}"
  else
    printf '%s\n' "$default"
  fi
}

hh_conf_bool() {
  local raw
  raw="$(hh_conf "$1" "${2:-no}")"
  case "${raw,,}" in
    1|yes|true|on) return 0 ;;
    *) return 1 ;;
  esac
}

hh_conf_writable_file() {
  if [[ -n "${HEARTHOST_CONF_FILE:-}" ]]; then
    printf '%s\n' "$HEARTHOST_CONF_FILE"
  elif [[ -f /etc/hearthost/hearthost.conf ]]; then
    printf '%s\n' /etc/hearthost/hearthost.conf
  else
    printf '%s\n' /etc/hearthost/hearthost.conf
  fi
}

# Update KEY=value in the writable config file and in the loaded map.
hh_conf_set() {
  local key="$1"
  local value="$2"
  local file tmp
  file="$(hh_conf_writable_file)"
  mkdir -p "$(dirname "$file")"
  [[ -f "$file" ]] || touch "$file"
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    $0 ~ ("^" k "=") {
      if (!done) {
        print k "=" v
        done = 1
      }
      next
    }
    { print }
    END {
      if (!done) print k "=" v
    }
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
  HEARTHOST_CONF["$key"]="$value"
}

hh_interactive() {
  [[ -z "${HEARTHOST_NONINTERACTIVE:-}" && -t 0 && -t 2 ]]
}

# Resolve phpMyAdmin hostname from flag, env, existing config, or a TTY prompt.
# Never inferred from the machine hostname (PTRs are not a dedicated admin name).
hh_prompt_phpmyadmin_host() {
  local supplied="${1:-}"
  local current
  if [[ -n "$supplied" ]]; then
    current="$supplied"
  elif [[ -n "${HEARTHOST_PHPMYADMIN_HOST:-}" ]]; then
    current="$HEARTHOST_PHPMYADMIN_HOST"
  else
    current="$(hh_conf phpmyadmin_host "")"
  fi
  current="${current,,}"
  current="${current#"${current%%[![:space:]]*}"}"
  current="${current%"${current##*[![:space:]]}"}"

  if [[ -n "$current" ]]; then
    if ! hh_valid_domain "$current"; then
      hh_error "invalid phpmyadmin_host: $current"
      return 1
    fi
    hh_conf_set phpmyadmin_host "$current"
    hh_info "phpMyAdmin hostname: $current"
    return 0
  fi

  if ! hh_interactive; then
    hh_warn "phpmyadmin_host is empty. Re-run on a TTY or pass --phpmyadmin-host=pma.example.com"
    return 0
  fi

  local answer
  while true; do
    printf 'phpMyAdmin hostname (dedicated FQDN, e.g. pma.example.com): ' >&2
    IFS= read -r answer || answer=""
    answer="${answer,,}"
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
    if hh_valid_domain "$answer"; then
      hh_conf_set phpmyadmin_host "$answer"
      hh_info "phpMyAdmin hostname: $answer"
      return 0
    fi
    printf 'Use a full domain like pma.example.com (not an IP or a PTR hostname).\n' >&2
  done
}
