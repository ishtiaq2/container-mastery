# Podman, OpenNMS, PostgreSQL & Python Event Automation
### A complete, hands-on container learning guide

This guide teaches containers from the ground up using Podman, then builds a real
three-container stack: **OpenNMS**, **PostgreSQL**, and a **Python automation
container** that triggers OpenNMS events and shows you how custom alarms are defined.
It folds in and expands on the Docker/Podman/Karaf README you provided, retargeted at
this specific stack.

---

## Table of Contents

1. [Container Fundamentals](#1-container-fundamentals)
2. [Docker vs. Podman](#2-docker-vs-podman)
3. [Installing Podman](#3-installing-podman)
4. [Podman Basics OpenNMS](#6-container-1--opennms)
7. [Container 2 the Python Automation Container](#9-container-3--the-python-automation-container)
10. [Wiring It All Together with podman-compose](#10-wiring-it-all-together-with-podman-compose)
11. [Step-by-Step: Bring the Stack Up and Trigger a Custom Alarm](#11-step-by-step-bring-the-stack-up-and-trigger-a-custom-alarm)
12. [Podman Pods (a Podman-native alternative to compose)](#12-podman-pods-a-podman-native-alternative-to-compose)
13. [Troubleshooting](#13-troubleshooting)
14. [Security Notes](#14-security-notes)
15. [Docker vs. Podman Quick Reference](#15-docker-vs-podman-quick-reference)
16. [Roadmap & Further Reading](#16-roadmap--further-reading)

---

## 1. Container Fundamentals

A **container** packages an application with everything it needs to run as one isolated, portable unit. It is **not** a lightweight
virtual machine: there's no separate guest kernel. A container is a normal process on
the host, made to *look* isolated using two Linux kernel features:

- **Namespaces** limit and account for the resources (CPU, memory) that
 process is allowed to consume.

- **Namespaces** give the process its own private view of things: its own filesystem root, its own network interfaces, its own process-ID numbering (so the container's main process can appear as PID 1 inside the container while being an ordinary PID on the host).
- **Cgroups** (control groups) — limit and account for the resources (CPU, memory) that process is allowed to consume.

A **Dockerfile** (or `Containerfile` a read-only, layered snapshot everything
needed to run the app. A **container** is a running instance of that image.

**Compose** (Docker Compose, or `podman-compose`) takes this one level up: instead of
typing out long `run` commands for each piece of a multi-container application, you
describe all your services, networks, and volumes declaratively in one YAML file, and the
tool sets up a private network so containers can reach each other by service name each `podman` command runs as its own process, no persistent background service |
| Root requirement | Traditionally daemon runs as root (rootless mode exists but is the exception) | **Rootless by default** intentionally near-identical; `alias docker=podman` works for most commands |
| Multi-container tooling | `docker compose` (built in) | `podman-compose` (separate tool, reads the same `docker-compose.yml` format) or native **pods** |
| Systemd integration | Bolted on | First-class | **Pods**: a group of containers that share one network namespace, modeled directly on Kubernetes pods |

The practical upshot for this guide: because Podman is daemonless and rootless, **you
don't need `sudo` for anything below**, and if you've used Docker before, nearly every
command you already know just works by swapping `docker` for `podman`.

---

## 3. Installing Podman

**Linux (Fedora/RHEL/CentOS)** Podman needs a Linux VM under the hood on these platforms:
```bash
brew install podman        # macOS
podman machine init
podman machine start
```

**Optional but recommended for this guide** Hands-On

Before touching OpenNMS, get comfortable with the primitives.

```bash
# Pull and run a trivial container
podman run --rm hello-world

# Run something interactive and see the isolated filesystem
podman run -it --rm alpine sh
# inside the container:
ps -ef        # notice your shell is PID 1 in here
exit

# List running containers
podman ps

# List all containers, including stopped ones
podman ps -a

# List images you've pulled/built
podman images

# Remove a stopped container
podman rm <container-id-or-name>

# See it needs no daemon   opennms (container)     Horizon core + web UI    ports: 8980 (HTTP),             8101 (SSH/Karaf)
                             
                
                
                
                
                              HTTP REST API (:8980/rest/events)
                               py-events (container)      Python script(s) that      send custom UEI events   

 All three share one Podman network (or pod) the monitoring engine + web console + REST API (everything we built a
 mental model of earlier: Jetty serving HTTP, Jersey serving REST, Karaf/OSGi under the
 hood).
- **database** our own container, purely a client: it doesn't run OpenNMS code, it
 just calls OpenNMS's REST API (or execs `send-event.pl`) the same way any external
 integration would.

---

## 6. Container 1 that's the
supported path.

Create a project directory:
```bash
mkdir -p opennms-stack && cd opennms-stack
```

Create `.opennms.env` (OpenNMS-side connection settings):
```env
TZ=UTC
OPENNMS_DBNAME=opennms
OPENNMS_DBUSER=opennms
OPENNMS_DBPASS=opennmsPass123
```

Create `.postgres.env` (shared by both the database and OpenNMS containers so they agree
on credentials):
```env
POSTGRES_HOST=database
POSTGRES_PORT=5432
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgresPass123
```

We'll reference these two files from `podman-compose.yml` in Section 10 `-s` is the one you want for
 normal use: it initializes the database if needed, applies configuration, and starts
 OpenNMS Horizon in one step.
- On first boot, OpenNMS runs schema installation against PostgreSQL PostgreSQL

We use the plain, official PostgreSQL image just reference `postgres:14` (or `postgres:16` for a
newer release) directly in compose, shown in Section 10, with a health check so OpenNMS
waits for it to be truly ready rather than just "started":

```yaml
healthcheck:
 test: ["CMD-SHELL", "pg_isready -U postgres"]
 interval: 10s
 timeout: 5s
 retries: 5
```

---

## 8. Understanding OpenNMS Events, UEIs, and Alarms

Before writing the Python container, you need the concepts it's automating.

### What is a UEI?

A **UEI** (Universal Event Identifier) is simply a unique string name for a type of
event "this exact thing happened at this
 exact moment." OpenNMS logs every event it receives, always.
- An **alarm** is a *deduplicated, stateful* representation of a problem, built from
 events. If the same underlying problem generates 500 identical "interface down" events
 over an hour, you don't want 500 separate open tickets critically for turning events into alarms so your own custom event definitions need to be placed above any catch-all files, or they'll never be reached.</cite>

A minimal custom event definition looks like this:

```xml
<event>
 <uei>uei.opennms.org/custom/pythonHealthCheck/serviceDown</uei>
 <event-label>Custom: Python health-check reports service down</event-label>
 <descr>&lt;p&gt;The Python health-check script reported %parm[serviceName]% as DOWN on %nodelabel%.&lt;/p&gt;</descr>
 <logmsg dest="logndisplay">Python health check: %parm[serviceName]% is DOWN on %nodelabel%</logmsg>
 <severity>Major</severity>
 <alarm-data reduction-key="%uei%:%nodeid%:%parm[serviceName]%" alarm-type="1" auto-clean="false"/>
</event>

<event>
 <uei>uei.opennms.org/custom/pythonHealthCheck/serviceUp</uei>
 <event-label>Custom: Python health-check reports service restored</event-label>
 <descr>&lt;p&gt;The Python health-check script reported %parm[serviceName]% as UP again on %nodelabel%.&lt;/p&gt;</descr>
 <logmsg dest="logndisplay">Python health check: %parm[serviceName]% is UP on %nodelabel%</logmsg>
 <severity>Normal</severity>
 <alarm-data reduction-key="%uei%:%nodeid%:%parm[serviceName]%"
             alarm-type="2"
             clear-key="uei.opennms.org/custom/pythonHealthCheck/serviceDown:%nodeid%:%parm[serviceName]%"
             auto-clean="false"/>
</event>
```

### Decoding `alarm-data`

- **`reduction-key`** tells OpenNMS how this alarm relates to others:
 - `1` = a **problem** (something going wrong on the "up"/"resolved" event, this
 must exactly match the `reduction-key` of the "down"/"problem" event it's meant to
 clear. That's the pairing mechanism: OpenNMS doesn't guess which alarm an "up" event
 resolves whether the alarm should be automatically deleted (not just cleared)
 once resolved, after a retention window.

### Where custom event files go

Put your custom definitions in their own file, e.g.
`${OPENNMS_HOME}/etc/events/custom.events.xml`, then register it near the *top* of
`eventconf.xml` (above the catch-all tributaries) with:

```xml
<event-file>events/custom.events.xml</event-file>
```

After editing, <cite index="15-1">you must restart the eventd daemon for the change to take effect <cite index="29-1">posting an event in XML format to the Events endpoint of the Horizon REST API creates a corresponding event, exactly as the raw XML-TCP interface would</cite>, and <cite index="32-1">that POST accepts either XML (`application/xml`) or JSON (`application/json`) as its content type</cite>. This is precisely the Jersey-powered REST layer from earlier in our conversation the Python Automation Container

### Step 1 .opennms.env
podman-compose.yml
          py-events/
    requirements.txt
    `py-events/requirements.txt`

```
requests==2.32.3
```

### Step 3 `py-events/send_event.py`

```python
"""
Sends custom OpenNMS events over the REST API (the Jersey-powered /rest/events
endpoint), exactly the same mechanism send-event.pl uses internally -- just
callable from a completely separate container over plain HTTP.
"""
import sys
import requests
from requests.auth import HTTPBasicAuth

OPENNMS_URL = "http://opennms:8980/opennms/rest/events"
AUTH = HTTPBasicAuth("admin", "admin")  # change for anything beyond a lab

EVENT_XML_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<event xmlns="http://xmlns.opennms.org/xsd/event">
   <uei>{uei}</uei>
   <source>py-events-container</source>
   <nodeid>{node_id}</nodeid>
   <parms>
       <parm>
           <parmName>serviceName</parmName>
           <value type="string" encoding="text">{service_name}</value>
       </parm>
   </parms>
</event>"""


def send_event(uei: str, node_id: int, service_name: str) -> None:
   payload = EVENT_XML_TEMPLATE.format(uei=uei, node_id=node_id, service_name=service_name)
   headers = {"Content-Type": "application/xml"}

   response = requests.post(OPENNMS_URL, data=payload, headers=headers, auth=AUTH)

   if response.status_code == 200 or response.status_code == 204:
       print(f"Sent {uei} for service='{service_name}' on node {node_id} -- status {response.status_code}")
   else:
       print(f"Failed to send event: {response.status_code} {response.text}")
       sys.exit(1)


if __name__ == "__main__":
   # Example: fire the "down" event, then (run again with 'up') the clearing event.
   action = sys.argv[1] if len(sys.argv) > 1 else "down"
   node_id = int(sys.argv[2]) if len(sys.argv) > 2 else 1
   service_name = sys.argv[3] if len(sys.argv) > 3 else "billing-api"

   uei = (
       "uei.opennms.org/custom/pythonHealthCheck/serviceDown"
       if action == "down"
       else "uei.opennms.org/custom/pythonHealthCheck/serviceUp"
   )
   send_event(uei, node_id, service_name)
```

### Step 5 this is the
`podman-compose` promise from Section 2: same YAML, no daemon.

---

## 11. Step-by-Step: Bring the Stack Up and Trigger a Custom Alarm

### Step 1 Confirm the web console is reachable

```bash
curl -I http://localhost:8980/opennms/login.jsp
```

Or open `http://localhost:8980/opennms` in a browser Register the custom event file

The etc-overlay copies our file in, but `eventconf.xml` still needs one line added to
load it. Exec into the running container:

```bash
podman exec -it opennms bash
```

Inside the container:
```bash
cd /opt/opennms/etc
# Add our tributary file near the top of the list, above the catch-alls
sed -i '/<\/events>/i\  <event-file>events/custom.events.xml</event-file>' eventconf.xml

# Reload eventd instead of restarting the whole container
./bin/send-event.pl uei.opennms.org/internal/reloadDaemonConfig -p 'daemonName Eventd'
exit
```

This step is also a nice concrete look at `send-event.pl` used exactly the way it's
intended Fire your custom event from the Python container

```bash
podman exec -it py-events python send_event.py down 1 billing-api
```

You should see:
```
Sent uei.opennms.org/custom/pythonHealthCheck/serviceDown for service='billing-api' on node 1 -- status 204
```

### Step 5 Alarms**. You should see a new **Major** alarm
labeled with your custom description, referencing `billing-api`.

### Step 6 because the `clear-key` on the "up" event matches the
`reduction-key` of the "down" alarm exactly, OpenNMS automatically resolves/clears it
rather than creating a second, unrelated alarm. This is the pairwise problem/resolution
mechanic from Section 8 working end-to-end.

### Step 7 they can reach each other over `localhost`, not just a
private bridge network. You can build the same three-container stack without any compose
tooling at all:

```bash
# Create a pod, publishing OpenNMS's ports at the pod level
podman pod create --name opennms-pod -p 8980:8980 -p 8101:8101 -p 5432:5432

# Everything below joins that pod, so they all share one network namespace
podman run -d --pod opennms-pod --name database \
 --env-file .postgres.env \
 -v psql-data:/var/lib/postgresql/data \
 postgres:14

podman run -d --pod opennms-pod --name opennms \
 --env-file .opennms.env --env-file .postgres.env \
 -v opennms-data:/opennms-data \
 -v ./etc-overlay:/opt/opennms-etc-overlay \
 opennms/horizon:latest -s

podman run -d --pod opennms-pod --name py-events \
 py-events:latest
```

Because they share a network namespace, `py-events` could reach OpenNMS at
`http://localhost:8980/opennms/rest/events` here instead of `http://opennms:8980/...` another Podman-only
trick:
```bash
podman generate kube opennms-pod > opennms-pod.yaml
```

---

## 13. Troubleshooting

- **OpenNMS container keeps restarting / healthcheck never passes** confirm all three services are on the same
 `networks:` entry in the compose file; a container left off the shared network can't
 resolve other services by name.
- **Custom event never appears / alarm never created** you edited the file but didn't
 reload/restart Eventd; re-run the `send-event.pl ... reloadDaemonConfig` step.
- **Rootless Podman and bind-mounted volume permission errors** bind them to `127.0.0.1:8101:8101` etc., or
 drop the `ports:` mapping entirely and only reach them from other containers on the
 private network.
- Never commit real credentials in `.opennms.env`/`.postgres.env` to version control for
 anything beyond localhost, put TLS in front of it (a reverse proxy, or OpenNMS's own
 HTTPS connector).

---

## 15. Docker vs. Podman Quick Reference

(Carried over and expanded from your original README, since it's genuinely useful day to
day.)

| Task | Docker | Podman |
|---|---|---|
| Run a container | `docker run ...` | `podman run ...` |
| Multi-container stack | `docker compose up -d` | `podman-compose up -d` |
| Build an image | `docker build .` | `podman build .` (or `buildah`) |
| Background service management | `dockerd` (daemon) | none see below) and
 run the stack on ECS/AKS instead of locally, as a natural "local containers Events & Alarms deep-dive (`docs.opennms.com`)
- OpenNMS REST API reference (`/rest/events`, `/rest/nodes`, `/rest/alarms`)
- Podman documentation GitHub
- PostgreSQL documentation
