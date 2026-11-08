#!/usr/bin/env bash
# 01 - Check the host (read-only, changes nothing)          guide: Step 2
set -uo pipefail
cd "$(dirname "$0")" && source ./lab.env

echo "== 1. CPU virtualisation. Expected: a number above 0, and VT-x or AMD-V"
grep -Ec '(vmx|svm)' /proc/cpuinfo
lscpu | grep -i virtualization

echo "== 2. Real hardware or a VM? Expected: none"
systemd-detect-virt

echo "== 3. Memory and disk. Expected: Mem total 8Gi+, /var Avail 30G+"
free -h | head -n 2
df -h /var

echo "== 4. KVM / VirtualBox modules loaded? (empty before step 02; stop VirtualBox VMs if vbox shows)"
grep -E '^(kvm|vbox)' /proc/modules | cut -d' ' -f1

echo "== 5. OS and package manager"
. /etc/os-release && echo "$PRETTY_NAME"
command -v apt-get dnf

echo "== 6. Network card to the LAN (needed in step 14)"
ip route show default
NIC=$(ip route show default | awk '{print $5; exit}')
if [ -d "/sys/class/net/$NIC/wireless" ]; then echo "$NIC is Wi-Fi"; else echo "$NIC is wired"; fi
