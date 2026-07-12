#!/bin/bash
set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# Default: do not overwrite existing cert/key pairs. Pass -f or --overwrite to force
OVERWRITE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--overwrite)
      OVERWRITE=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--overwrite|-f]"
      echo "  By default existing cert/key pairs in ./certs are preserved. Use --overwrite to recreate."
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--overwrite|-f]"
      exit 1
      ;;
  esac
done


create_leaf_cert(){
    local service="$1"
    local cname="$2"
    local keyfile="certs/${service}.key"
    local crtfile="certs/${service}.crt"

    if [[ -f "$keyfile" && -f "$crtfile" && $OVERWRITE -ne 1 ]]; then
        echo "Skipping $cname: $keyfile and $crtfile already exist (use --overwrite to recreate)"
        return
    fi

    echo "--- Creating certificate for $cname ---"

    if [[ $OVERWRITE -eq 1 ]]; then
        sudo rm -f "$keyfile" "$crtfile" || true
    fi

    sudo openssl genrsa -out "$keyfile" 2048
    echo "Created key for $cname"

    sudo openssl req -new \
        -key "$keyfile" \
        -subj "/CN=${cname}" \
        -out tmp.csr
    echo "Created CSR for $cname"

    { cat "${SCRIPT_DIR}/leaf-base.ext"; echo "subjectAltName=DNS:${cname}"; } > tmp.ext
    sudo openssl x509 -req \
        -in tmp.csr \
        -CA "${ROOT_CA_CRT}" \
        -CAkey "${ROOT_CA_KEY}" \
        -CAcreateserial \
        -out "$crtfile" \
        -days 825 \
        -sha256 \
        -extfile tmp.ext
    echo "Created certificate. Cleaning up..."
    sudo rm tmp.csr tmp.ext
}

mkdir -p certs/

create_leaf_cert "$SERVICE"    "${SERVICE}.${DOMAIN}"

