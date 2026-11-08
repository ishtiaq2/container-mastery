#!/usr/bin/env bash
# 08 - Lab SSH key and cloud-init files for a VM             guide: Step 9
# Usage: ./08_cloud_init.sh [vm-name]                         (default lab-web1)
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env
VM=${1:-lab-web1}
D="$LAB_HOME/vms/$VM"
mkdir -p "$LAB_HOME/ssh" "$D"

echo "== Lab-only SSH key (your ~/.ssh is not touched)"
if [ ! -f "$LAB_SSH_KEY" ]; then ssh-keygen -q -t ed25519 -N '' -C kvm-lab -f "$LAB_SSH_KEY"; fi
ls -l "$LAB_HOME/ssh"

echo "== user-data and meta-data in $D"
cat > "$D/user-data" <<EOF
#cloud-config
hostname: $VM
users:
  - name: $LAB_USER
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
      - $(cat "$LAB_SSH_KEY.pub")
chpasswd:
  expire: false
  users:
    - {name: $LAB_USER, password: lab, type: text}
ssh_pwauth: false
package_update: true
packages: [qemu-guest-agent]
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
EOF
printf 'instance-id: %s\nlocal-hostname: %s\n' "$VM" "$VM" > "$D/meta-data"

echo "== Check. Expected: #cloud-config first, your key present, YAML OK"
cat "$D/user-data" "$D/meta-data"
python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1])); print("YAML OK")' "$D/user-data" || echo "(could not check YAML: python3-yaml missing?)"

echo "Undo: rm -rf $D"
