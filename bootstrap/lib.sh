#!/usr/bin/env bash
# Shared setup for the bootstrap-* recipes: reads bootstrap.yaml and exposes
# the ssh target + config values. Sourced from each recipe body.
#
# bootstrap.yaml is intentionally flat ("key: value") so we can parse it with
# grep/sed and avoid depending on a specific yq flavor.

BOOTSTRAP_YAML="${BOOTSTRAP_YAML:-bootstrap.yaml}"
[ -f "$BOOTSTRAP_YAML" ] || { echo "ERROR: $BOOTSTRAP_YAML not found" >&2; exit 1; }

yaml_get() {
  # $1 = top-level key. Strips the "key:" prefix, an optional trailing
  # "# comment", surrounding whitespace, and one layer of quotes.
  grep -E "^$1:" "$BOOTSTRAP_YAML" \
    | sed -E "s/^$1:[[:space:]]*//; s/[[:space:]]+#.*\$//; s/[[:space:]]+\$//; s/^[\"']//; s/[\"']\$//"
}

HOST=$(yaml_get host)
USER_REMOTE=$(yaml_get user)
PARENT=$(yaml_get parent)
REGISTRY=$(yaml_get registry_cname)
K3S_VERSION=$(yaml_get k3s_version)
ROOTCA=$(yaml_get rootCA)
LUKS_DEVICE=$(yaml_get luks_device)
LUKS_NAME=$(yaml_get luks_name)
MOUNT_POINT=$(yaml_get mount_point)

: "${HOST:?host missing in $BOOTSTRAP_YAML}"
: "${USER_REMOTE:?user missing in $BOOTSTRAP_YAML}"

SSH_TARGET="$USER_REMOTE@$HOST"
# accept-new: don't prompt on first connect to a clean node; still protects
# against a changed key later. ConnectTimeout keeps a dead host from hanging.
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
