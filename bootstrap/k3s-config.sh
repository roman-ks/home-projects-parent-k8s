#!/usr/bin/env bash
# Runs on the node as root (piped via `sudo bash -s -- <parent> <registry> <rootCA-b64>`).
# Writes k3s config.yaml, registries.yaml and the root CA before install.
set -euo pipefail

PARENT="${1:?parent path arg missing}"
REGISTRY="${2:?registry cname arg missing}"
ROOTCA_B64="${3:?rootCA base64 arg missing}"
MOUNT_POINT="${4:?mount point arg missing}"

# Normalise trailing slash so "${PARENT}encryption-config.json" is always valid.
[ "${PARENT: -1}" = "/" ] || PARENT="${PARENT}/"
MOUNT_POINT="${MOUNT_POINT%/}"

# Prereq: verify the encrypted drive is actually MOUNTED before touching $PARENT.
# We check the mountpoint itself (not just whether $PARENT exists), so we never
# silently create the dir tree on the unencrypted root fs when the drive is locked.
mountpoint -q "$MOUNT_POINT" || { echo "ERROR: $MOUNT_POINT is not mounted — run bootstrap-unlock first" >&2; exit 1; }
# $PARENT must live under the mounted drive, else creating it would miss the encryption.
case "$PARENT" in
  "$MOUNT_POINT"/*) ;;
  *) echo "ERROR: parent ($PARENT) is not under mount_point ($MOUNT_POINT)" >&2; exit 1 ;;
esac
# Safe now: the drive is mounted, so this lands on the encrypted fs.
mkdir -p "$PARENT"

# Generate the secrets-encryption config on the node if absent. NEVER overwrite:
# replacing this key would make already-encrypted secrets undecryptable.
ENC_FILE="${PARENT}encryption-config.json"
if [ -f "$ENC_FILE" ]; then
  echo "encryption-config.json already present, keeping it"
else
  secret=$(head -c 32 /dev/urandom | base64)
  ( umask 077; cat > "$ENC_FILE" <<EOF
{
  "kind": "EncryptionConfiguration",
  "apiVersion": "apiserver.config.k8s.io/v1",
  "resources": [
    {
      "resources": [
        "secrets"
      ],
      "providers": [
        {
          "aescbc": {
            "keys": [
              {
                "name": "aescbckey",
                "secret": "$secret"
              }
            ]
          }
        },
        {
          "identity": {}
        }
      ]
    }
  ]
}
EOF
  )
  echo "generated $ENC_FILE"
fi

install -d -m 0700 /etc/rancher/k3s/certs

cat > /etc/rancher/k3s/config.yaml <<EOF
secrets-encryption: true
kube-apiserver-arg:
  - "encryption-provider-config=${PARENT}encryption-config.json"
EOF

cat > /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  "${REGISTRY}":
    endpoint:
      - "https://${REGISTRY}"
configs:
  "${REGISTRY}":
    tls:
      ca_file: /etc/rancher/k3s/certs/rootCA.crt
EOF

printf '%s' "$ROOTCA_B64" | base64 -d > /etc/rancher/k3s/certs/rootCA.crt

echo "Wrote /etc/rancher/k3s/{config.yaml,registries.yaml,certs/rootCA.crt}"
