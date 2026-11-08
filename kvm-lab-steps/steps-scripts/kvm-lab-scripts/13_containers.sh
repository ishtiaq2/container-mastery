#!/usr/bin/env bash
# 13 - OpenNMS + PostgreSQL + Python app in a VM              guide: Step 14
# Usage: ./13_containers.sh            (creates VM lab-stack: 6 GB RAM, 2 vCPU, 30 GB)
set -euo pipefail
cd "$(dirname "$0")" && source ./lab.env
VM=lab-stack

echo "== 13.1 A bigger Ubuntu VM (same steps 06-09)"
./06_download_image.sh ubuntu24
./07_create_disk.sh "$VM" ubuntu24 30
./08_cloud_init.sh "$VM"
./09_boot_vm.sh "$VM" 6144 2
IP=$(vm_ip "$VM")

echo "== 13.2 Install Docker inside the VM"
labssh "$LAB_USER@$IP" 'sudo apt-get update -qq && sudo apt-get install -y -qq docker.io docker-compose-v2 && sudo usermod -aG docker $USER'
labssh "$LAB_USER@$IP" 'sudo docker version --format "Docker {{.Server.Version}}"; sudo docker compose version'

echo "== 13.3 Write the three files in $LAB_HOME/stack and copy them to the VM"
mkdir -p "$LAB_HOME/stack/app"
cat > "$LAB_HOME/stack/compose.yaml" <<'EOF'
name: labstack
services:
  database:
    image: postgres:15
    environment: {POSTGRES_USER: postgres, POSTGRES_PASSWORD: postgres, POSTGRES_DB: appdb}
    volumes: [pgdata:/var/lib/postgresql/data]
    healthcheck: {test: ["CMD-SHELL", "pg_isready -U postgres"], interval: 10s, timeout: 5s, retries: 10}
    networks: [backend]
  horizon:
    image: opennms/horizon:latest          # pin a version for real use
    command: ["-s"]                        # create the DB schema, then start
    depends_on: {database: {condition: service_healthy}}
    environment:
      POSTGRES_HOST: database              # the service name is the host name
      POSTGRES_PORT: 5432
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      OPENNMS_DBNAME: opennms
      OPENNMS_DBUSER: opennms
      OPENNMS_DBPASS: opennms
    volumes: [opennms-rrd:/opt/opennms/share/rrd]
    ports: ["8980:8980"]
    networks: [backend]
  app:
    build: ./app
    depends_on: {database: {condition: service_healthy}}
    environment:
      DB_HOST: database
      DB_NAME: appdb
      DB_USER: postgres
      DB_PASSWORD: postgres
      OPENNMS_URL: http://horizon:8980/opennms
      OPENNMS_USER: admin
      OPENNMS_PASSWORD: admin
    restart: unless-stopped
    networks: [backend]
networks: {backend: {}}
volumes: {pgdata: {}, opennms-rrd: {}}
EOF
cat > "$LAB_HOME/stack/app/Dockerfile" <<'EOF'
FROM python:3.12-slim
RUN pip install --no-cache-dir "psycopg[binary]" requests
COPY app.py /app.py
CMD ["python", "-u", "/app.py"]
EOF
cat > "$LAB_HOME/stack/app/app.py" <<'EOF'
import os, time, psycopg, requests
DB = dict(host=os.environ["DB_HOST"], dbname=os.environ["DB_NAME"],
          user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"])
URL = os.environ["OPENNMS_URL"] + "/rest/info"
AUTH = (os.environ["OPENNMS_USER"], os.environ["OPENNMS_PASSWORD"])
with psycopg.connect(**DB, autocommit=True) as conn:
    conn.execute("CREATE TABLE IF NOT EXISTS checks (id serial PRIMARY KEY, at timestamptz DEFAULT now(), ok boolean, detail text)")
    while True:
        try:
            r = requests.get(URL, auth=AUTH, timeout=5, headers={"Accept": "application/json"})
            ok, detail = r.ok, (r.json().get("displayVersion") if r.ok else f"HTTP {r.status_code}")
        except requests.RequestException as e:
            ok, detail = False, f"OpenNMS not reachable yet ({type(e).__name__})"
        conn.execute("INSERT INTO checks (ok, detail) VALUES (%s, %s)", (ok, detail))
        print(f"ok={ok} detail={detail}", flush=True)
        time.sleep(30)
EOF
labscp -r "$LAB_HOME/stack" "$LAB_USER@$IP:"

echo "== 13.4 Start the containers (first time pulls ~1.5 GB)"
labssh "$LAB_USER@$IP" 'cd stack && sudo docker compose config --quiet && sudo docker compose up -d --build && sudo docker compose ps'

echo "== 13.5 Docker DNS: each service name resolves to a container IP"
labssh "$LAB_USER@$IP" 'cd stack && sudo docker compose exec -T app getent hosts database horizon' || true

echo "== 13.6 Wait for OpenNMS (3-10 min). Expected: JSON with displayVersion"
for _ in $(seq 1 60); do
  if curl -sf -u admin:admin "http://$IP:8980/opennms/rest/info"; then echo; break; fi
  sleep 10
done
labssh "$LAB_USER@$IP" "cd stack && sudo docker compose exec -T database psql -U postgres -d appdb -c 'select id, at, ok, detail from checks order by id desc limit 5;'"

echo
echo "Browser:  http://$IP:8980/opennms   (admin / admin, change it)"
echo "Logs:     source ./lab.env && labssh $LAB_USER@$IP 'cd stack && sudo docker compose logs -f app'"
echo "Your app: edit $LAB_HOME/stack/app/app.py, then:"
echo "          labscp -r $LAB_HOME/stack $LAB_USER@$IP: && labssh $LAB_USER@$IP 'cd stack && sudo docker compose up -d --build app'"
echo "Undo:     virsh destroy $VM; virsh undefine $VM --remove-all-storage"
