#!/usr/bin/env bash
# 09_a_troubleshoot_and_tools.sh - Interactive Diagnostics & Provisioning
# Usage: ./09_a_troubleshoot_and_tools.sh [vm-name]
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env
VM=${1:-lab-centos}

echo "========================================="
echo " KVM & Podman Interactive Setup Check    "
echo "========================================="

# 1. KVM Check
echo -e "\n== 1. Checking KVM Hardware Acceleration =="
if [ ! -e "/dev/kvm" ]; then
    echo "[!] ISSUE: /dev/kvm is missing. Hardware acceleration is not active."
    echo "    FIX:   Load 'kvm_intel' and 'kvm_amd' kernel modules."
    read -r -p "    Press [Enter] to run the fix, or [Ctrl+C] to abort..."
    
    sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true
    
    if [ ! -e "/dev/kvm" ]; then
        echo "    [ERROR] Still missing /dev/kvm. You must enable VT-x/AMD-V in your BIOS."
        exit 1
    fi
else
    echo "[OK] /dev/kvm exists."
fi

# 2. VM Boot Status
echo -e "\n== 2. Checking if VM '$VM' is Running =="
if virsh domstate "$VM" 2>/dev/null | grep -q 'shut off'; then
    echo "[!] ISSUE: VM '$VM' is currently shut off."
    echo "    FIX:   Run ./09_boot_vm.sh to boot the VM."
    read -r -p "    Press [Enter] to start the VM, or [Ctrl+C] to abort..."
    
    ./09_boot_vm.sh "$VM" 8192 4
elif ! virsh domstate "$VM" 2>/dev/null | grep -q 'running'; then
    echo "    [ERROR] VM '$VM' does not exist or is in an unknown state."
    exit 1
else
    echo "[OK] VM '$VM' is running."
fi

# 3. IP Address Fetch
echo -e "\n== 3. Fetching VM IP Address =="
VM_IP=$(virsh net-dhcp-leases lab-nat | awk "/$VM/ {print \$5}" | cut -d/ -f1 | head -n 1)
while [ -z "$VM_IP" ]; do
    echo "[!] ISSUE: Could not find an IP address for $VM."
    echo "    FIX:   Wait for cloud-init to finish booting and check DHCP again."
    read -r -p "    Press [Enter] to check again, or [Ctrl+C] to abort..."
    VM_IP=$(virsh net-dhcp-leases lab-nat | awk "/$VM/ {print \$5}" | cut -d/ -f1 | head -n 1)
done
echo "[OK] Target IP: $VM_IP"

# Base SSH Command
SSH_CMD="ssh -o StrictHostKeyChecking=no -i $LAB_HOME/ssh/id_ed25519 lab@$VM_IP"

# 4. Podman Installation
echo -e "\n== 4. Checking Podman Installation =="
if ! $SSH_CMD "command -v podman" >/dev/null 2>&1; then
    echo "[!] ISSUE: Podman is not installed inside the VM."
    echo "    FIX:   Run 'sudo dnf install -y podman epel-release podman-compose'."
    read -r -p "    Press [Enter] to install tools over SSH, or [Ctrl+C] to abort..."
    
    $SSH_CMD "sudo dnf install -y podman epel-release && sudo dnf install -y podman-compose"
else
    echo "[OK] Podman is already installed."
fi

# 5. Systemd Linger
echo -e "\n== 5. Checking Systemd Linger (Background Containers) =="
if ! $SSH_CMD "loginctl show-user lab | grep -q 'Linger=yes'" 2>/dev/null; then
    echo "[!] ISSUE: User 'lab' does not have systemd linger enabled (containers die on logout)."
    echo "    FIX:   Run 'sudo loginctl enable-linger lab'."
    read -r -p "    Press [Enter] to enable linger, or [Ctrl+C] to abort..."
    
    $SSH_CMD "sudo loginctl enable-linger lab"
else
    echo "[OK] Systemd Linger is enabled."
fi

# 6. Nginx Web Server Container
echo -e "\n== 6. Checking Web Test Container =="
if ! $SSH_CMD "podman ps --format '{{.Names}}' | grep -q '^web-test$'" 2>/dev/null; then
    echo "[!] ISSUE: Nginx container 'web-test' is not running."
    echo "    FIX:   Pull nginx:alpine and run it on port 8080."
    read -r -p "    Press [Enter] to launch the web container, or [Ctrl+C] to abort..."
    
    $SSH_CMD "podman rm -f web-test 2>/dev/null || true; podman run -d --name web-test -p 8080:80 docker.io/library/nginx:alpine"
else
    echo "[OK] 'web-test' container is running."
fi

# 7. Final Verification
echo -e "\n== 7. Verifying Nginx Network Routing =="
if ! curl -s -I "http://$VM_IP:8080" | grep -q "200 OK"; then
    echo "[!] FAILED: Cannot reach Nginx on http://$VM_IP:8080 from the host."
    echo "    Please verify firewall rules or container status manually inside the VM."
else
    echo "[OK] Nginx is responding over the network on http://$VM_IP:8080!"
    echo -e "\nSetup Complete. Log in anytime with:"
    echo "    source ./lab.env && labssh lab@$VM_IP"
fi
