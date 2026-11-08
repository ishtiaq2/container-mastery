#!/usr/bin/env bash
# 07 - Create a VM's overlay disk                            guide: Step 8
# Usage: ./07_create_disk.sh [vm-name] [image] [disk-GB]     (default lab-web1 ubuntu24 20)
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env
VM=${1:-lab-web1}; IMAGE=${2:-ubuntu24}; DISK=${3:-20}

case "$VM" in lab-*) ;; *) echo "VM names must start with lab- (cleanup relies on it)"; exit 1 ;; esac
if [ ! -f "$LAB_HOME/state/image-$IMAGE.env" ]; then echo "Run ./06_download_image.sh $IMAGE first"; exit 1; fi
# shellcheck source=/dev/null
source "$LAB_HOME/state/image-$IMAGE.env"          # gives IMG_FILE and OS_VARIANT

mkdir -p "$LAB_HOME/vms/$VM"
printf 'IMG_FILE=%s\nOS_VARIANT=%s\n' "$IMG_FILE" "$OS_VARIANT" > "$LAB_HOME/vms/$VM/vm.env"

echo "== Overlay $VM.qcow2 (${DISK}G) on top of $IMG_FILE"
if sudo test -f "$LAB_POOL_DIR/$VM.qcow2"; then
  echo "already exists"
else
  sudo qemu-img create -f qcow2 -F qcow2 -b "$LAB_BASE_DIR/$IMG_FILE" "$LAB_POOL_DIR/$VM.qcow2" "${DISK}G"
fi

echo "== Check. Expected: virtual size ${DISK} GiB, disk size ~200 KiB, backing file = the base image"
sudo qemu-img info --backing-chain "$LAB_POOL_DIR/$VM.qcow2" | grep -E '^(image|virtual size|disk size|backing file)'
virsh pool-refresh "$LAB_POOL" >/dev/null
virsh vol-list "$LAB_POOL"

echo "Undo: sudo rm $LAB_POOL_DIR/$VM.qcow2"
