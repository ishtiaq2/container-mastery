#!/usr/bin/env bash
# 03 - Create the lab storage pool                          guide: Step 4
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env

echo "== Define and build pool $LAB_POOL -> $LAB_POOL_DIR"
if ! virsh pool-info "$LAB_POOL" >/dev/null 2>&1; then
  virsh pool-define-as "$LAB_POOL" dir --target "$LAB_POOL_DIR"
  virsh pool-build "$LAB_POOL"
fi
virsh pool-start "$LAB_POOL" 2>/dev/null || true     # 'already active' on a re-run is fine
virsh pool-autostart "$LAB_POOL"
sudo mkdir -p "$LAB_BASE_DIR"

echo "== Check. Expected: lab-pool  active  yes"
virsh pool-list --all
virsh pool-dumpxml "$LAB_POOL" | grep '<path>'
sudo ls -ld "$LAB_POOL_DIR" "$LAB_BASE_DIR"

echo "Undo: virsh pool-destroy $LAB_POOL; virsh pool-undefine $LAB_POOL; sudo rm -rf $LAB_POOL_DIR"
