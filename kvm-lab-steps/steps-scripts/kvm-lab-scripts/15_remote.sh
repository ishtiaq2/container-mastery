#!/usr/bin/env bash
# 15 - Deploy VMs to a remote KVM host (VMs get IPs from the remote DHCP)    guide: Step 16
#
#  where     command                                  what it does
#  laptop    ./15_remote.sh prepare                   copy this folder to the remote (needs REMOTE in lab.env)
#  remote    ./01_check_host.sh; ./02_install_kvm.sh; ./03_create_storage_pool.sh; log out and in
#  remote    ./15_remote.sh bridge                    netplan bridge br-lab, with a 5-minute automatic undo
#  remote    ./15_remote.sh confirm                   bridge works: cancel the undo, define lab-bridge
#  remote    ./15_remote.sh fresh lab-remote1         way A: build a new VM on the remote
#  laptop    ./15_remote.sh ship lab-web1             way B: flatten + copy a laptop VM (prints its MAC)
#  remote    ./15_remote.sh import lab-web1 <MAC>     way B: start the shipped VM with the same MAC
#  remote    ./15_remote.sh undo                      remove the bridge again
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env
NETPLAN_FILE=/etc/netplan/99-kvm-lab-bridge.yaml

case "${1:-}" in
prepare)
  if [ -z "$REMOTE" ]; then echo "Add  export REMOTE=user@host  to lab.env first"; exit 1; fi
  ssh "$REMOTE" 'hostname; grep -Ec "(vmx|svm)" /proc/cpuinfo; systemd-detect-virt || true'   # Expected: > 0 and none
  # the lab SSH key goes too, so both machines can log in to every lab VM
  rsync -av --exclude state --exclude scratch --exclude vms --exclude export --exclude stack --exclude '*.xml' \
    ./ "$REMOTE:kvm-lab/"
  echo "Next: ssh -t $REMOTE   then   cd kvm-lab && ./01_check_host.sh && ./02_install_kvm.sh && ./03_create_storage_pool.sh"
  ;;

bridge)
  NIC=$(ip route show default | awk '{print $5; exit}')
  echo "== Current network of $NIC"
  ip -4 -br addr show "$NIC"
  sudo cat /etc/netplan/*.yaml
  if sudo grep -q 'addresses:' /etc/netplan/*.yaml; then echo "Static address found: adapt the netplan file by hand instead."; exit 1; fi
  if command -v nmcli >/dev/null && nmcli -t -f DEVICE,STATE device 2>/dev/null | grep "^$NIC:connected" >/dev/null; then
    echo "$NIC is managed by NetworkManager: use ./14_bridge.sh on instead."; exit 1
  fi

  echo "== Write $NETPLAN_FILE (an extra file: deleting it restores the original setup)"
  sudo tee "$NETPLAN_FILE" >/dev/null <<EOF
network:
  version: 2
  ethernets:
    $NIC:
      dhcp4: false
      dhcp6: false
  bridges:
    $LAB_BRIDGE:
      interfaces: [$NIC]
      macaddress: $(cat "/sys/class/net/$NIC/address")
      dhcp4: true
      parameters:
        stp: false
        forward-delay: 0
EOF
  sudo chmod 600 "$NETPLAN_FILE"
  sudo cat "$NETPLAN_FILE"
  sudo netplan generate && echo "netplan syntax OK"

  echo "== Automatic undo in 5 minutes unless you run: ./15_remote.sh confirm"
  sudo systemctl stop kvm-lab-netrevert.timer 2>/dev/null || true
  sudo systemctl reset-failed kvm-lab-netrevert.service 2>/dev/null || true
  sudo systemd-run --unit=kvm-lab-netrevert --on-active=5min /bin/sh -c "rm -f $NETPLAN_FILE; netplan apply"
  echo "== Applying (SSH may freeze a few seconds; if it drops, reconnect and run ./15_remote.sh confirm)"
  sudo netplan apply
  ip -4 -br addr show "$LAB_BRIDGE"                 # Expected: the server's IP, now on br-lab
  ;;

confirm)
  if [ -z "$(ip -4 -o addr show "$LAB_BRIDGE" 2>/dev/null)" ]; then echo "$LAB_BRIDGE has no IP: do not confirm, let the timer undo it"; exit 1; fi
  ip -4 -br addr show "$LAB_BRIDGE"
  bridge link
  sudo systemctl stop kvm-lab-netrevert.timer 2>/dev/null || true
  echo "Automatic undo cancelled."
  ping -c 2 1.1.1.1 || echo "ping failed (ICMP may be blocked): check a web page works"
  if ! virsh net-info lab-bridge >/dev/null 2>&1; then
    cat > "$LAB_HOME/lab-bridge.xml" <<EOF
<network><name>lab-bridge</name><forward mode='bridge'/><bridge name='$LAB_BRIDGE'/></network>
EOF
    virsh net-define "$LAB_HOME/lab-bridge.xml"
  fi
  virsh net-start lab-bridge 2>/dev/null || true
  virsh net-autostart lab-bridge
  virsh net-list --all
  ;;

fresh)
  VM=${2:-lab-remote1}
  ./06_download_image.sh ubuntu24
  ./07_create_disk.sh "$VM" ubuntu24 20
  ./08_cloud_init.sh "$VM"
  ./09_boot_vm.sh "$VM" 2048 2 lab-bridge          # Expected: an IP from the REMOTE network
  ;;

ship)
  VM=${2:-lab-web1}
  if [ -z "$REMOTE" ]; then echo "Add  export REMOTE=user@host  to lab.env first"; exit 1; fi
  MAC=$(virsh domiflist "$VM" | awk '/52:54/{print $5; exit}')
  echo "== $VM has MAC $MAC (the guest finds its network card by MAC, so it must stay the same)"
  vm_stop "$VM"
  virsh domstate "$VM"                              # Expected: shut off
  echo "== Flatten overlay + base into one standalone disk"
  mkdir -p "$LAB_HOME/export"
  sudo qemu-img convert -p -O qcow2 "$LAB_POOL_DIR/$VM.qcow2" "$LAB_HOME/export/$VM.qcow2"
  sudo chown "$USER" "$LAB_HOME/export/$VM.qcow2"
  qemu-img info "$LAB_HOME/export/$VM.qcow2" | grep -E '^(virtual size|disk size|backing file)'   # Expected: no backing file
  echo "== Copy to the remote"
  ssh "$REMOTE" "mkdir -p kvm-lab/vms/$VM"
  scp "$LAB_HOME/vms/$VM/vm.env" "$REMOTE:kvm-lab/vms/$VM/"
  scp "$LAB_HOME/export/$VM.qcow2" "$REMOTE:/tmp/"
  echo "Next, on the remote:  ./15_remote.sh import $VM $MAC"
  ;;

import)
  VM=${2:?usage: ./15_remote.sh import <vm-name> <MAC>}; MAC=${3:?MAC address printed by ship}
  # shellcheck source=/dev/null
  source "$LAB_HOME/vms/$VM/vm.env"                # gives OS_VARIANT
  sudo mv "/tmp/$VM.qcow2" "$LAB_POOL_DIR/"
  # no --cloud-init: the VM was set up on its first boot on the laptop
  sudo virt-install --connect qemu:///system --name "$VM" --memory 2048 --vcpus 2 --cpu host-passthrough \
    --osinfo "$OS_VARIANT" --import \
    --disk "path=$LAB_POOL_DIR/$VM.qcow2,format=qcow2,bus=virtio" \
    --network "network=lab-bridge,model=virtio,mac=$MAC" \
    --graphics none --console pty,target_type=serial --noautoconsole
  echo "IP of $VM: $(wait_ip "$VM" || echo 'none yet: virsh console '"$VM")"    # Expected: an IP from the REMOTE DHCP
  echo "From the laptop: source ./lab.env && labssh -J $USER@$(hostname -I | awk '{print $1}') $LAB_USER@<that IP>"
  ;;

undo)
  virsh net-destroy lab-bridge 2>/dev/null || true
  virsh net-undefine lab-bridge 2>/dev/null || true
  sudo rm -f "$NETPLAN_FILE"
  sudo netplan apply
  ip -4 -br addr show                               # Expected: the IP is back on the card, no br-lab
  echo "Remove everything else on the remote with ./16_cleanup.sh"
  ;;

*) sed -n '2,13p' "$0"; exit 1 ;;
esac
