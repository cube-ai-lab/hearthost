# OS detection for Ubuntu LTS and AlmaLinux. Testable via HEARTHOST_OS_RELEASE.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_OS_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_OS_LOADED=1

HH_OS_ID=""
HH_OS_VERSION_ID=""
HH_OS_ID_LIKE=""
HH_OS_PRETTY=""
HH_OS_FAMILY=""
HH_OS_MAJOR=""

hh_os_release_file() {
  printf '%s\n' "${HEARTHOST_OS_RELEASE:-/etc/os-release}"
}

hh_os_load() {
  local file
  file="$(hh_os_release_file)"
  HH_OS_ID=""
  HH_OS_VERSION_ID=""
  HH_OS_ID_LIKE=""
  HH_OS_PRETTY=""
  HH_OS_FAMILY=""
  HH_OS_MAJOR=""
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  # Isolate assignments from the live shell.
  eval "$(
    # shellcheck disable=SC1090
    . "$file"
    printf 'HH_OS_ID=%q\n' "${ID:-}"
    printf 'HH_OS_VERSION_ID=%q\n' "${VERSION_ID:-}"
    printf 'HH_OS_ID_LIKE=%q\n' "${ID_LIKE:-}"
    printf 'HH_OS_PRETTY=%q\n' "${PRETTY_NAME:-${NAME:-unknown}}"
  )"
  HH_OS_MAJOR="${HH_OS_VERSION_ID%%.*}"
  case "$HH_OS_ID" in
    ubuntu) HH_OS_FAMILY=debian ;;
    almalinux) HH_OS_FAMILY=rhel ;;
    *)
      case " $HH_OS_ID_LIKE " in
        *" debian "*) HH_OS_FAMILY=debian ;;
        *" rhel "*|*" fedora "*|*" centos "*) HH_OS_FAMILY=rhel ;;
        *) HH_OS_FAMILY=unknown ;;
      esac
      ;;
  esac
}

hh_os_id() { [[ -n "$HH_OS_ID" ]] || hh_os_load; printf '%s\n' "$HH_OS_ID"; }
hh_os_version() { [[ -n "$HH_OS_ID" ]] || hh_os_load; printf '%s\n' "$HH_OS_VERSION_ID"; }
hh_os_family() { [[ -n "$HH_OS_ID" ]] || hh_os_load; printf '%s\n' "$HH_OS_FAMILY"; }
hh_os_pretty() { [[ -n "$HH_OS_ID" ]] || hh_os_load; printf '%s\n' "$HH_OS_PRETTY"; }
hh_os_major() { [[ -n "$HH_OS_ID" ]] || hh_os_load; printf '%s\n' "$HH_OS_MAJOR"; }

# Ubuntu LTS is even-year .04, from 22.04 onward (22.04, 24.04, 26.04, …).
hh_os_is_ubuntu_lts() {
  [[ -n "$HH_OS_ID" ]] || hh_os_load
  [[ "$HH_OS_ID" == "ubuntu" ]] || return 1
  [[ "$HH_OS_VERSION_ID" =~ ^([0-9]+)\.04$ ]] || return 1
  local major="${BASH_REMATCH[1]}"
  ((major >= 22 && major % 2 == 0))
}

# AlmaLinux 9.x and 10.x.
hh_os_is_almalinux() {
  [[ -n "$HH_OS_ID" ]] || hh_os_load
  [[ "$HH_OS_ID" == "almalinux" ]] || return 1
  [[ "$HH_OS_MAJOR" == "9" || "$HH_OS_MAJOR" == "10" ]]
}

hh_os_supported() {
  hh_os_is_ubuntu_lts || hh_os_is_almalinux
}

hh_os_supported_list() {
  printf 'Ubuntu LTS 22.04+ (22.04, 24.04, 26.04, …) or AlmaLinux 9.x / 10.x\n'
}

# Nginx worker account. Used only as listen.group on the PHP-FPM socket.
# Tenant files are never owned by this user — see lib/perms.sh (USER:USER).
hh_os_web_user() {
  case "$(hh_os_family)" in
    rhel) printf 'nginx\n' ;;
    *) printf 'www-data\n' ;;
  esac
}

hh_sshd_reload() {
  if systemctl cat ssh.service >/dev/null 2>&1; then
    systemctl reload ssh
  else
    systemctl reload sshd
  fi
}

hh_pkg_installed() {
  local name="$1"
  case "$(hh_os_family)" in
    rhel) rpm -q "$name" >/dev/null 2>&1 ;;
    *) dpkg -s "$name" >/dev/null 2>&1 ;;
  esac
}

hh_pkg_install() {
  case "$(hh_os_family)" in
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq "$@" >/dev/null
      ;;
    rhel)
      if ! hh_pkg_installed epel-release; then
        dnf -y install epel-release >/dev/null
      fi
      dnf -y install "$@" >/dev/null
      ;;
    *)
      hh_die "cannot install packages on family $(hh_os_family)"
      ;;
  esac
}
