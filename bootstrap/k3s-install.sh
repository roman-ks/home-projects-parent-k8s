#!/usr/bin/env bash
# Runs on the node as root (piped via `sudo bash -s -- <k3s-version>`).
# Installs a pinned k3s and waits for the apiserver to report ready.
set -euo pipefail

K3S_VERSION="${1:?k3s version arg missing}"

# Prereq: memory cgroup controller must be live (needs bootstrap-cgroups + reboot).
if ! grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
  echo "ERROR: memory cgroup controller not enabled — run bootstrap-cgroups and reboot first." >&2
  exit 1
fi

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -

# The apiserver isn't ready the instant the installer returns — poll /readyz.
echo "Waiting for node readiness..."
deadline=$(( $(date +%s) + 90 ))
until [ "$(k3s kubectl get --raw='/readyz' 2>/dev/null)" = "ok" ]; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "ERROR: k3s not ready after 90s" >&2
    k3s kubectl get --raw='/readyz?verbose' 2>/dev/null || true
    exit 1
  fi
  sleep 3
done
echo "k3s is ready (/readyz = ok)"
