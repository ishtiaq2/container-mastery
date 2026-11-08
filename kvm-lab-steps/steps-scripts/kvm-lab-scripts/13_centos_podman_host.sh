#!/usr/bin/env bash
# =============================================================================
# 13 - CentOS Stream 9 VM as a Podman container host
#
# What you get: a VM (default name lab-centos) on the lab NAT network with
#   podman            - runs containers, Docker-compatible, no daemon, no root needed
#   podman-compose    - reads the same compose.yaml files Docker Compose uses
# Next step: ./13b_deploy_containers.sh <your-container-folder>
#
# Usage:  ./13_centos_podman_host.sh [vm-name] [ram-MB] [cpus] [disk-GB]
#         default: lab-centos 6144 2 30   (OpenNMS + PostgreSQL need ~6 GB RAM)
# Needs:  steps 02-04 done (KVM installed, lab-pool, lab-nat)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env
VM=${1:-lab-centos}; RAM=${2:-6144}; CPUS=${3:-2}; DISK=${4:-30}

# -----------------------------------------------------------------------------
# 1. Create and boot the CentOS VM (same steps 06-09 as the Ubuntu VM)
#    06: download + verify the CentOS Stream 9 cloud image (once)
#    07: thin overlay disk on top of it
#    08: cloud-init: user 'lab', your lab SSH key, qemu-guest-agent
#    09: virt-install, wait for an IP, show the VM from inside
# -----------------------------------------------------------------------------
./06_download_image.sh centos9
./07_create_disk.sh "$VM" centos9 "$DISK"
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
echo "== Podman (from CentOS's own repositories)"
sudo dnf -y -q install podman dnf-plugins-core

echo "== podman-compose (from EPEL, which needs the CRB repository)"
sudo dnf config-manager --set-enabled crb
sudo dnf -y -q install epel-release epel-next-release
sudo dnf -y -q install podman-compose

echo "== Let short image names like 'postgres:15' resolve to Docker Hub"
#    Without this, Podman may stop with a 'short-name' error on compose files written for Docker.
mkdir -p ~/.config/containers
printf 'unqualified-search-registries = ["docker.io"]\nshort-name-mode = "permissive"\n' > ~/.config/containers/registries.conf

echo "== Rootless Podman needs sub-UIDs for your user (e.g. PostgreSQL runs as UID 999 in its container)"
grep "^$USER:" /etc/subuid /etc/subgid || sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate

echo "== Keep your containers running after you log out (rootless Podman runs under your user)"
sudo loginctl enable-linger "$USER"

echo "== Check. Expected: versions, 'Hello Podman World', SELinux Enforcing"
podman --version
podman-compose --version
podman run --rm quay.io/podman/hello | grep -i hello
getenforce
EOF

echo
echo "Done. Log in:     source ./lab.env && labssh $LAB_USER@$IP"
echo "Next:            ./13b_deploy_containers.sh <your-container-folder> $VM"
echo "Undo:            virsh destroy $VM; virsh undefine $VM --remove-all-storage"
