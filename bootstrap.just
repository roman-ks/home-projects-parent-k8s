# k3s node bootstrap — run in order; see bootstrap-recipes.md.
# Invoked as `just bootstrap <recipe>`. Recipes run with CWD at the repo root
# (this module file lives at the root), so paths like bootstrap/lib.sh resolve.

set dotenv-load := true


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
