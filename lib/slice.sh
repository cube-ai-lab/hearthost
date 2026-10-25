# Phase 6: per-tenant systemd cgroup v2 caps (CloudLinux LVE-style).
# Each tenant's logind user-{uid}.slice gets a drop-in with MemoryMax/
# CPUQuota/TasksMax. SSH/SFTP sessions land there automatically and the
# tenant's PHP-FPM master (lib/php.sh) is pinned there too, so one cap
# covers the whole tenant.
# shellcheck shell=bash

if [[ -n "${HEARTHOST_SLICE_LOADED:-}" ]]; then
  return 0
fi
HEARTHOST_SLICE_LOADED=1

# Limits for a user: explicit args win, else the user's state YAML, else config
# defaults. Echoes "MEMORY CPU TASKS SWAP".
hh_slice_limits() {
  local user="$1"
  local mem="${2:-}" cpu="${3:-}" tasks="${4:-}"
  local state
  state="$(hh_user_state "$user")"
  if [[ -f "$state" ]]; then
    [[ -n "$mem" ]] || mem="$(sed -n 's/^memory:[[:space:]]*//p' "$state" | head -1)"
    [[ -n "$cpu" ]] || cpu="$(sed -n 's/^cpu:[[:space:]]*//p' "$state" | head -1)"
    [[ -n "$tasks" ]] || tasks="$(sed -n 's/^tasks:[[:space:]]*//p' "$state" | head -1)"
  fi
  [[ -n "$mem" ]] || mem="$(hh_conf default_memory 1G)"
  [[ -n "$cpu" ]] || cpu="$(hh_conf default_cpu 100%)"
  [[ -n "$tasks" ]] || tasks="$(hh_conf default_tasks 120)"
  local swap
  swap="$(hh_conf default_swap 256M)"
  printf '%s %s %s %s\n' "$mem" "$cpu" "$tasks" "$swap"
}

# Pure: render the [Slice] drop-in to dest.
hh_slice_render() {
  local dest="$1" mem="$2" cpu="$3" tasks="$4" swap="$5"
  local mem_v cpu_v swap_v
  mem_v="$(hh_systemd_memory_max "$mem")" || { hh_error "bad memory: $mem"; return 1; }
  cpu_v="$(hh_systemd_cpu_quota "$cpu")" || { hh_error "bad cpu: $cpu"; return 1; }
  swap_v="$(hh_systemd_memory_max "$swap")" || swap_v="$swap"
  hh_nginx_subst "$(hearthost_root)/templates/systemd/user-slice-dropin.conf" "$dest" \
    "CPU_QUOTA=$cpu_v" \
    "MEMORY_MAX=$mem_v" \
    "SWAP_MAX=$swap_v" \
    "TASKS_MAX=$tasks"
}

# Apply the cap to a tenant's user-{uid}.slice. Root.
hh_slice_apply() {
  hh_require_root
  hh_config_load
  local user="${1:-}"
  shift || true
  local mem="" cpu="" tasks=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --memory) mem="${2:-}"; shift ;;
      --memory=*) mem="${1#*=}" ;;
      --cpu) cpu="${2:-}"; shift ;;
      --cpu=*) cpu="${1#*=}" ;;
      --tasks) tasks="${2:-}"; shift ;;
      --tasks=*) tasks="${1#*=}" ;;
      *) hh_die "usage: hearthost slice apply USER [--memory M] [--cpu C] [--tasks N]" ;;
    esac
    shift
  done
  [[ -n "$user" ]] || hh_die "usage: hearthost slice apply USER [...]"
  hh_valid_username "$user" || hh_die "invalid username: $user"
  getent passwd "$user" >/dev/null || hh_die "user $user does not exist"

  local dropin limits
  dropin="$(hh_user_slice_dropin "$user")" || hh_die "cannot resolve uid for $user"
  read -r mem cpu tasks swap < <(hh_slice_limits "$user" "$mem" "$cpu" "$tasks")

  mkdir -p "$(dirname "$dropin")"
  hh_slice_render "$dropin" "$mem" "$cpu" "$tasks" "$swap" || hh_die "could not render slice drop-in"
  chmod 644 "$dropin"
  systemctl daemon-reload

  # Apply to the running slice too (systemd creates it lazily; set-property
  # succeeds once it exists, e.g. after a login or the tenant FPM start).
  local slice
  slice="$(hh_user_session_slice "$user")"
  if systemctl show "$slice" >/dev/null 2>&1; then
    local cpu_v
    cpu_v="$(hh_systemd_cpu_quota "$cpu")"
    systemctl set-property "$slice" \
      "MemoryMax=$(hh_systemd_memory_max "$mem")" \
      "CPUQuota=$cpu_v" \
      "TasksMax=$tasks" >/dev/null 2>&1 || true
  fi
  hh_info "slice cap for $user: MemoryMax=$mem CPUQuota=$(hh_systemd_cpu_quota "$cpu") TasksMax=$tasks ($slice)"
}

hh_slice_remove() {
  local user="$1"
  local dropin
  dropin="$(hh_user_slice_dropin "$user" 2>/dev/null)" || return 0
  if [[ -f "$dropin" ]]; then
    rm -f "$dropin"
    rmdir "$(dirname "$dropin")" 2>/dev/null || true
    systemctl daemon-reload
    hh_info "removed slice cap for $user"
  fi
}
