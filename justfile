set dotenv-load := true

default:
    just --list


# --- k3s node bootstrap (run in order; see bootstrap-recipes.md) ---

# Enable the memory cgroup in cmdline.txt and reboot the node.
bootstrap-cgroups:
    #!/usr/bin/env bash
    set -euo pipefail
    source bootstrap/lib.sh
    echo "Enabling cgroups on $SSH_TARGET (node will reboot)..."
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'sudo bash -s' < bootstrap/cgroups.sh

# Install cryptsetup (needed to unlock the encrypted drive).
bootstrap-cryptsetup:
    #!/usr/bin/env bash
    set -euo pipefail
    source bootstrap/lib.sh
    echo "Installing cryptsetup on $SSH_TARGET..."
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'sudo apt-get update && sudo apt-get install -y cryptsetup'

# Unlock + mount the LUKS drive (interactive passphrase, never persisted; idempotent).
bootstrap-unlock:
    #!/usr/bin/env bash
    set -euo pipefail
    source bootstrap/lib.sh
    : "${LUKS_DEVICE:?luks_device missing in bootstrap.yaml}"
    : "${LUKS_NAME:?luks_name missing in bootstrap.yaml}"
    : "${MOUNT_POINT:?mount_point missing in bootstrap.yaml}"
    echo "Unlocking $LUKS_DEVICE on $SSH_TARGET (you'll be prompted for the LUKS passphrase)..."
    # -t allocates a TTY so cryptsetup can prompt on your terminal. stdin is NOT
    # redirected, so the passphrase is typed live and never touches disk/history.
    ssh -t "${SSH_OPTS[@]}" "$SSH_TARGET" "
        set -e
        if sudo cryptsetup status $LUKS_NAME >/dev/null 2>&1; then
            echo 'already unlocked'
        else
            sudo cryptsetup luksOpen $LUKS_DEVICE $LUKS_NAME
        fi
        sudo mkdir -p $MOUNT_POINT
        if mountpoint -q $MOUNT_POINT; then
            echo 'already mounted'
        else
            sudo mount /dev/mapper/$LUKS_NAME $MOUNT_POINT
        fi
        echo \"drive ready at $MOUNT_POINT\"
    "

# Write k3s config.yaml, registries.yaml and the root CA to the node.
bootstrap-k3s-config:
    #!/usr/bin/env bash
    set -euo pipefail
    source bootstrap/lib.sh
    : "${PARENT:?parent missing in bootstrap.yaml}"
    : "${REGISTRY:?registry_cname missing in bootstrap.yaml}"
    : "${MOUNT_POINT:?mount_point missing in bootstrap.yaml}"
    : "${ROOTCA:?rootCA missing in bootstrap.yaml}"
    [ -f "$ROOTCA" ] || { echo "ERROR: local rootCA not found: $ROOTCA" >&2; exit 1; }
    rootca_b64=$(base64 -w0 "$ROOTCA")
    echo "Writing k3s config to $SSH_TARGET..."
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
        "sudo bash -s -- '$PARENT' '$REGISTRY' '$rootca_b64' '$MOUNT_POINT'" < bootstrap/k3s-config.sh

# Install pinned k3s and wait for the node to be ready.
bootstrap-k3s:
    #!/usr/bin/env bash
    set -euo pipefail
    source bootstrap/lib.sh
    : "${K3S_VERSION:?k3s_version missing in bootstrap.yaml}"
    echo "Installing k3s $K3S_VERSION on $SSH_TARGET..."
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
        "sudo bash -s -- '$K3S_VERSION'" < bootstrap/k3s-install.sh

# Fetch the node's kubeconfig to ~/.kube/config, repointed at the node IP.
bootstrap-k3s-kubeconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    source bootstrap/lib.sh
    dest="$HOME/.kube/config"
    mkdir -p "$HOME/.kube"
    echo "Fetching kubeconfig from $SSH_TARGET..."
    # k3s.yaml is root-only, so read it via `sudo cat` over the single ssh session
    # (scp can't elevate). Stream straight into a temp file next to the destination
    # and repoint the server URL — nothing sensitive lands in a shell variable.
    tmp=$(mktemp "$HOME/.kube/config.XXXXXX")   # mktemp is 0600
    trap 'rm -f "$tmp"' EXIT
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'sudo cat /etc/rancher/k3s/k3s.yaml' \
        | sed -E "s#(server: https://)[^:]+#\1${HOST}#" > "$tmp"
    # sanity-check we actually got a kubeconfig before touching the real one
    grep -q 'server: https://' "$tmp" || { echo "ERROR: fetched kubeconfig looks invalid" >&2; exit 1; }
    # back up any existing config (may hold other contexts), then swap in atomically
    if [ -f "$dest" ]; then
        backup="$dest.bak.$(date +%Y%m%d%H%M%S)"
        cp "$dest" "$backup"
        echo "Backed up existing kubeconfig -> $backup"
    fi
    mv "$tmp" "$dest"
    trap - EXIT
    echo "Wrote $dest (server -> https://${HOST}:6443)"
    echo "Verifying..."
    kubectl get pods -n kube-system



pihole:
    helm upgrade --install pihole ./charts/pihole \
        --namespace default \
        -f values/pihole.yaml


oci-registry:
    helm upgrade --install oci-registry ./charts/oci-registry \
        --namespace default \
        -f values/oci-registry.yaml

gram: 
    helm upgrade --install gram ./charts/gram \
        --namespace default \
        -f values/gram.yaml 



# Nothing is stored: key+cert live only in a temp dir wiped on exit. openssl runs
# as your user (so no root-owned files), and only the CA read is elevated via
# `sudo cat` through a process-substitution fd — the CA key never touches disk.
# Generate a CA-signed leaf cert and load it straight into a k8s TLS secret.
tls-secret:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${DOMAIN:?DOMAIN missing in .env}"
    : "${ROOT_CA_CRT:?ROOT_CA_CRT missing in .env}"
    : "${ROOT_CA_KEY:?ROOT_CA_KEY missing in .env}"
    read -p "Enter service: " service
    cname="${service}.${DOMAIN}"
    sudo -v   # prime sudo so the CA reads below don't prompt mid-command
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    # leaf key + CSR, generated as the user (nothing root-owned)
    openssl genrsa -out "$tmp/tls.key" 2048
    openssl req -new -key "$tmp/tls.key" -subj "/CN=${cname}" -out "$tmp/tls.csr"
    { cat certs/leaf-base.ext; echo "subjectAltName=DNS:${cname}"; } > "$tmp/tls.ext"
    # sign with the root CA; CA cert+key streamed via sudo, never written to disk
    openssl x509 -req \
        -in "$tmp/tls.csr" \
        -CA <(sudo cat "$ROOT_CA_CRT") \
        -CAkey <(sudo cat "$ROOT_CA_KEY") \
        -CAserial "$tmp/ca.srl" -CAcreateserial \
        -out "$tmp/tls.crt" \
        -days 825 -sha256 -extfile "$tmp/tls.ext"
    # create-or-update, so re-running just rotates the cert
    kubectl create secret tls "${service}-tls" \
        --cert="$tmp/tls.crt" --key="$tmp/tls.key" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "Applied secret ${service}-tls (cert for ${cname}); temp files wiped."

