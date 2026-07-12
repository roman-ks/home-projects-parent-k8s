set dotenv-load := true

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



create-leaf-cert:
    #!/usr/bin/env bash
    set -euo pipefail
    read -p "Enter service: " service
    sudo SERVICE="$service" \
        ROOT_CA_CRT="$ROOT_CA_CRT" \
        ROOT_CA_KEY="$ROOT_CA_KEY" \
        DOMAIN="$DOMAIN" \
        ./certs/create_leaf_certs.sh

add-tls-secret:
    #!/usr/bin/env bash
    set -euo pipefail
    read -p "Enter service: " service
    kubectl create secret tls "$service-tls" \
        --cert=certs/"$service".crt \
        --key=certs/"$service".key

