#!/usr/bin/env bash
# 12 - Another distribution with the same steps 06-09        guide: Step 13
# Usage: ./12_other_os.sh [image] [vm-name]                  (default centos9 lab-db1)
#        images: centos9 alma9 rocky9 debian12 ubuntu22
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env
IMAGE=${1:-centos9}; VM=${2:-lab-db1}

./06_download_image.sh "$IMAGE"
./07_create_disk.sh "$VM" "$IMAGE" 20
./08_cloud_init.sh "$VM"
./09_boot_vm.sh "$VM" 2048 2

echo "== Check. Expected: the new distribution's name; SELinux 'Enforcing' on CentOS/Alma/Rocky"
labssh "$LAB_USER@$(vm_ip "$VM")" 'grep PRETTY_NAME /etc/os-release; getenforce 2>/dev/null || echo "no SELinux"'
virsh list --all
echo "Undo: virsh destroy $VM; virsh undefine $VM --remove-all-storage; rm -rf $LAB_HOME/vms/$VM"
