#!/usr/bin/env bash
set -Eeuo pipefail

# Configuration
DEVICE="/dev/sda1"
MAPPER="cryptssd"
MOUNT="/mnt/drive1"

KEY="/etc/cryptsetup-keys.d/${MAPPER}.key"
CRYPTTAB="/etc/crypttab"
FSTAB="/etc/fstab"

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
[[ -b "$DEVICE" ]] || { echo "Invalid device: $DEVICE"; exit 1; }
cryptsetup isLuks "$DEVICE" || { echo "Not a LUKS device"; exit 1; }

install -d -m 0700 /etc/cryptsetup-keys.d
install -d "$MOUNT"

UUID="$(cryptsetup luksUUID "$DEVICE")"

# Generate and add keyfile.
if [[ -e "$KEY" ]]; then
    echo "Keyfile already exists: $KEY"
    exit 1
fi

TMP="$(mktemp /etc/cryptsetup-keys.d/.key.XXXXXX)"
trap 'rm -f "$TMP"' EXIT

chmod 0400 "$TMP"
dd if=/dev/urandom of="$TMP" bs=64 count=1 status=none

echo "Adding keyfile to LUKS. Enter an existing passphrase:"
cryptsetup luksAddKey "$DEVICE" "$TMP"

cryptsetup open --test-passphrase --key-file "$TMP" "$DEVICE"

install -o root -g root -m 0400 "$TMP" "$KEY"
rm -f "$TMP"
trap - EXIT

# Open the device temporarily if it isn't already open.
OPENED_HERE=0

cleanup() {
    if (( OPENED_HERE )); then
        cryptsetup close "$MAPPER" || true
    fi
}

trap cleanup EXIT

if ! cryptsetup status "$MAPPER" >/dev/null 2>&1; then
    cryptsetup open --key-file "$KEY" "$DEVICE" "$MAPPER"
    OPENED_HERE=1
fi

FS="$(blkid -s TYPE -o value "/dev/mapper/$MAPPER")"
[[ -n "$FS" ]] || {
    echo "Could not detect filesystem"
    exit 1
}

# Cleanup happens automatically on exit.

# Configure automatic unlocking.
sed -i "\|^${MAPPER}[[:space:]]|d" "$CRYPTTAB"
echo "$MAPPER UUID=$UUID $KEY luks,nofail" >> "$CRYPTTAB"

# Configure automatic mounting.
sed -i "\|^[^#].*[[:space:]]${MOUNT}[[:space:]]|d" "$FSTAB"
echo "/dev/mapper/$MAPPER $MOUNT $FS defaults,noatime,nofail,x-systemd.device-timeout=15s 0 2" >> "$FSTAB"

echo
echo "Provisioning complete:"
echo "  Device:  $DEVICE"
echo "  Mapper:  /dev/mapper/$MAPPER"
echo "  Keyfile: $KEY"
echo "  Mount:   $MOUNT ($FS)"
