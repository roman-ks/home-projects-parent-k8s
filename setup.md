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