#!/usr/bin/env bash
# 14 - Bridged network: each VM gets its own LAN IP         guide: Step 15
# Usage: ./14_bridge.sh on                     turn the wired card into a port of bridge br-lab
#        ./14_bridge.sh vm lab-web1 [network]  move a VM to lab-bridge (or back: lab-nat)
#        ./14_bridge.sh off                    move all VMs back to lab-nat and remove the bridge
# Run at the machine, not over SSH. Needs a wired card and NetworkManager.
# A reboot always restores your old network (the bridge does not autoconnect).
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env
S="$LAB_HOME/state"
mkdir -p "$S"

move_vm() {   # move_vm VM NETWORK
  sudo virt-xml --connect qemu:///system "$1" --edit --network "network=$2"
  virsh domiflist "$1"
  if [ "$(virsh domstate "$1")" = "running" ]; then
    vm_stop "$1"
    virsh start "$1"
    echo "IP of $1: $(wait_ip "$1" || echo 'none yet')"
  fi
}

case "${1:-}" in
on)
  if ! command -v nmcli >/dev/null; then echo "No NetworkManager here (netplan/networkd server): use ./15_remote.sh bridge instead."; exit 1; fi
  NIC=$(ip route show default | awk '{print $5; exit}')
  echo "== Look first: card $NIC"
  if [ -d "/sys/class/net/$NIC/wireless" ]; then echo "$NIC is Wi-Fi: bridging is not possible. Use NAT."; exit 1; fi
  if [ -n "${SSH_CONNECTION:-}" ]; then echo "You are on SSH. Run this at the machine."; exit 1; fi
  if nmcli -t -f NAME con show | grep -qx "$LAB_BRIDGE"; then echo "$LAB_BRIDGE already exists"; exit 0; fi
  ORIG=$(nmcli -g GENERAL.CONNECTION device show "$NIC")
  echo "$NIC" > "$S/bridge-iface"
  echo "$ORIG" > "$S/bridge-orig-con"
  ip -4 -br addr show "$NIC"
  echo "Rescue if needed: sudo nmcli con delete $LAB_BRIDGE-port $LAB_BRIDGE; sudo nmcli con up '$ORIG'   (or reboot)"

  echo "== Create $LAB_BRIDGE and move $NIC into it (network drops for a few seconds)"
  sudo nmcli con add type bridge ifname "$LAB_BRIDGE" con-name "$LAB_BRIDGE" \
    bridge.stp no bridge.mac-address "$(cat "/sys/class/net/$NIC/address")" \
    connection.autoconnect no ipv4.method auto ipv6.method auto
  sudo nmcli con add type bridge-slave ifname "$NIC" master "$LAB_BRIDGE" \
    con-name "$LAB_BRIDGE-port" connection.autoconnect no
  sudo nmcli con up "$LAB_BRIDGE-port" || true

  echo "== Check: the IP must move to $LAB_BRIDGE within 45 s, otherwise everything is rolled back"
  BR_IP=""
  for _ in $(seq 1 15); do
    BR_IP=$(ip -4 -o addr show "$LAB_BRIDGE" 2>/dev/null | awk '{print $4}')
    if [ -n "$BR_IP" ]; then break; fi
    sleep 3
  done
  if [ -z "$BR_IP" ]; then
    echo "No IP on $LAB_BRIDGE - rolling back"
    sudo nmcli con delete "$LAB_BRIDGE-port" "$LAB_BRIDGE" || true
    sudo nmcli con up "$ORIG"
    exit 1
  fi
  ip -4 -br addr show "$LAB_BRIDGE"                 # Expected: your IP, now on br-lab
  bridge link                                       # Expected: NIC ... master br-lab
  ping -c 2 1.1.1.1 || echo "ping failed (ICMP may be blocked on your network): check a web page works"
  echo "If Docker runs on THIS host, allow bridged traffic or VMs get no IP:"
  echo "  sudo iptables -I DOCKER-USER -i $LAB_BRIDGE -o $LAB_BRIDGE -j ACCEPT"

  echo "== Tell libvirt about the bridge (network lab-bridge, no DHCP of its own)"
  cat > "$LAB_HOME/lab-bridge.xml" <<EOF
<network>
  <name>lab-bridge</name>
  <forward mode='bridge'/>
  <bridge name='$LAB_BRIDGE'/>
</network>
EOF
  virsh net-define "$LAB_HOME/lab-bridge.xml"
  virsh net-start lab-bridge
  virsh net-list --all
  echo "Next: ./14_bridge.sh vm lab-web1   and   ./14_bridge.sh vm lab-db1"
  ;;

vm)
  VM=${2:?usage: ./14_bridge.sh vm <vm-name> [lab-bridge|lab-nat]}
  move_vm "$VM" "${3:-lab-bridge}"
  echo "Check from another machine on your LAN: ping <that IP>. Your router lists $VM as a device."
  ;;

off)
  echo "== Move every lab VM that uses lab-bridge back to lab-nat"
  for v in $(virsh list --all --name | grep '^lab-' || true); do
    if virsh domiflist "$v" | grep -w lab-bridge >/dev/null; then move_vm "$v" "$LAB_NET"; fi
  done
  echo "== Remove lab-bridge and $LAB_BRIDGE, restore the original connection"
  virsh net-destroy lab-bridge 2>/dev/null || true
  virsh net-undefine lab-bridge 2>/dev/null || true
  sudo nmcli con delete "$LAB_BRIDGE-port" "$LAB_BRIDGE" 2>/dev/null || true
  if [ -f "$S/bridge-orig-con" ]; then sudo nmcli con up "$(cat "$S/bridge-orig-con")"; fi
  ip -4 -br addr show                                # Expected: your IP is back on the card
  rm -f "$S/bridge-iface" "$S/bridge-orig-con"
  ;;

*) sed -n '2,8p' "$0"; exit 1 ;;
esac
