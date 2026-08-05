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

# Create the PV dir + the static local-volume subdirs on the encrypted drive
# (run `unlock` first). encrypted-local-path (dynamic) provisions under $dir/;
# the `local` PVs (samba, immich) need their subdirs to pre-exist.
pv-dir:
    #!/usr/bin/env bash
    set -euo pipefail
    source bootstrap/lib.sh
    : "${MOUNT_POINT:?mount_point missing in bootstrap.yaml}"
    dir="${MOUNT_POINT%/}/pv"
    # Subdirs backing the static local-volume PVs (immich-external is shared by
    # the samba imuser share and immich's external library).
    subdirs="samba-user immich-external immich-upload immich-postgres"
    echo "Creating $dir + local-volume subdirs on $SSH_TARGET..."
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "
        set -e
        mountpoint -q '$MOUNT_POINT' || { echo 'ERROR: $MOUNT_POINT is not mounted — run: just bootstrap unlock' >&2; exit 1; }
        sudo mkdir -p '$dir'
        for s in $subdirs; do sudo mkdir -p \"$dir/\$s\"; done
        echo 'PV dirs:'; ls -ld '$dir' \"$dir\"/*/
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

# Sync k3s' auto-apply manifests (traefik HelmChartConfig + the authentik
# forwardAuth Middleware) into the node's server/manifests dir. k3s reconciles
# them automatically. Add a *.yaml under k3s/server/manifests/ and re-run.
traefik:
    #!/usr/bin/env bash
    set -euo pipefail
    source bootstrap/lib.sh
    srcdir="k3s/server/manifests"
    destdir="/var/lib/rancher/k3s/server/manifests"
    ls "$srcdir"/*.yaml >/dev/null 2>&1 || { echo "ERROR: no manifests in $srcdir" >&2; exit 1; }
    echo "Syncing $srcdir/*.yaml -> $SSH_TARGET:$destdir ..."
    # One ssh session: stream a tar of the manifests dir and extract it as root.
    tar -C "$srcdir" -cf - . | ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
        "sudo mkdir -p '$destdir' && sudo tar -C '$destdir' -xf -"
    echo "Synced $(ls "$srcdir"/*.yaml | wc -l) manifest(s) — k3s will reconcile shortly."

# Generate an intermediate CA (signed by the offline root) and load it into
# cert-manager as the `intermediate-ca` secret, so the `internal-ca` ClusterIssuer
# can sign leaf certs. LOCAL openssl + kubectl (no ssh) — for testing cert-manager.
# Run after `just cert-manager`. The root key is streamed via sudo, never on disk.
intermediate-ca:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${ROOT_CA_CRT:?ROOT_CA_CRT missing in .env}"
    : "${ROOT_CA_KEY:?ROOT_CA_KEY missing in .env}"
    : "${DOMAIN:?DOMAIN missing in .env}"
    [ -f "$ROOT_CA_CRT" ] || { echo "ERROR: root CA cert not found: $ROOT_CA_CRT" >&2; exit 1; }
    sudo -v   # prime sudo so the CA-key read below doesn't prompt mid-command
    tmp=$(mktemp -d "${XDG_RUNTIME_DIR:-/dev/shm}/int-cert.XXXXXX")
    trap 'rm -rf "$tmp"; stty sane 2>/dev/null || true' EXIT
    trap 'rm -rf "$tmp"' EXIT
    # intermediate key + CSR (generated as your user; nothing root-owned)
    openssl genrsa -out "$tmp/int.key" 4096
    openssl req -new -key "$tmp/int.key" -subj "/CN=${DOMAIN} intermediate CA" -out "$tmp/int.csr"
    # CA extensions — this cert may sign leaves; pathlen:0 forbids further sub-CAs.
    printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,digitalSignature,cRLSign,keyCertSign\n' > "$tmp/int.ext"
    # sign with the root CA; cert+key streamed via sudo, never written to disk
    openssl x509 -req \
        -in "$tmp/int.csr" \
        -CA <(sudo cat "$ROOT_CA_CRT") \
        -CAkey <(sudo cat "$ROOT_CA_KEY") \
        -CAserial "$tmp/ca.srl" -CAcreateserial \
        -out "$tmp/int.crt" \
        -days 1825 -sha256 -extfile "$tmp/int.ext"
    # chain served to clients = intermediate + root
    cat "$tmp/int.crt" <(sudo cat "$ROOT_CA_CRT") > "$tmp/int.chain.crt"
    # load into cert-manager as the CA issuer's signing secret
    kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret tls intermediate-ca \
        --namespace cert-manager \
        --cert="$tmp/int.chain.crt" --key="$tmp/int.key" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "Loaded intermediate-ca secret into cert-manager (chain: intermediate + root); temp files wiped."
