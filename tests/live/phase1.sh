#!/usr/bin/env bash
# Live checks after `hearthost init hardening`. Must run as root on the VPS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

printf '== live: phase1 ==\n'
check "hearthost-ssh group" getent group hearthost-ssh
check "hearthost-sftp group" getent group hearthost-sftp
check "root in hearthost-ssh" bash -c 'id -nG root | grep -qw hearthost-ssh'
check "AllowUsers disabled in sshd_config" bash -c '! grep -Eq "^[[:space:]]*AllowUsers[[:space:]]+" /etc/ssh/sshd_config'
check "sshd drop-in installed" test -f /etc/ssh/sshd_config.d/60-hearthost.conf
check "sshd -t" sshd -t
check "sshd AllowGroups" bash -c 'sshd -T | grep -Eq "^allowgroups .*hearthost-ssh"'
check "X11Forwarding off" bash -c 'sshd -T | grep -q "^x11forwarding no"'
check "TCP forwarding still on" bash -c 'sshd -T | grep -q "^allowtcpforwarding yes"'
check "UFW active" bash -c 'ufw status | grep -qi "Status: active"'
check "UFW 22" bash -c 'ufw status | grep -Eq "22/tcp|OpenSSH"'
check "UFW 80" bash -c 'ufw status | grep -q "80/tcp"'
check "UFW 443" bash -c 'ufw status | grep -q "443/tcp"'
check "fail2ban active" systemctl is-active --quiet fail2ban
check "fail2ban sshd jail" bash -c 'fail2ban-client status sshd >/dev/null'
check "kptr_restrict=2" bash -c '[[ "$(sysctl -n kernel.kptr_restrict)" == "2" ]]'
check "rp_filter=1" bash -c '[[ "$(sysctl -n net.ipv4.conf.all.rp_filter)" == "1" ]]'
check "unattended-upgrades enabled" systemctl is-enabled --quiet unattended-upgrades
check "runtime config exists" test -f /etc/hearthost/hearthost.conf
check "sshd backup exists" bash -c 'ls /etc/hearthost/backups/sshd_config.* >/dev/null'

set +e
doctor_out="$("$ROOT/bin/hearthost" doctor 2>&1)"
doctor_rc=$?
set -e
if [[ "$doctor_rc" == "0" ]]; then
  ok "doctor still exits 0"
else
  fail "doctor exit $doctor_rc"
  printf '%s\n' "$doctor_out"
fi
if [[ "$doctor_out" == *"UFW active"* ]]; then
  ok "doctor sees UFW"
else
  fail "doctor missing UFW ok"
fi
if [[ "$doctor_out" == *"AllowGroups"* ]]; then
  ok "doctor sees SSH groups"
else
  fail "doctor missing SSH groups"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
