#!/bin/bash

function errexit() {
    echo -e "$1"
    exit 1
}

img="$1"
[ "$img" == "" ] && errexit "? No IMG specified"

root_ca_crt="$2"
[ "$root_ca_crt" == "" ] && errexit "? No Root CA cert"


[ "$(type -p sdm)" == "" ] && errexit "? sdm is not installed"

# Create a fresh working copy
work_img="${img%.img}-custom.img"
cp --reflink=auto --sparse=always "$img" "$work_img"

assets="."
rm -f $assets/my.plugins.1
[ -f $assets/my.plugins ] && mv $assets/my.plugins $assets/my.plugins.1

(cat <<EOF
# Plugin List generated $(date +"%Y-%m-%d %H:%M:%S")
EOF
    ) | bash -c "cat >|$assets/my.plugins"

(cat <<EOF

# Create the regular user first
user:deluser=pi
user:adduser=user|prompt

# Install the user's SSH public key for normal OS logins
sshkey:sshuser=user|import-pubkey=/home/roman/.ssh/authorized_keys

# Disable first-boot setup; configure localization from the host
disables:piwiz|cloudinit
L10n:keymap=us|locale=en_US.UTF-8|timezone=Europe/Kyiv

# Kernel command line
cmdline:add=cgroup_memory=1 cgroup_enable=memory

# Copy provision script
copyfile:"from=$assets/provision.sh|to=/usr/local/sbin/"

# Create directory needed by defer-plugin
mkdir:dir=/etc/sdm/assets/defer-plugin

# Create directory for k3s configs
copydir:"from=$assets/var/|to=/var"
mkdir:dir=/etc/rancher/k3s/
copyfile:"from=$assets/etc/rancher/k3s/registries.yaml|to=/etc/rancher/k3s/"
mkdir:"dir=/etc/rancher/k3s/certs"
copyfile:"from=$root_ca_crt|to=/etc/rancher/k3s/certs/"

# Copy SSD unlock config script
copyfile:"from=$assets/provision-ssd-unlock.sh|to=/usr/local/sbin/"

mkdir:dir=/etc/systemd/journald.conf.d/
copydir:"from=$assets/etc/systemd/|to=/etc/systemd"

 
EOF
    ) | bash -c "cat >>$assets/my.plugins"

sdm --customize \
    --batch \
    --plugin @$assets/my.plugins \
    --poptions noupgrade \
    --extend \
    --xmb 2048 \
    --restart \
    --logwidth 256 "$work_img"

echo $"
Use sdm to burn the disk and create SSH Host Keys:
sdm --ddsw "bs=16M" --burn /dev/sdX --hostname raspberrypi \"$work_img\" --expand-root \\
    --plugin sshhostkey:generate-keys \\
    --plugin defer-plugin:\"defer-command:/usr/local/sbin/provision.sh\"

Once in Dropbear use:
sdmcryptfs /dev/mmcblk0 RAM
"
