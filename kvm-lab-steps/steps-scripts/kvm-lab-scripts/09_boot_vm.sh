#!/usr/bin/env bash
# 09 - Boot a VM with virt-install and log in                guide: Step 10
# Usage: ./09_boot_vm.sh [vm-name] [ram-MB] [cpus] [network]  (default lab-web1 2048 2 lab-nat)
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env
VM=${1:-lab-web1}; RAM=${2:-2048}; CPUS=${3:-2}; NET=${4:-$LAB_NET}
if [ ! -f "$LAB_HOME/vms/$VM/user-data" ]; then echo "Run ./07_create_disk.sh and ./08_cloud_init.sh for $VM first"; exit 1; fi
# shellcheck source=/dev/null
source "$LAB_HOME/vms/$VM/vm.env"                  # gives OS_VARIANT

echo "== Create and boot $VM ($RAM MB, $CPUS vCPU, network $NET)"
if virsh dominfo "$VM" >/dev/null 2>&1; then
  echo "already defined"
  virsh start "$VM" 2>/dev/null || true
else
  # sudo: so virt-install can write the cloud-init disk into libvirt's own directory.
  # sudo drops LIBVIRT_DEFAULT_URI, so --connect is given explicitly.
  sudo virt-install --connect qemu:///system \
    --name "$VM" --memory "$RAM" --vcpus "$CPUS" --cpu host-passthrough \
    --osinfo "$OS_VARIANT" --import \
    --disk "path=$LAB_POOL_DIR/$VM.qcow2,format=qcow2,bus=virtio" \
    --network "network=$NET,model=virtio" \
    --graphics none --console pty,target_type=serial \
    --cloud-init "user-data=$LAB_HOME/vms/$VM/user-data,meta-data=$LAB_HOME/vms/$VM/meta-data" \
    --noautoconsole
fi
virsh list --all

echo "== Wait for an IP (up to 5 min)"
IP=$(wait_ip "$VM") || { echo "No IP yet. Watch the boot with: virsh console $VM   (login lab / lab, leave with Ctrl+])"; exit 1; }
echo "$VM has IP $IP"

echo "== Wait for SSH, then look inside"
for _ in $(seq 1 30); do
  if labssh -o ConnectTimeout=5 "$LAB_USER@$IP" true 2>/dev/null; then break; fi
  sleep 5
done
labssh "$LAB_USER@$IP" 'cloud-init status --wait || true; hostnamectl | grep -E "hostname|Virtualization"; nproc; free -h | head -n 2; lsblk -d; ip -br addr'

echo
echo "Log in:   source ./lab.env && labssh $LAB_USER@$IP"
echo "Console:  virsh console $VM     (lab / lab, leave with Ctrl+])"
echo "Undo:     virsh destroy $VM; virsh undefine $VM --remove-all-storage"
