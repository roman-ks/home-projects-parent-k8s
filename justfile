set dotenv-load := true

# k3s node bootstrap recipes live in bootstrap.just — run as `just bootstrap <recipe>`.
mod bootstrap

default:
    just --list


core:
    helm upgrade --install core ./charts/core \
        --namespace kube-system

# Install cert-manager (CRDs + controllers). Run before `pki`.
cert-manager:
    helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
        --version v1.21.0 \
        --namespace cert-manager --create-namespace \
        --set crds.enabled=true

# Deploy the internal CA ClusterIssuer (cert-manager must be installed).
# The issuer is not Ready until the intermediate secret exists — run `pki-secret`.
pki:
    helm upgrade --install pki ./charts/pki \
        --namespace cert-manager

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

memos:
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl create namespace memos --dry-run=client -o yaml | kubectl apply -f -
    helm upgrade --install memos ./charts/memos \
        --namespace memos \
        -f values/memos.yaml

samba:
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl create namespace samba --dry-run=client -o yaml | kubectl apply -f -
    helm upgrade --install samba ./charts/samba --namespace samba

# Apply the SMB account passwords from the sops-encrypted manifest (RAM-backed
# decrypt; YubiKey). Run once / when a password changes.
samba-secret:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp=$(mktemp -d "${XDG_RUNTIME_DIR:-/dev/shm}/samba.XXXXXX")
    trap 'rm -rf "$tmp"; stty sane 2>/dev/null || true' EXIT
    kubectl create namespace samba --dry-run=client -o yaml | kubectl apply -f -
    cp values/samba.enc.yaml "$tmp/samba.yaml"
    echo ">>> Decrypting samba-accounts — enter PIN, then tap the YubiKey when it flashes..."
    sops -d -i "$tmp/samba.yaml"
    kubectl apply -f "$tmp/samba.yaml"

# Deploy Immich (community chart, ML off) + its postgres. The config carries the
# OIDC client secret + DB password, so it's sops-decrypted in memory each deploy
# (YubiKey). OIDC creds must match values/immich.enc.yaml.
immich:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp=$(mktemp -d "${XDG_RUNTIME_DIR:-/dev/shm}/immich.XXXXXX")
    trap 'rm -rf "$tmp"; stty sane 2>/dev/null || true' EXIT
    kubectl create namespace immich --dry-run=client -o yaml | kubectl apply -f -
    helm dependency build charts/immich-wrapper
    cp values/immich-config.enc.yaml "$tmp/immich-config.yaml"
    echo ">>> Decrypting immich config — enter PIN, then tap the YubiKey when it flashes..."
    sops -d -i "$tmp/immich-config.yaml"
    helm upgrade --install immich ./charts/immich-wrapper \
        --namespace immich \
        -f "$tmp/immich-config.yaml"

kopia:
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl create namespace kopia --dry-run=client -o yaml | kubectl apply -f -
    helm upgrade --install kopia ./charts/kopia \
        --namespace kopia \
        -f values/kopia.yaml

# Apply the kopia S3 creds + repo password from the sops-encrypted manifest
# (RAM-backed decrypt; YubiKey). For an EXISTING repo, KOPIA_PASSWORD must be the
# original repo password. Run once / when a credential changes.
kopia-secret:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp=$(mktemp -d "${XDG_RUNTIME_DIR:-/dev/shm}/kopia.XXXXXX")
    trap 'rm -rf "$tmp"; stty sane 2>/dev/null || true' EXIT
    kubectl create namespace kopia --dry-run=client -o yaml | kubectl apply -f -
    cp values/kopia.enc.yaml "$tmp/kopia.yaml"
    echo ">>> Decrypting kopia-secrets — enter PIN, then tap the YubiKey when it flashes..."
    sops -d -i "$tmp/kopia.yaml"
    kubectl apply -f "$tmp/kopia.yaml"

authentik:
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl create namespace authentik --dry-run=client -o yaml | kubectl apply -f -
    helm dependency update charts/authentik-wrapper
    helm upgrade --install authentik ./charts/authentik-wrapper \
        --namespace authentik


# Apply the authentik secrets (core config + db creds + OIDC provider client
# creds) as a separate, secrets-only release. Values are sops-decrypted in
# memory (never written to disk). Requires the YubiKey — run only when a secret
# changes, not on every `just authentik` deploy.
authentik-secret:
    #!/usr/bin/env bash
    set -euo pipefail
    # RAM-backed, user-private tmpdir; shredded on exit. Nothing hits disk.
    tmp=$(mktemp -d "${XDG_RUNTIME_DIR:-/dev/shm}/authentik-secrets.XXXXXX")
    trap 'rm -rf "$tmp"; stty sane 2>/dev/null || true' EXIT
    kubectl create namespace authentik --dry-run=client -o yaml | kubectl apply -f -
    # Decrypt each file in place, one at a time. `sops -d -i` leaves sops's stdout
    # on the terminal (unlike `$(sops -d)` / `<(sops -d)`, which pipe it) so the
    # YubiKey PIN + touch prompts behave exactly like a manual `sops -d`.
    files=(authentik immich memos)
    i=0
    for f in "${files[@]}"; do
        i=$((i + 1))
        cp "values/$f.enc.yaml" "$tmp/$f.yaml"
        echo ">>> [$i/${#files[@]}] Decrypting $f.enc.yaml — enter PIN, then tap the YubiKey when it flashes..."
        sops -d -i "$tmp/$f.yaml"
    done
    helm upgrade --install authentik-secrets ./charts/authentik-secrets \
        --namespace authentik \
        -f "$tmp/authentik.yaml" \
        -f "$tmp/immich.yaml" \
        -f "$tmp/memos.yaml"

# Nothing is stored: key+cert live only in a temp dir wiped on exit. openssl runs
# as your user (so no root-owned files), and only the CA read is elevated via
# `sudo cat` through a process-substitution fd — the CA key never touches disk.
# Generate a CA-signed leaf cert and load it into a k8s TLS secret.
# Optional namespace arg (empty -> "default"): `just tls-secret kube-system`.
tls-secret namespace='':
    #!/usr/bin/env bash
    set -euo pipefail
    : "${DOMAIN:?DOMAIN missing in .env}"
    : "${ROOT_CA_CRT:?ROOT_CA_CRT missing in .env}"
    : "${ROOT_CA_KEY:?ROOT_CA_KEY missing in .env}"
    ns='{{namespace}}'; ns="${ns:-default}"   # empty -> default namespace
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
        --namespace "$ns" \
        --cert="$tmp/tls.crt" --key="$tmp/tls.key" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "Applied secret ${service}-tls in namespace '$ns' (cert for ${cname}); temp files wiped."

