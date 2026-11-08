#!/usr/bin/env bash
# 05 - Disk images by hand with qemu-img (no sudo)          guide: Step 6
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env
mkdir -p "$LAB_HOME/scratch" && cd "$LAB_HOME/scratch"
rm -f demo.* looks-raw.img base.qcow2 overlay.qcow2 demo-back.qcow2

echo "== 5.1 qcow2 only uses space for what is written. Expected: virtual 10 GiB, disk ~200 KiB"
qemu-img create -f qcow2 demo.qcow2 10G
qemu-img info demo.qcow2 | grep -E '^(virtual size|disk size)'

echo "== 5.2 raw is a sparse file. Expected: ls 10G, du 0"
qemu-img create -f raw demo.img 10G
ls -lh demo.img
du -h demo.img

echo "== 5.3 The format is inside the file. Expected: file format: qcow2"
cp demo.qcow2 looks-raw.img
qemu-img info looks-raw.img | grep '^file format'

echo "== 5.4 Base + overlay. Expected: overlay.qcow2 -> backing file base.qcow2"
qemu-img create -f qcow2 base.qcow2 2G
qemu-img create -f qcow2 -F qcow2 -b "$PWD/base.qcow2" overlay.qcow2 20G
qemu-img info --backing-chain overlay.qcow2 | grep -E '^(image|backing file|virtual size)'

echo "== 5.5 Resize, snapshot, convert to VirtualBox and back"
qemu-img resize overlay.qcow2 +5G
qemu-img snapshot -c before-change overlay.qcow2
qemu-img snapshot -l overlay.qcow2
qemu-img convert -f qcow2 -O vdi demo.qcow2 demo.vdi
qemu-img convert -f vdi -O qcow2 demo.vdi demo-back.qcow2
qemu-img check demo-back.qcow2                     # Expected: No errors were found on the image.
ls -lh

echo "Undo: rm -rf $LAB_HOME/scratch"
