#!/usr/bin/env bash
# Live checks for Phase 8: logrotate config parses, the backup timer is
# enabled, and `hearthost health` runs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export HEARTHOST_ROOT="$ROOT"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/config.sh"
hh_config_load

PASS=0
FAIL=0
ok() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

printf '== live: phase8 ==\n'

if [[ -f /etc/logrotate.d/hearthost ]]; then
  if logrotate -d /etc/logrotate.d/hearthost >/dev/null 2>&1; then
    ok "logrotate config installed and parses"
  else
    fail "logrotate config present but fails dry run"
  fi
else
  fail "logrotate config missing (run hearthost init logrotate)"
fi

if systemctl is-enabled --quiet hearthost-backup.timer 2>/dev/null; then
  ok "nightly backup timer enabled"
else
  fail "backup timer not enabled (run hearthost init backups)"
fi

if [[ -d "$(hh_conf backup_dir /var/backups/hearthost)" ]]; then
  ok "backup dir exists ($(hh_conf backup_dir /var/backups/hearthost))"
else
  printf '  info backup dir not created yet (run a backup)\n'
fi

if "$ROOT/bin/hearthost" health >/dev/null 2>&1; then
  ok "hearthost health reports no problems"
else
  fail "hearthost health reports problems (run: hearthost health)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
