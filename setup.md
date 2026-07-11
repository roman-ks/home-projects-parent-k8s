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



