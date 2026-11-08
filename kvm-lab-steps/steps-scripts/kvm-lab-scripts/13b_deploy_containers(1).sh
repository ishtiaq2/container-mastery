#!/usr/bin/env bash
# =============================================================================
# 13b - Copy your container files into the CentOS or Ubuntu VM and run them with Podman
#
# Your folder needs a compose.yaml (or docker-compose.yml) with a PostgreSQL
# service, plus whatever it builds (e.g. app/Dockerfile, app/app.py).
# PostgreSQL is started first and checked before the other containers start.
#
# Usage:  ./13b_deploy_containers.sh <folder> [vm-name] [db-service] [db-user] [web-port]
#         default:                   -        lab-centos database    postgres  8980
# Example: ./13b_deploy_containers.sh ~/devel/my-opennms-stack
# Needs:   ./13_centos_podman_host.sh or ./13_ubuntu_podman_host.sh run first
#          (for the Ubuntu VM pass its name: ./13b_deploy_containers.sh <folder> lab-ubuntu)
#
# Notes:
#   - Images with short names (postgres:15) come from Docker Hub (set up in step 13).
#   - CentOS has SELinux on: named volumes work as they are; a bind mount of a
#     host folder needs ':Z', e.g.  ./data:/data:Z  (harmless on Ubuntu)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env
SRC=${1:?usage: ./13b_deploy_containers.sh <folder> [vm-name] [db-service] [db-user] [web-port]}
VM=${2:-lab-centos}; DB=${3:-database}; DB_USER=${4:-postgres}; PORT=${5:-8980}
SRC=$(cd "$SRC" && pwd)
NAME=$(basename "$SRC")
IP=$(vm_ip "$VM")
if [ -z "$IP" ]; then echo "$VM has no IP: is it running? (virsh list --all)"; exit 1; fi

# -----------------------------------------------------------------------------
# 1. Copy the folder to the VM: it lands in /home/lab/<folder-name>
#    By hand:  labscp -r <folder> lab@<IP>:
# -----------------------------------------------------------------------------
echo "== Copy $SRC to $VM:~/$NAME"
ls "$SRC"
labscp -r "$SRC" "$LAB_USER@$IP:"

# -----------------------------------------------------------------------------
# 2. Inside the VM: start PostgreSQL, wait until it accepts connections,
#    then start everything else. The values after '--' become $1..$4 inside.
# -----------------------------------------------------------------------------
labssh "$LAB_USER@$IP" 'bash -s' -- "$NAME" "$DB" "$DB_USER" "$PORT" <<'EOF'
set -e
NAME=$1; DB=$2; DB_USER=$3; PORT=$4
cd ~/"$NAME"
ls compose.yaml docker-compose.yml 2>/dev/null || { echo "No compose.yaml in ~/$NAME"; exit 1; }

echo "== Start the PostgreSQL service '$DB' first"
podman-compose up -d "$DB"
C=$(podman ps --filter "label=com.docker.compose.service=$DB" --format '{{.Names}}' | head -n 1)
echo "PostgreSQL container: $C"
[ -n "$C" ] || { echo "No running container for service '$DB': check the service name in compose.yaml"; exit 1; }

echo "== Wait until PostgreSQL accepts connections (up to 2 min). Expected: accepting connections"
for i in $(seq 1 24); do
  if podman exec "$C" pg_isready; then break; fi
  sleep 5
done

echo "== Start all other containers (builds images from your Dockerfiles)"
podman-compose up -d --build

echo "== Open port $PORT in the VM firewall, if one is running (firewalld on CentOS, ufw on Ubuntu)"
if systemctl is-active --quiet firewalld; then
  sudo firewall-cmd --permanent --add-port="$PORT/tcp" && sudo firewall-cmd --reload
elif command -v ufw >/dev/null && sudo ufw status | grep -qw active; then
  sudo ufw allow "$PORT/tcp"
fi

echo "== Check. Expected: every container 'Up', and your databases listed"
podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
podman exec "$C" psql -U "$DB_USER" -c '\l'
EOF

# -----------------------------------------------------------------------------
# 3. From the host: is the web port answering? (OpenNMS needs 3-10 minutes)
# -----------------------------------------------------------------------------
echo "== From the host: http://$IP:$PORT"
curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://$IP:$PORT/" || echo "not answering yet - try again in a few minutes"

echo
echo "Log in and look around:"
echo "  source ./lab.env && labssh $LAB_USER@$IP"
echo "  cd ~/$NAME"
echo "  podman-compose ps                      # status"
echo "  podman-compose logs -f                 # logs (Ctrl+C to stop)"
echo "  podman exec -it <container> bash       # a shell inside a container"
echo "  podman-compose up -d --build           # after you change your code (copy it again with this script)"
echo "  podman-compose down                    # stop and remove the containers (volumes are kept)"
