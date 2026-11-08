#!/usr/bin/env bash
# =============================================================================
# 13 (Ubuntu) - Ubuntu 24.04 VM as a Podman container host
#
# What you get: a VM (default name lab-ubuntu) on the lab NAT network with
#   podman            - runs containers, Docker-compatible, no daemon, no root needed
#   podman-compose    - reads the same compose.yaml files Docker Compose uses
# Next step: ./13b_deploy_containers.sh <your-container-folder> lab-ubuntu
#
# Usage:  ./13_ubuntu_podman_host.sh [vm-name] [ram-MB] [cpus] [disk-GB]
#         default: lab-ubuntu 6144 2 30   (OpenNMS + PostgreSQL need ~6 GB RAM)
# Needs:  steps 02-04 done (KVM installed, lab-pool, lab-nat)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env
VM=${1:-lab-ubuntu}; RAM=${2:-6144}; CPUS=${3:-2}; DISK=${4:-30}

# -----------------------------------------------------------------------------
# 1. Create and boot the Ubuntu VM (steps 06-09)
#    06: download + verify noble-server-cloudimg-amd64.img (once)
#    07: thin overlay disk on top of it
#    08: cloud-init: user 'lab', your lab SSH key, qemu-guest-agent
#    09: virt-install, wait for an IP, show the VM from inside
# -----------------------------------------------------------------------------
./06_download_image.sh ubuntu24
./07_create_disk.sh "$VM" ubuntu24 "$DISK"
./08_cloud_init.sh "$VM"
./09_boot_vm.sh "$VM" "$RAM" "$CPUS"
IP=$(vm_ip "$VM")
echo "$VM has IP $IP"

# -----------------------------------------------------------------------------
# 2. Install Podman and podman-compose inside the VM
#    The commands between <<'EOF' and EOF run INSIDE the VM over SSH.
#    To do it by hand instead:  source ./lab.env && labssh lab@<IP>   then type them.
# -----------------------------------------------------------------------------
labssh "$LAB_USER@$IP" 'bash -s' <<'EOF'
set -e
echo "== Podman and podman-compose (both in Ubuntu 24.04's own repositories)"
sudo apt-get update -qq
sudo apt-get install -y -qq podman podman-compose

echo "== Let short image names like 'postgres:15' resolve to Docker Hub"
#    Without this, Podman may stop with a 'short-name' error on compose files written for Docker.
mkdir -p ~/.config/containers
printf 'unqualified-search-registries = ["docker.io"]\nshort-name-mode = "permissive"\n' > ~/.config/containers/registries.conf

echo "== Keep your containers running after you log out (rootless Podman runs under your user)"
sudo loginctl enable-linger "$USER"

echo "== Check. Expected: versions and 'Hello Podman World'"
podman --version
podman-compose --version
podman run --rm quay.io/podman/hello | grep -i hello
grep PRETTY_NAME /etc/os-release
EOF

echo
echo "Done. Log in:     source ./lab.env && labssh $LAB_USER@$IP"
echo "Next:            ./13b_deploy_containers.sh <your-container-folder> $VM"
echo "Undo:            virsh destroy $VM; virsh undefine $VM --remove-all-storage"
