#!/usr/bin/env bash
# 04 - Create the lab NAT network 192.168.150.0/24          guide: Step 5
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env

if virsh net-info "$LAB_NET" >/dev/null 2>&1; then
  echo "== $LAB_NET already exists"
else
  echo "== Is $LAB_SUBNET.0/24 free? (a printed line means it is taken)"
  if ip -4 -o addr | grep " $LAB_SUBNET\."; then
    echo "Taken. Set another LAB_SUBNET in lab.env (e.g. 192.168.151) and run again."
    exit 1
  fi

  echo "== Write $LAB_HOME/$LAB_NET.xml and define it"
  cat > "$LAB_HOME/$LAB_NET.xml" <<EOF
<network>
  <name>$LAB_NET</name>
  <forward mode='nat'/>
  <bridge name='virbr-lab' stp='on' delay='0'/>
  <ip address='$LAB_SUBNET.1' netmask='255.255.255.0'>
    <dhcp><range start='$LAB_SUBNET.100' end='$LAB_SUBNET.200'/></dhcp>
  </ip>
</network>
EOF
  cat "$LAB_HOME/$LAB_NET.xml"
  virsh net-define "$LAB_HOME/$LAB_NET.xml"
fi
virsh net-start "$LAB_NET" 2>/dev/null || true       # 'already active' on a re-run is fine
virsh net-autostart "$LAB_NET"

echo "== Check. Expected: lab-nat active yes, virbr-lab with $LAB_SUBNET.1/24, a dnsmasq line, NAT rules > 0"
virsh net-list --all
ip -br addr show virbr-lab
pgrep -af dnsmasq | grep "$LAB_NET" || echo "no dnsmasq for $LAB_NET"
echo "NAT rules: $( (sudo nft list ruleset 2>/dev/null; sudo iptables-save 2>/dev/null) | grep -c "$LAB_SUBNET" || true)"

echo "Undo: virsh net-destroy $LAB_NET; virsh net-undefine $LAB_NET"
