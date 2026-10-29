#!/bin/bash
set -Eeuo pipefail

exec >> /var/log/provision.log 2>&1
echo "=== Provisioning started: $(date --iso-8601=seconds) ==="

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y upgrade

echo "=== Provisioning completed: $(date --iso-8601=seconds) ==="