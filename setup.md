# Set up k3s
## On PI
### Enable cgroup
1. edit cmdline
```bash
sudo nano /boot/firmware/cmdline.txt
```

2, add `cgroup_memory=1 cgroup_enable=memory` in the end
3. reboot

### Install k3s
1. Run
```bash
curl -sfL https://get.k3s.io | sh -
```

2. verify installation
```bash
sudo kubeclt get pods
```

## On laptop
<!-- todo format and add exact steps -->
copy k3s.yaml from /etc/rancher/k3s/k3s.yaml on pi to as ~/.kube/config

intall helm
sudo snap install helm --classic



### Create pihole secret
```
kubectl create secret tls pihole-tls --cert=pihole.crt --key=pihole.key
```

### Setup oci image build env
```bash
sudo apt install buildah
# needed to run arm64 builds on amd64 laptop
sudo apt install qemu-user-binfmt
```

### Setup age+sops

#### Build age-plugin-yubikey
```shell
sudo apt install cargo libpcsclite-dev pcscd
cargo install age-plugin-yubikey
echo 'export PATH="$PATH:$HOME/.cargo/bin"' >> ~/.bashrc
source ~/.bashrc
```

#### Generate age identity(if not present)
Note it wont be able to decrypt old secrets.
```bash
age-plugin-yubikey --generate
```

#### Recover age identity from yubikey
```shell
age-plugin-yubikey --list
mkdir -p ~/.config/sops/age
age-plugin-yubikey --identity > ~/.config/sops/age/keys.txt
```

```bash
# age
sudo apt install age
sudo apt-get install libpcsclite-dev

#sops
# Download the binary
curl -LO https://github.com/getsops/sops/releases/download/v3.13.2/sops-v3.13.2.linux.amd64

# Move the binary in to your PATH
mv sops-v3.13.2.linux.amd64 /usr/local/bin/sops

# Make the binary executable
chmod +x /usr/local/bin/sops
```

#### Encrypt values file
```bash
sops --encrypt --in-place values/authentik.enc.yaml
```