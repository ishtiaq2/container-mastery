#!/usr/bin/env bash
# 06 - Download and verify a cloud image                     guide: Step 7
# Usage: ./06_download_image.sh [ubuntu24|ubuntu22|debian12|centos9|alma9|rocky9]   (default ubuntu24)
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env
NAME=${1:-ubuntu24}

case "$NAME" in
  ubuntu24) IMG_URL=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img; OS_VARIANT=ubuntu24.04 ;;
  ubuntu22) IMG_URL=https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img; OS_VARIANT=ubuntu22.04 ;;
  debian12) IMG_URL=https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2; OS_VARIANT=debian12 ;;
  centos9)  IMG_URL=https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2; OS_VARIANT=centos-stream9 ;;
  alma9)    IMG_URL=https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2; OS_VARIANT=almalinux9 ;;
  rocky9)   IMG_URL=https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2; OS_VARIANT=rocky9 ;;
  *) echo "Unknown image '$NAME'"; exit 1 ;;
esac
IMG_FILE="${IMG_URL##*/}"

echo "== Does virt-install know $OS_VARIANT? (if not: linux2022, else let virt-install guess)"
OS_LIST=$(virt-install --osinfo list)
if ! echo "$OS_LIST" | grep -qw "$OS_VARIANT"; then
  if echo "$OS_LIST" | grep -qw linux2022; then OS_VARIANT=linux2022; else OS_VARIANT="detect=on,require=off"; fi
fi
echo "using: $OS_VARIANT"

echo "== Download $IMG_FILE"
if sudo test -f "$LAB_BASE_DIR/$IMG_FILE"; then
  echo "already downloaded"
else
  sudo curl -fL --progress-bar -o "$LAB_BASE_DIR/$IMG_FILE.part" "$IMG_URL"
  sudo mv "$LAB_BASE_DIR/$IMG_FILE.part" "$LAB_BASE_DIR/$IMG_FILE"
fi

echo "== Verify the checksum. Expected: the two values are identical"
SUMS=$(curl -fsSL "${IMG_URL%/*}/SHA256SUMS" 2>/dev/null || curl -fsSL "${IMG_URL%/*}/CHECKSUM" 2>/dev/null || true)
REMOTE_SUM=$(echo "$SUMS" | grep -F "$IMG_FILE" | grep -owE '[0-9a-f]{64}' | head -n 1 || true)
LOCAL_SUM=$(sudo sha256sum "$LAB_BASE_DIR/$IMG_FILE" | awk '{print $1}')
echo "published: ${REMOTE_SUM:-(none found for this file name, compare by hand on the download site)}"
echo "local:     $LOCAL_SUM"
if [ -n "$REMOTE_SUM" ] && [ "$REMOTE_SUM" != "$LOCAL_SUM" ]; then
  echo "MISMATCH: run  sudo rm $LAB_BASE_DIR/$IMG_FILE  and download again"
  exit 1
fi

echo "== Look inside. Expected: file format: qcow2 (even for .img)"
sudo qemu-img info "$LAB_BASE_DIR/$IMG_FILE" | grep -E '^(file format|virtual size|disk size)'

# remembered for steps 07-09
mkdir -p "$LAB_HOME/state"
printf 'IMG_FILE=%s\nOS_VARIANT=%s\n' "$IMG_FILE" "$OS_VARIANT" > "$LAB_HOME/state/image-$NAME.env"
echo "Saved $LAB_HOME/state/image-$NAME.env"
echo "Undo: sudo rm $LAB_BASE_DIR/$IMG_FILE"
