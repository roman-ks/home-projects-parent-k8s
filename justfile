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

