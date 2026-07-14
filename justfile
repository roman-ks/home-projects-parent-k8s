set dotenv-load := true

# k3s node bootstrap recipes live in bootstrap.just — run as `just bootstrap <recipe>`.
mod bootstrap

default:
    just --list


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

authentik:
    kubectl create namespace authentik --dry-run=client -o yaml | kubectl apply -f -
    helm dependency update charts/authentik-wrapper
    helm upgrade --install authentik ./charts/authentik-wrapper \
        --namespace authentik

authentik-secret:
    #!/usr/bin/env bash
    set -euo pipefail
    authentik_secret_key=$(openssl rand 60 | base64 -w 0)
    postgresql_user=authentik
    postgresql_password=$(openssl rand -base64 36 | tr -d '\n')
    kubectl create secret generic authentik-secret \
        --namespace authentik \
        --from-literal=AUTHENTIK_SECRET_KEY="$authentik_secret_key" \
        --from-literal=AUTHENTIK_POSTGRESQL__HOST=authentik-postgresql \
        --from-literal=AUTHENTIK_POSTGRESQL__USER="$postgresql_user" \
        --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="$postgresql_password" \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl create secret generic authentik-postgresql-secret \
        --namespace authentik \
        --from-literal=username="$postgresql_user" \
        --from-literal=password="$postgresql_password" \
        --dry-run=client -o yaml | kubectl apply -f -

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

