#!/usr/bin/env bash
# Runs on the node as root (piped via `sudo bash -s`).
# Enables the memory cgroup in cmdline.txt, then reboots (detached).
set -euo pipefail

FILE=/boot/firmware/cmdline.txt
[ -f "$FILE" ] || { echo "ERROR: $FILE not found (is this Raspberry Pi OS?)" >&2; exit 1; }

# cmdline.txt MUST stay a single line — append only the missing tokens to line 1.
missing=""
for token in cgroup_memory=1 cgroup_enable=memory; do
  grep -qw -- "$token" "$FILE" || missing="$missing $token"
done

if [ -n "$missing" ]; then
  sed -i "1 s|\$|$missing|" "$FILE"
  echo "Added cgroup params:$missing"
else
  echo "cgroup params already present, no change"
fi

# Detach the reboot so this ssh command returns cleanly instead of dying with
# the dropped connection (keeps the recipe unattended).
echo "Scheduling reboot in 3s..."
systemd-run --on-active=3s --timer-property=AccuracySec=100ms reboot >/dev/null
