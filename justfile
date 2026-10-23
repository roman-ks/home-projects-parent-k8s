set dotenv-load := true

# k3s node bootstrap recipes live in bootstrap.just — run as `just bootstrap <recipe>`.
mod bootstrap

default:
    just --list


core:
    helm upgrade --install core ./charts/core \
        --namespace kube-system

# Scale a target's UI server up (default 1) or down (0). Scale down when done —
# a running server polls S3 (billed).
#   just kopia-ui immich      # up
#   just kopia-ui immich 0    # down
kopia-ui name replicas='1':
    kubectl -n kopia scale deploy/kopia-{{name}}-server --replicas={{replicas}}

_k8s-secret secret-path ns:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp=$(mktemp -d "${XDG_RUNTIME_DIR:-/dev/shm}/XXXXXXXXX")
    tmp_file="$tmp/tmp.yaml"
    trap 'rm -rf "$tmp"; stty sane 2>/dev/null || true' EXIT
    kubectl create namespace {{ns}} --dry-run=client -o yaml | kubectl apply -f -
    cp {{secret-path}} "$tmp_file"
    echo ">>> Decrypting {{secret-path}} — enter PIN, then tap the YubiKey when it flashes..."
    sops -d -i "$tmp_file"
    kubectl apply -n {{ns}} -f "$tmp_file"

argocd-secrets: (_k8s-secret "values/argocd-age.enc.yaml" "argocd") (_k8s-secret "values/argocd-repo.enc.yaml" "argocd") 

argocd:
    #!/usr/bin/env bash
    set -euo pipefail

    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
        #!/usr/bin/env bash
    NAMESPACE="argocd"

    tmp=$(mktemp -d "${XDG_RUNTIME_DIR:-/dev/shm}/argocd.XXXXXX")
    trap 'rm -rf "$tmp"; stty sane 2>/dev/null || true' EXIT
    cp values/argocd-secret.enc.yaml "$tmp/argocd-secret.yaml"
    echo ">>> Decrypting argocd config — enter PIN, then tap the YubiKey when it flashes..."
    sops -d -i "$tmp/argocd-secret.yaml"

    helm upgrade --install "argocd" \
        --namespace "${NAMESPACE}" \
        --create-namespace \
        argo/argo-cd -f values/argocd.yaml \
        -f "$tmp/argocd-secret.yaml"
    
    kubectl apply -f values/argocd-root-app.yaml