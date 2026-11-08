#!/usr/bin/env bash
# 11 - Lifecycle and snapshots                                guide: Step 12
# Usage: ./11_snapshot_demo.sh [vm-name]                      (default lab-web1)
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env
VM=${1:-lab-web1}

echo "== Shut down, then start again"
vm_stop "$VM"
virsh domstate "$VM"                                # Expected: shut off
virsh start "$VM"
IP=$(wait_ip "$VM")
for _ in $(seq 1 30); do
  if labssh -o ConnectTimeout=5 "$LAB_USER@$IP" true 2>/dev/null; then break; fi
  sleep 5
done

echo "== Snapshot, break something, roll back"
virsh snapshot-delete "$VM" before-mistake >/dev/null 2>&1 || true   # left over from an earlier run
labssh "$LAB_USER@$IP" 'echo important > ~/data.txt && cat ~/data.txt'          # Expected: important
virsh snapshot-create-as "$VM" before-mistake --description "data.txt exists"
virsh snapshot-list "$VM"
labssh "$LAB_USER@$IP" 'rm ~/data.txt; ls ~/data.txt || true'                   # Expected: No such file
virsh snapshot-revert "$VM" before-mistake
sleep 5
labssh "$LAB_USER@$IP" 'cat ~/data.txt'                                         # Expected: important (it is back)

virsh snapshot-delete "$VM" before-mistake
echo "Try by hand: virsh destroy $VM (pull the plug), virsh autostart $VM, virsh dumpxml $VM | less"
