#!/usr/bin/env bash
# @Name:        Linux Health Check (SSH)
# @Description: Checks a Linux server over SSH: OS, uptime, load, memory, full filesystems, failed systemd units, pending reboot, available updates and recent journal errors. Put user@host in the Target box (SSH key sign-in).
# @Admin:       No
# @Changes:     No
# @Target:      Remote
# @Param:       DiskWarn | int | 85 | Warn when a filesystem is at least this % full
# @Param:       JournalLines | int | 15 | How many recent error lines to show
# @Tags:        linux, ssh, health, disk, systemd, bash

DISKWARN=85
JLINES=15
while [ $# -gt 0 ]; do
  case "$1" in
    --DiskWarn) DISKWARN="$2"; shift 2 ;;
    --JournalLines) JLINES="$2"; shift 2 ;;
    *) shift ;;
  esac
done

os="$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || uname -sr )"
echo "== $(hostname)  ($os)"
echo "Uptime: $(uptime -p 2>/dev/null || uptime)"
echo "Load:   $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)   CPUs: $(nproc 2>/dev/null)"
echo
echo "== Memory"
free -h 2>/dev/null | awk 'NR==1 || /Mem|Swap/'
echo
echo "== Filesystems (warn at ${DISKWARN}%)"
df -hP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk -v w="$DISKWARN" '
  NR==1 { print; next }
  { p=$5; sub("%","",p); flag=(p+0>=w) ? "   <-- WARN" : ""; print $0 flag }'
echo
echo "== Failed systemd units"
if command -v systemctl >/dev/null 2>&1; then
  failed="$(systemctl --failed --no-legend --plain 2>/dev/null)"
  if [ -n "$failed" ]; then echo "$failed" | sed 's/^/  /'; else echo "  none"; fi
else
  echo "  systemd not present"
fi
echo
echo "== Reboot needed"
if [ -f /var/run/reboot-required ]; then echo "  yes (/var/run/reboot-required)"
elif command -v needs-restarting >/dev/null 2>&1 && ! needs-restarting -r >/dev/null 2>&1; then echo "  yes (needs-restarting)"
else echo "  no"; fi
echo
echo "== Updates available"
if command -v apt >/dev/null 2>&1; then
  echo "  apt: $(apt list --upgradable 2>/dev/null | grep -vc '^Listing')"
elif command -v dnf >/dev/null 2>&1; then
  echo "  dnf: $(dnf -q check-update 2>/dev/null | grep -c '^[[:alnum:]]')"
elif command -v yum >/dev/null 2>&1; then
  echo "  yum: $(yum -q check-update 2>/dev/null | grep -c '^[[:alnum:]]')"
else
  echo "  unknown package manager"
fi
echo
echo "== Recent errors (last 24h)"
if command -v journalctl >/dev/null 2>&1; then
  journalctl -p err --since "24 hours ago" --no-pager -q 2>/dev/null | tail -n "$JLINES" | sed 's/^/  /'
else
  tail -n "$JLINES" /var/log/syslog 2>/dev/null || tail -n "$JLINES" /var/log/messages 2>/dev/null
fi
