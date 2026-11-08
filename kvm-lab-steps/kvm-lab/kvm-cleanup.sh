#!/usr/bin/env bash
# =============================================================================
#  kvm-cleanup.sh  -  undo everything kvm-lab.sh did           (file 2 of 2)
#
#  One command puts the host back to its state before the lab:
#     ./kvm-cleanup.sh                 # asks before removing packages
#     ./kvm-cleanup.sh --yes           # no questions
#     ./kvm-cleanup.sh --keep-packages # remove lab VMs/networks/files, keep KVM installed
#
#  What it removes (only lab things - anything you had before is left alone):
#    1. every VM named lab-*  (+ its disks and snapshots)
#    2. every libvirt network named lab-*, the optional host bridge br-lab
#       (NetworkManager) or /etc/netplan/99-kvm-lab-bridge.yaml (servers)
#    3. the storage pool lab-pool and /var/lib/libvirt/images/kvm-lab
#    4. the packages kvm-lab.sh installed (exact list recorded at install time)
#    5. libvirt directories that did not exist before the lab
#    6. ~/kvm-lab  (SSH key, cloud-init files, scratch disks, state)
#    7. your membership of the libvirt group, if the manual guide added it
#  Safe to run more than once. Run as your normal user.
# =============================================================================
set -uo pipefail          # no -e: keep going and clean as much as possible

LAB_HOME="${KVM_LAB_HOME:-$HOME/kvm-lab}"
STATE_DIR="$LAB_HOME/state"
URI="qemu:///system"
POOL_NAME="lab-pool"
POOL_DIR="/var/lib/libvirt/images/kvm-lab"
HOST_BRIDGE="br-lab"
YES=0; KEEP_PKGS=0
for a in "$@"; do case "$a" in
  --yes|-y) YES=1 ;; --keep-packages) KEEP_PKGS=1 ;;
  -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
  *) echo "unknown option $a"; exit 1 ;;
esac; done

if [[ -t 1 ]]; then B=$'\e[1m'; C=$'\e[36m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'; else B=""; C=""; G=""; Y=""; N=""; fi
step() { echo; echo "${B}${C}==== $* ====${N}"; }
run()  { echo "  ${B}\$ $*${N}"; "$@"; }
ok()   { echo "  ${G}OK${N}  $*"; }
confirm() { [[ $YES == 1 ]] && return 0; read -rp "  $* [y/N] " r; [[ "$r" =~ ^[Yy] ]]; }
have() { command -v "$1" >/dev/null 2>&1; }
V()    { sudo virsh -c "$URI" "$@"; }

[[ $EUID -eq 0 ]] && { echo "Run as your normal user (the script uses sudo)."; exit 1; }

echo "${B}This removes all lab-* VMs, networks, disks and ~/kvm-lab.${N}"
[[ $KEEP_PKGS == 0 && -s "$STATE_DIR/packages-installed-by-lab.txt" ]] && \
  echo "It will also remove $(wc -l <"$STATE_DIR/packages-installed-by-lab.txt") packages the lab installed."
confirm "Continue?" || exit 0
sudo -v || exit 1

# ---------------------------------------------------------------------------
if have virsh; then
  step "1. Remove lab VMs"
  for vm in $(V list --all --name 2>/dev/null | grep '^lab-'); do
    V destroy "$vm" >/dev/null 2>&1
    V pool-refresh "$POOL_NAME" >/dev/null 2>&1
    run V undefine "$vm" --snapshots-metadata --remove-all-storage >/dev/null || run V undefine "$vm" --snapshots-metadata
  done

  step "2. Remove lab networks"
  for net in $(V net-list --all --name 2>/dev/null | grep '^lab-'); do
    V net-destroy "$net" >/dev/null 2>&1
    run V net-undefine "$net"
  done

  step "3. Remove lab storage pool"
  if V pool-info "$POOL_NAME" >/dev/null 2>&1; then
    V pool-destroy "$POOL_NAME" >/dev/null 2>&1
    run V pool-undefine "$POOL_NAME"
  fi
fi
run sudo rm -rf "$POOL_DIR"

# ---------------------------------------------------------------------------
if have nmcli && nmcli -t -f NAME con show 2>/dev/null | grep -qx "$HOST_BRIDGE"; then
  step "4. Remove host bridge $HOST_BRIDGE and restore the original connection"
  run sudo nmcli con delete "$HOST_BRIDGE-port"
  run sudo nmcli con delete "$HOST_BRIDGE"
  orig=$(cat "$STATE_DIR/bridge-orig-con" 2>/dev/null)
  ifc=$(cat "$STATE_DIR/bridge-iface" 2>/dev/null)
  if [[ -n "$orig" ]]; then run sudo nmcli con up "$orig"; elif [[ -n "$ifc" ]]; then run sudo nmcli device connect "$ifc"; fi
fi

# ---------------------------------------------------------------------------
NETPLAN_FILE=/etc/netplan/99-kvm-lab-bridge.yaml
if [[ -f "$NETPLAN_FILE" ]]; then
  step "4b. Remove the netplan bridge from the step-by-step guide (Step 16)"
  run sudo rm -f "$NETPLAN_FILE"
  run sudo netplan apply
fi
sudo systemctl stop kvm-lab-netrevert.timer >/dev/null 2>&1

if [[ -f "$STATE_DIR/added-to-libvirt-group" ]]; then
  step "4c. Remove $USER from the libvirt group (added in the step-by-step guide)"
  run sudo gpasswd -d "$USER" libvirt
fi

# ---------------------------------------------------------------------------
PKG_FILE="$STATE_DIR/packages-installed-by-lab.txt"
if [[ $KEEP_PKGS == 0 && -s "$PKG_FILE" ]]; then
  step "5. Remove the packages the lab installed"
  mapfile -t PKGS <"$PKG_FILE"
  sudo systemctl stop libvirtd virtqemud virtnetworkd virtstoraged \
       libvirtd.socket virtqemud.socket virtnetworkd.socket virtstoraged.socket >/dev/null 2>&1
  if have apt-get; then
    # show exactly what apt would remove: if it lists something NOT in the lab list,
    # that means you installed software since that depends on it - you decide.
    extra=$(sudo apt-get purge -s "${PKGS[@]}" 2>/dev/null | awk '/^Purg /{print $2}' | grep -vxF -f "$PKG_FILE")
    if [[ -n "$extra" ]]; then
      echo "  ${Y}These packages were NOT installed by the lab but depend on lab packages:${N}"; echo "$extra" | sed 's/^/     /'
      confirm "Remove them too?" || { echo "  Skipping package removal (re-run with --keep-packages to silence)."; PKGS=(); }
    fi
    (( ${#PKGS[@]} )) && run sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${PKGS[@]}"
  elif have dnf; then
    (( ${#PKGS[@]} )) && run sudo dnf remove -y "${PKGS[@]}"
  fi
  if (( ${#PKGS[@]} )); then
    step "6. Remove libvirt directories that were created by the lab"
    for d in /etc/libvirt /var/lib/libvirt /var/log/libvirt; do
      grep -qx "$d" "$STATE_DIR/dirs-before.txt" 2>/dev/null || { [[ -e $d ]] && run sudo rm -rf "$d"; }
    done
    # let VirtualBox use VT-x again without a reboot (fails harmlessly if busy)
    sudo modprobe -r kvm_intel kvm_amd kvm >/dev/null 2>&1 && ok "KVM kernel modules unloaded"
  fi
else
  step "5. Packages kept (KVM stays installed)"
fi

# ---------------------------------------------------------------------------
step "7. Remove $LAB_HOME"
run rm -rf "$LAB_HOME"

# ---------------------------------------------------------------------------
step "Verify"
left=0
if have virsh; then
  v=$(V list --all --name 2>/dev/null | grep -c '^lab-'); n=$(V net-list --all --name 2>/dev/null | grep -c '^lab-')
  [[ $v == 0 ]] && ok "no lab VMs" || { echo "  $v lab VMs left"; left=1; }
  [[ $n == 0 ]] && ok "no lab networks" || { echo "  $n lab networks left"; left=1; }
fi
ip link show "$HOST_BRIDGE" >/dev/null 2>&1 && { echo "  bridge $HOST_BRIDGE still exists"; left=1; } || ok "no host bridge"
[[ -f /etc/netplan/99-kvm-lab-bridge.yaml ]] && { echo "  netplan bridge file still exists"; left=1; } || ok "no netplan bridge file"
sudo test -e "$POOL_DIR" && { echo "  $POOL_DIR still exists"; left=1; } || ok "no lab disks"
[[ -e "$LAB_HOME" ]] && { echo "  $LAB_HOME still exists"; left=1; } || ok "no ~/kvm-lab"
echo
[[ $left == 0 ]] && echo "${G}${B}Host is clean.${N}" || echo "${Y}Some items remain - see above, or reboot and run again.${N}"
