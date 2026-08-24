# Homelab GitOps infra + extras

GitOps setup for deploying applications to a K3s homelab.

The goal is to have the application deployment process require as little
manual intervention as possible, with Git as the source of truth.

## Stack

- K3s
- Argo CD
- Kustomize
- GitHub Actions
- Self-hosted GitHub Actions runner running in Kubernetes
- Private container registry
- Helm

## Repository structure

```text
k3s/ - k3s configs used for bootstrap
charts/ - charts and chart wrappers
values/ - values for charts. *.enc.yaml contain SOPS encrypted vals
```

## Argo CD

Argo CD itself is deployed to the cluster using Kustomize.

Application manifests are managed separately from the application source
and are used by Argo CD as the desired state.

## CI

The GitHub Actions runner is deployed inside the K3s cluster using ARC and Runner Helm charts.

Relevant charts:
- charts/gha-runner-set - wrapper around the official chart, including trust configuration for the internal OCI registry CA
- official gha-runner-scale-set-controller chart


## Deployment

All infra bootstrapping happens with `just` recipes.
1. `bootstrap.just` - used to bootstrap k3s and base resources
2. `justfile` - contains recipes for all other deployments including GHA runners and Argo CD

Some recipes require SOPS decryption and therefore a YubiKey. See [setup.md](setup.md) for local PC setup.
