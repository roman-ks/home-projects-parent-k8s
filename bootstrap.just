# k3s node bootstrap — run in order; see bootstrap-recipes.md.
# Invoked as `just bootstrap <recipe>`. Recipes run with CWD at the repo root
# (this module file lives at the root), so paths like bootstrap/lib.sh resolve.

set dotenv-load := true

# Enable the memory cgroup in cmdline.txt and reboot the node.
cgroups:
    #!/usr/bin/env bash
    set -euo pipefail
    source bootstrap/lib.sh
    ssh-keygen -R "$SSH_TARGET"  # remove any old host key so we can connect after reboot
    echo "Enabling cgroups on $SSH_TARGET (node will reboot)..."
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'sudo bash -s' < bootstrap/cgroups.sh

# Install cryptsetup (needed to unlock the encrypted drive).
cryptsetup:
    #!/usr/bin/env bash
    set -euo pipefail
    source bootstrap/lib.sh
    echo "Installing cryptsetup on $SSH_TARGET..."
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'sudo apt-get update && sudo apt-get install -y cryptsetup'

# Unlock + mount the LUKS drive (interactive passphrase, never persisted; idempotent).
unlock:
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
k3s-config:
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
k3s:
    #!/usr/bin/env bash
    set -euo pipefail
    source bootstrap/lib.sh
    : "${K3S_VERSION:?k3s_version missing in bootstrap.yaml}"
    echo "Installing k3s $K3S_VERSION on $SSH_TARGET..."
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
        "sudo bash -s -- '$K3S_VERSION'" < bootstrap/k3s-install.sh

# Fetch the node's kubeconfig to ~/.kube/config, repointed at the node IP.
k3s-kubeconfig:
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

# Deploy the Traefik HelmChartConfig into k3s' auto-apply manifests dir.
traefik:
    #!/usr/bin/env bash
    set -euo pipefail
    source bootstrap/lib.sh
    src="k3s/server/manifests/traefik-config.yaml"
    dest="/var/lib/rancher/k3s/server/manifests/traefik-config.yaml"
    [ -f "$src" ] || { echo "ERROR: $src not found locally" >&2; exit 1; }
    echo "Deploying $src to $SSH_TARGET:$dest..."
    # k3s' helm-controller auto-applies anything dropped in server/manifests.
    # Pipe the file over one ssh session into place (no scp roundtrip).
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
        "sudo mkdir -p /var/lib/rancher/k3s/server/manifests && sudo tee '$dest' >/dev/null" < "$src"
    echo "Wrote $dest — k3s will reconcile the traefik HelmChartConfig shortly."
