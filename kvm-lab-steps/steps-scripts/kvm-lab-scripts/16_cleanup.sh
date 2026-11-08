#!/usr/bin/env bash
# 16 - Clean up, in reverse order                             guide: Step 17
# Removes only what the lab created. Your scripts, lab.env and README stay.
set -uo pipefail          # no -e: keep going and clean as much as possible
cd "$(dirname "$0")" && source ./lab.env
S="$LAB_HOME/state"

read -rp "Remove all lab-* VMs, networks, disks and the lab's packages? [y/N] " a
case "$a" in y|Y) ;; *) exit 0 ;; esac

echo "== 16.1 VMs"
for v in $(virsh list --all --name 2>/dev/null | grep '^lab-'); do
  virsh destroy "$v" 2>/dev/null
  virsh undefine "$v" --snapshots-metadata --remove-all-storage
done

echo "== 16.2 Networks"
for n in $(virsh net-list --all --name 2>/dev/null | grep '^lab-'); do
  virsh net-destroy "$n" 2>/dev/null
  virsh net-undefine "$n"
done

echo "== 16.3 Host bridge (step 14) and netplan bridge (step 15)"
if command -v nmcli >/dev/null && nmcli -t -f NAME con show | grep -qx "$LAB_BRIDGE"; then
  sudo nmcli con delete "$LAB_BRIDGE-port" "$LAB_BRIDGE"
  sudo nmcli con up "$(cat "$S/bridge-orig-con")"
fi
if [ -f /etc/netplan/99-kvm-lab-bridge.yaml ]; then
  sudo rm -f /etc/netplan/99-kvm-lab-bridge.yaml
  sudo netplan apply
fi
sudo systemctl stop kvm-lab-netrevert.timer 2>/dev/null

echo "== 16.4 Storage pool and disks"
virsh pool-destroy "$LAB_POOL" 2>/dev/null
virsh pool-undefine "$LAB_POOL" 2>/dev/null
sudo rm -rf "$LAB_POOL_DIR"

echo "== 16.5 Group membership (only groups step 02 added)"
for g in libvirt kvm; do
  if [ -f "$S/added-to-$g-group" ]; then sudo gpasswd -d "$USER" "$g"; fi
done

echo "== 16.6 Packages step 02 installed"
if [ -s "$S/packages-installed-by-lab.txt" ]; then
  mapfile -t PKGS < "$S/packages-installed-by-lab.txt"
  sudo systemctl stop libvirtd libvirtd.socket 2>/dev/null
  if command -v apt-get >/dev/null; then
    echo "Other packages apt would also remove (empty = none):"
    sudo apt-get purge -s "${PKGS[@]}" 2>/dev/null | awk '/^Purg /{print $2}' | grep -vxF -f "$S/packages-installed-by-lab.txt"
    read -rp "Purge ${#PKGS[@]} packages? [y/N] " a
    case "$a" in y|Y) sudo apt-get purge -y "${PKGS[@]}" ;; esac
  else
    sudo dnf remove "${PKGS[@]}"                 # dnf shows the list and asks
  fi
else
  echo "No packages recorded: KVM stays installed."
fi

echo "== 16.7 libvirt directories that did not exist before step 02"
if ! command -v virsh >/dev/null && [ -f "$S/dirs-before.txt" ]; then
  for d in /etc/libvirt /var/lib/libvirt /var/log/libvirt; do
    grep -qx "$d" "$S/dirs-before.txt" || sudo rm -rf "$d"
  done
fi

echo "== 16.8 KVM kernel modules (lets VirtualBox use VT-x again)"
sudo modprobe -r kvm_intel kvm 2>/dev/null || sudo modprobe -r kvm_amd kvm 2>/dev/null

echo "== 16.9 Generated files in $LAB_HOME (scripts and lab.env are kept)"
rm -rf "$LAB_HOME/scratch" "$LAB_HOME/vms" "$LAB_HOME/ssh" "$LAB_HOME/export" "$LAB_HOME/stack" \
       "$LAB_HOME/lab-nat.xml" "$LAB_HOME/lab-bridge.xml" "$S"

echo "== Check. Expected: no lab VMs/networks, no br-lab, no $LAB_POOL_DIR"
virsh list --all 2>/dev/null
virsh net-list --all 2>/dev/null
ip link show "$LAB_BRIDGE" 2>/dev/null || echo "no $LAB_BRIDGE"
sudo ls -d "$LAB_POOL_DIR" 2>/dev/null || echo "no $LAB_POOL_DIR"
echo "Log out and back in so the group change applies."
