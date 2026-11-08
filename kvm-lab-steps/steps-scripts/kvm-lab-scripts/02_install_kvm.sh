#!/usr/bin/env bash
# 02 - Install KVM and record exactly what changed            guide: Step 3
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env
S="$LAB_HOME/state"
mkdir -p "$S"

list_pkgs() {
  if command -v apt-get >/dev/null; then
    dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' | awk '$1=="ii"{print $2}' | sort
  else
    rpm -qa --qf '%{NAME}\n' | sort
  fi
}

echo "== 2.1 'Before' picture (taken only once, so a re-run never overwrites it)"
if [ ! -f "$S/packages-before.txt" ]; then
  list_pkgs > "$S/packages-before.txt"
  for d in /etc/libvirt /var/lib/libvirt /var/log/libvirt; do
    if [ -e "$d" ]; then echo "$d"; fi
  done > "$S/dirs-before.txt"
fi
wc -l < "$S/packages-before.txt"

echo "== 2.2 Install the packages"
if command -v apt-get >/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst \
    dnsmasq-base bridge-utils cloud-utils libguestfs-tools rsync
else
  # RHEL/Alma/Rocky 9: no bridge-utils package, and cloud-utils comes from EPEL
  sudo dnf install -y qemu-kvm qemu-img libvirt libvirt-client virt-install guestfs-tools rsync
fi

echo "== 2.3 'After' picture: keep only the new packages"
list_pkgs > "$S/packages-after.txt"
comm -13 "$S/packages-before.txt" "$S/packages-after.txt" > "$S/packages-installed-by-lab.txt"
echo "New packages: $(wc -l < "$S/packages-installed-by-lab.txt")   (0 = they were all installed before the first run)"

echo "== 2.4 Start libvirt and check KVM"
sudo systemctl enable --now libvirtd
systemctl is-active libvirtd                       # Expected: active
grep -E '^kvm' /proc/modules | cut -d' ' -f1       # Expected: kvm_intel (or kvm_amd) and kvm
ls -l /dev/kvm                                     # Expected: crw-rw---- ... root kvm ... /dev/kvm
virt-host-validate qemu || true                    # WARN about IOMMU / secure guest is fine

echo "== 2.5 Add $USER to the libvirt and kvm groups (a marker file per group, for cleanup)"
for g in libvirt kvm; do
  if id -nG "$USER" | grep -qw "$g"; then
    echo "already in $g"
  else
    sudo usermod -aG "$g" "$USER"
    touch "$S/added-to-$g-group"
    echo "added to $g"
  fi
done
sg libvirt -c "virsh uri" || echo "virsh failed: log out and back in, then run: virsh uri"

echo
echo "Done. Log out and back in once, so every new terminal has the groups. Then check:"
echo "  virsh list --all        (no 'permission denied')"
echo "  ls -l $S"
