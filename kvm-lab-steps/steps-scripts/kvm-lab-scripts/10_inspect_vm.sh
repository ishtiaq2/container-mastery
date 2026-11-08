#!/usr/bin/env bash
# 10 - The VM seen as a host process (read-only)             guide: Step 11
# Usage: ./10_inspect_vm.sh [vm-name]                         (default lab-web1)
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env
VM=${1:-lab-web1}
PID=$(sudo cat "/run/libvirt/qemu/$VM.pid")

echo "== 1. The whole VM is one process. Expected: user libvirt-qemu (not root), command qemu-system-x86"
ps -o pid,user,%cpu,%mem,rss,etime,comm -p "$PID"
ps -Z -p "$PID" -o label= || true                   # its own AppArmor/SELinux profile

echo "== 2. Each virtual CPU is a thread. Expected: 'CPU 0/KVM', 'CPU 1/KVM'"
ps -T -p "$PID" -o spid,comm,psr,%cpu | grep -E 'SPID|CPU'
virsh vcpuinfo "$VM" | grep -E '^(VCPU|CPU:)'

echo "== 3. Guest RAM is memory of this process"
virsh dominfo "$VM" | grep -i memory
sudo grep VmRSS "/proc/$PID/status"

echo "== 4. The disk is a file, the network card is a tap device"
virsh domblklist "$VM"
virsh domiflist "$VM"

echo "== 5. The same VM from the inside"
labssh "$LAB_USER@$(vm_ip "$VM")" 'nproc; free -h | head -n 2; lsblk -d -o NAME,SIZE; ip -br link'
