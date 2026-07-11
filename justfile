default:
    just --list



pihole:
    helm upgrade --install pihole ./charts/pihole \
        --namespace default \
        -f values/pihole.yaml

