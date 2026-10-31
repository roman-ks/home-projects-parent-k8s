#!/bin/bash
set -Eeuo pipefail

exec >> /var/log/provision.log 2>&1
echo "=== Provisioning started: $(date --iso-8601=seconds) ==="

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y upgrade
apt-get -y install cryptsetup systemd-cryptsetup

#--- Install K3s
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.36.1+k3s1" sh -

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


udo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald

echo "=== Provisioning completed: $(date --iso-8601=seconds) ==="