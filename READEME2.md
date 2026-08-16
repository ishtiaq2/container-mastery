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
4. [Podman Basics - Hands-On](#4-podman-basics--hands-on)
5. [Architecture of Our Stack](#5-architecture-of-our-stack)
6. [Container 1 - OpenNMS](#6-container-1--opennms)
7. [Container 2 - PostgreSQL](#7-container-2--postgresql)
8. [Understanding OpenNMS Events, UEIs, and Alarms](#8-understanding-opennms-events-ueis-and-alarms)
9. [Container 3 - the Python Automation Container](#9-container-3--the-python-automation-container)
10. [Wiring It All Together with podman-compose](#10-wiring-it-all-together-with-podman-compose)
11. [Step-by-Step: Bring the Stack Up and Trigger a Custom Alarm](#11-step-by-step-bring-the-stack-up-and-trigger-a-custom-alarm)
12. [Podman Pods (a Podman-native alternative to compose)](#12-podman-pods-a-podman-native-alternative-to-compose)
13. [Troubleshooting](#13-troubleshooting)
14. [Security Notes](#14-security-notes)
15. [Docker vs. Podman Quick Reference](#15-docker-vs-podman-quick-reference)
16. [Roadmap & Further Reading](#16-roadmap--further-reading)

---

## 1. Container Fundamentals

A **container** packages an application with everything it needs to run - code,
runtime, libraries, config - as one isolated, portable unit. It is **not** a lightweight
virtual machine: there's no separate guest kernel. A container is a normal process on
the host, made to *look* isolated using two Linux kernel features:

- **Namespaces** - give the process its own private view of things: its own filesystem
  root, its own network interfaces, its own process-ID numbering (so the container's main
  process can appear as PID 1 inside the container while being an ordinary PID on the
  host).
- **Cgroups (control groups)** - limit and account for the resources (CPU, memory) that
  process is allowed to consume.

A **Dockerfile** (or `Containerfile` - Podman's preferred name for the identical format)
is a text recipe: a sequence of instructions (`FROM`, `RUN`, `COPY`, `EXPOSE`, `CMD`) that
gets built, top to bottom, into an **image** - a read-only, layered snapshot everything
needed to run the app. A **container** is a running instance of that image.

**Compose** (Docker Compose, or `podman-compose`) takes this one level up: instead of
typing out long `run` commands for each piece of a multi-container application, you
describe all your services, networks, and volumes declaratively in one YAML file, and the
tool sets up a private network so containers can reach each other by service name - e.g.
your OpenNMS container can reach PostgreSQL simply at the hostname `database`.

---

## 2. Docker vs. Podman

| | Docker | Podman |
|---|---|---|
| Architecture | Client talks to a long-running background **daemon** (`dockerd`), usually running as root | **Daemonless** - each `podman` command runs as its own process, no persistent background service |
| Root requirement | Traditionally daemon runs as root (rootless mode exists but is the exception) | **Rootless by default** - designed to run entirely as your normal user |
| Command syntax | `docker run ...` | `podman run ...` - intentionally near-identical; `alias docker=podman` works for most commands |
| Multi-container tooling | `docker compose` (built in) | `podman-compose` (separate tool, reads the same `docker-compose.yml` format) or native **pods** |
| Systemd integration | Bolted on | First-class - `podman generate systemd` turns any container/pod into a systemd unit |
| Unique concept | - | **Pods**: a group of containers that share one network namespace, modeled directly on Kubernetes pods |

The practical upshot for this guide: because Podman is daemonless and rootless, **you
don't need `sudo` for anything below**, and if you've used Docker before, nearly every
command you already know just works by swapping `docker` for `podman`.

---

## 3. Installing Podman

**Linux (Fedora/RHEL/CentOS)** - usually preinstalled or one command:
```bash
sudo dnf install -y podman
```

**Debian/Ubuntu:**
```bash
sudo apt-get update
sudo apt-get install -y podman
```

**macOS / Windows** - Podman needs a Linux VM under the hood on these platforms:
```bash
brew install podman        # macOS
podman machine init
podman machine start
```

**Optional but recommended for this guide** - `podman-compose`, so you can reuse the
same `docker-compose.yml` syntax:
```bash
pip install podman-compose --break-system-packages
```

Verify everything:
```bash
podman --version
podman info
```

---

## 4. Podman Basics - Hands-On

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

# See it needs no daemon - check for a podman background process
ps -ef | grep podman
# (there usually isn't one lingering, unlike dockerd)
```

Try mapping a port and confirming rootless networking works fine on a normal (>1024)
port:
```bash
podman run -d --name web-test -p 8888:80 docker.io/library/nginx:alpine
curl -I http://localhost:8888
podman stop web-test && podman rm web-test
```

---

## 5. Architecture of Our Stack

```
                 ┌────────────────────────┐
                 │   opennms (container)   │
                 │  Horizon core + web UI  │
                 │  ports: 8980 (HTTP),    │
                 │         8101 (SSH/Karaf)│
                 └───────────┬─────────────┘
                              │ JDBC (postgres:5432)
                              ▼
                 ┌────────────────────────┐
                 │  database (container)   │
                 │      PostgreSQL         │
                 └────────────────────────┘
                              ▲
                              │ HTTP REST API (:8980/rest/events)
                              │ + auth (admin/admin by default)
                 ┌────────────┴─────────────┐
                 │  py-events (container)    │
                 │  Python script(s) that    │
                 │  send custom UEI events   │
                 └───────────────────────────┘

  All three share one Podman network (or pod) - containers reach each other
  by service name: "opennms", "database", "py-events".
```

- **opennms** - the monitoring engine + web console + REST API (everything we built a
  mental model of earlier: Jetty serving HTTP, Jersey serving REST, Karaf/OSGi under the
  hood).
- **database** - PostgreSQL, OpenNMS's persistence layer for nodes, events, and alarms.
- **py-events** - our own container, purely a client: it doesn't run OpenNMS code, it
  just calls OpenNMS's REST API (or execs `send-event.pl`) the same way any external
  integration would.

---

## 6. Container 1 - OpenNMS

We'll use the official OpenNMS Horizon image rather than build our own - that's the
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

We'll reference these two files from `podman-compose.yml` in Section 10 - no need to run
OpenNMS standalone yet.

A few things worth knowing about this image before you start it:

- <cite index="19-1">Setting `POSTGRES_HOST` controls the PostgreSQL database host that OpenNMS connects to, defaulting to a service named "database" if unset.</cite>
- The container's entrypoint script takes a mode flag - `-s` is the one you want for
  normal use: it initializes the database if needed, applies configuration, and starts
  OpenNMS Horizon in one step.
- On first boot, OpenNMS runs schema installation against PostgreSQL - this takes a
  couple of minutes, so don't panic if `:8980` isn't answering immediately.

---

## 7. Container 2 - PostgreSQL

We use the plain, official PostgreSQL image - no OpenNMS-specific customization needed
on the database side; OpenNMS creates its own schema/user on first boot using the
credentials from the env files above.

Nothing to build here either - just reference `postgres:14` (or `postgres:16` for a
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
event - a URI-shaped string like `uei.opennms.org/nodes/nodeDown`. Every event that
enters OpenNMS (from SNMP traps, syslog, internal daemons, the REST API, or manual
scripts) carries exactly one UEI. It's the "what kind of thing happened" label.

### Events vs. Alarms

- An **event** is a single, timestamped occurrence - "this exact thing happened at this
  exact moment." OpenNMS logs every event it receives, always.
- An **alarm** is a *deduplicated, stateful* representation of a problem, built from
  events. If the same underlying problem generates 500 identical "interface down" events
  over an hour, you don't want 500 separate open tickets - you want **one alarm** whose
  count field says "500." That deduplication is what `alarm-data` configuration
  controls.

### `eventconf.xml` and how a UEI becomes configured

`${OPENNMS_HOME}/etc/eventconf.xml` (plus its "tributary" included files under
`etc/events/`) is where every known UEI is defined: its label, description, severity, log
message, and - critically for turning events into alarms - its `<alarm-data>` block.
<cite index="15-1">The main eventconf.xml pulls in many tributary files split up by vendor, and each is loaded in the order it's listed when Horizon starts, with events inside each file matched against incoming events in that same order - so your own custom event definitions need to be placed above any catch-all files, or they'll never be reached.</cite>

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

- **`reduction-key`** - <cite index="5-1">this is the critical attribute: it can mix literal text with references to event fields/parameters, and its purpose is to uniquely identify the signature of a problem so that repeated matching events collapse into a single alarm rather than creating a new one each time.</cite> Convention is UEI first (least significant), then increasingly specific identifiers, joined with `:`.
- **`alarm-type`** - tells OpenNMS how this alarm relates to others:
  - `1` = a **problem** (something going wrong - down, degraded, triggered)
  - `2` = a **resolution/clear** for a matching problem alarm
  - `3` = <cite index="4-1">a notification-only alarm with no associated resolution, such as a security-relevant SNMP trap that isn't paired with an "all clear" event</cite>
- **`clear-key`** (or `clear-uei`, a shorthand form) - on the "up"/"resolved" event, this
  must exactly match the `reduction-key` of the "down"/"problem" event it's meant to
  clear. That's the pairing mechanism: OpenNMS doesn't guess which alarm an "up" event
  resolves - you tell it explicitly.
- **`auto-clean`** - whether the alarm should be automatically deleted (not just cleared)
  once resolved, after a retention window.

### Where custom event files go

Put your custom definitions in their own file, e.g.
`${OPENNMS_HOME}/etc/events/custom.events.xml`, then register it near the *top* of
`eventconf.xml` (above the catch-all tributaries) with:

```xml
<event-file>events/custom.events.xml</event-file>
```

After editing, <cite index="15-1">you must restart the eventd daemon for the change to take effect - either from the Karaf shell, or by sending eventd its own reload event from the command line.</cite>

### Triggering events: `send-event.pl` vs. the REST API

OpenNMS ships a Perl utility, `send-event.pl`, for exactly this kind of scripted event
generation: <cite index="9-1">it lets you create and send an event to trigger internal processes, most often used to reload daemon configuration without a full restart, and it's also commonly used as an automation tool to trigger events from continuous-integration scripts or other automated processes.</cite> Its usage takes the shape <cite index="11-1">`${OPENNMS_HOME}/bin/send-event.pl <uei> [host:port] [options]`</cite>, for example:

```bash
${OPENNMS_HOME}/bin/send-event.pl uei.opennms.org/internal/reloadDaemonConfig -p 'daemonName Eventd'
```

The catch for our architecture: `send-event.pl` normally runs **from inside the OpenNMS
container itself** (or over its raw TCP event-receiver port, which isn't exposed for
external callers by default). Since our Python container is a *separate* container, the
clean, container-friendly equivalent is the **REST API** - <cite index="29-1">posting an event in XML format to the Events endpoint of the Horizon REST API creates a corresponding event, exactly as the raw XML-TCP interface would</cite>, and <cite index="32-1">that POST accepts either XML (`application/xml`) or JSON (`application/json`) as its content type</cite>. This is precisely the Jersey-powered REST layer from earlier in our conversation - same mechanism you'd use to query `/rest/nodes`, just POSTing to `/rest/events` instead.

---

## 9. Container 3 - the Python Automation Container

### Step 1 - Project layout

```
opennms-stack/
├── .opennms.env
├── .postgres.env
├── podman-compose.yml
├── etc-overlay/
│   └── events/
│       └── custom.events.xml      # the two <event> blocks from Section 8
└── py-events/
    ├── Dockerfile
    ├── requirements.txt
    └── send_event.py
```

### Step 2 - `py-events/requirements.txt`

```
requests==2.32.3
```

### Step 3 - `py-events/Dockerfile`

```dockerfile
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY send_event.py .

# Keep the container alive so you can exec into it interactively for the tutorial;
# in production you'd run this as a one-shot job or a cron/Kubernetes CronJob instead.
CMD ["sleep", "infinity"]
```

### Step 4 - `py-events/send_event.py`

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

### Step 5 - the custom event file: `etc-overlay/events/custom.events.xml`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<events xmlns="http://xmlns.opennms.org/xsd/eventconf">
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
</events>
```

The official OpenNMS image supports an **etc-overlay** mechanism: anything you place
under `./etc-overlay` on the host gets layered onto `/opt/opennms/etc` inside the
container at startup, which is exactly how we'll inject this custom event file without
building a custom OpenNMS image. We still need one manual step (Section 11) to register
this file in `eventconf.xml` itself.

---

## 10. Wiring It All Together with podman-compose

`podman-compose.yml`:

```yaml
version: "3.8"

networks:
  opennms-net:
    driver: bridge

volumes:
  psql-data:
  opennms-data:
  opennms-etc:

services:
  database:
    image: docker.io/library/postgres:14
    container_name: database
    env_file:
      - .postgres.env
    volumes:
      - psql-data:/var/lib/postgresql/data
    networks:
      - opennms-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
    ports:
      - "5432:5432"

  opennms:
    image: docker.io/opennms/horizon:latest
    container_name: opennms
    init: true
    env_file:
      - .opennms.env
      - .postgres.env
    depends_on:
      database:
        condition: service_healthy
    volumes:
      - opennms-data:/opennms-data
      - opennms-etc:/opt/opennms/etc
      - ./etc-overlay:/opt/opennms-etc-overlay
    command: ["-s"]
    networks:
      - opennms-net
    ports:
      - "8980:8980"
      - "8101:8101"
    healthcheck:
      test: ["CMD", "curl", "-f", "-I", "http://localhost:8980/opennms/login.jsp"]
      interval: 1m
      timeout: 5s
      retries: 3

  py-events:
    build: ./py-events
    container_name: py-events
    depends_on:
      opennms:
        condition: service_healthy
    networks:
      - opennms-net
```

Notice that the whole stack is expressed exactly like a Docker Compose file - this is the
`podman-compose` promise from Section 2: same YAML, no daemon.

> **A real gotcha worth knowing before you rely on this:** `depends_on: condition:
> service_healthy` is a Docker Compose v2 feature, and support for it in
> `podman-compose` has historically been inconsistent depending on which version you
> have installed - some versions just wait for the container to *start*, silently
> ignoring the `condition:` key, rather than actually waiting for the healthcheck to
> pass. Check your installed version first:
> ```bash
> podman-compose version
> ```
> If your version doesn't honor `condition:`, don't trust `depends_on` alone here - add
> an explicit wait step before moving on, either as a one-off command or wired into the
> OpenNMS container's entrypoint. A simple, dependency-free version you can run by hand:
> ```bash
> until podman exec database pg_isready -U postgres; do
>   echo "waiting for database..."
>   sleep 2
> done
> echo "database is ready"
> ```
> Run that between `podman-compose up -d database` and starting the `opennms` service if
> you're bringing the stack up piecemeal, or simply treat the `healthcheck:` blocks as
> documentation of *intent* and manually confirm readiness (Section 11, Step 1's log-tail
> approach) rather than assuming compose enforced the ordering for you.

---

## 11. Step-by-Step: Bring the Stack Up and Trigger a Custom Alarm

### Step 1 - Bring the stack up

```bash
cd opennms-stack
podman-compose up -d
```

Watch OpenNMS come up (first boot takes a few minutes while it initializes the schema):
```bash
podman-compose logs -f opennms
```

### Step 2 - Confirm the web console is reachable

```bash
curl -I http://localhost:8980/opennms/login.jsp
```

Or open `http://localhost:8980/opennms` in a browser - default login `admin` / `admin`
(you'll be prompted to change it).

### Step 3 - Register the custom event file

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
intended - as a local automation/reload tool run from inside the OpenNMS container.

### Step 4 - Fire your custom event from the Python container

```bash
podman exec -it py-events python send_event.py down 1 billing-api
```

You should see:
```
Sent uei.opennms.org/custom/pythonHealthCheck/serviceDown for service='billing-api' on node 1 -- status 204
```

### Step 5 - See it become an alarm

In the OpenNMS web console: **Status → Alarms**. You should see a new **Major** alarm
labeled with your custom description, referencing `billing-api`.

### Step 6 - Clear it

```bash
podman exec -it py-events python send_event.py up 1 billing-api
```

Refresh the Alarms page - because the `clear-key` on the "up" event matches the
`reduction-key` of the "down" alarm exactly, OpenNMS automatically resolves/clears it
rather than creating a second, unrelated alarm. This is the pairwise problem/resolution
mechanic from Section 8 working end-to-end.

### Step 7 - Tear down

```bash
podman-compose down
# add -v to also remove the named volumes (database, opennms data/config) entirely
podman-compose down -v
```

---

## 12. Podman Pods (a Podman-native alternative to compose)

Since your original README specifically flagged Podman pods as worth covering: a **pod**
is a Podman-native concept (borrowed straight from Kubernetes) where multiple containers
share one network namespace - they can reach each other over `localhost`, not just a
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
`http://localhost:8980/opennms/rest/events` here instead of `http://opennms:8980/...` -
a genuinely different networking model from compose's per-container-hostname bridge
network, and one with no Docker equivalent.

You can even export this pod as a Kubernetes YAML file directly - another Podman-only
trick:
```bash
podman generate kube opennms-pod > opennms-pod.yaml
```

---

## 13. Troubleshooting

- **OpenNMS container keeps restarting / healthcheck never passes** - check
  `podman-compose logs opennms`; the most common cause is the database not being ready
  yet (confirm the `depends_on: condition: service_healthy` is actually wired, not just
  `depends_on: [database]`, which only waits for "started," not "ready").
- **`py-events` can't resolve `opennms`** - confirm all three services are on the same
  `networks:` entry in the compose file; a container left off the shared network can't
  resolve other services by name.
- **Custom event never appears / alarm never created** - the most common mistake is
  placing your `<event-file>` reference *below* the catch-all tributary files in
  `eventconf.xml`; incoming events are matched top-to-bottom and stop at the first match,
  so a catch-all earlier in the file can swallow your event first.
- **Changes to `eventconf.xml` don't take effect** - you edited the file but didn't
  reload/restart Eventd; re-run the `send-event.pl ... reloadDaemonConfig` step.
- **Rootless Podman and bind-mounted volume permission errors** - rootless containers
  map container UIDs into a range of "subordinate" UIDs on the host; if you see
  permission-denied errors writing to a bind-mounted directory, check `/etc/subuid` and
  `/etc/subgid` have an entry for your user, or use named volumes (as this guide does)
  instead of host bind-mounts for anything OpenNMS/Postgres need to write to.

---

## 14. Security Notes

- Change the default `admin/admin` OpenNMS login and the default Postgres passwords
  before this touches anything beyond your laptop.
- Don't expose port `8101` (the Karaf SSH shell) or `5432` (Postgres) beyond your local
  network in anything resembling production - bind them to `127.0.0.1:8101:8101` etc., or
  drop the `ports:` mapping entirely and only reach them from other containers on the
  private network.
- Never commit real credentials in `.opennms.env`/`.postgres.env` to version control -
  treat these exactly like the README's original SNMP community-string warning: fine as
  placeholder values in a lab, never in anything shared.
- The REST API in this guide uses HTTP Basic Auth over plain HTTP for simplicity - for
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
| Background service management | `dockerd` (daemon) | none - daemonless |
| Run without root | opt-in, less common | default behavior |
| Group of containers sharing a network namespace | not a first-class concept | **pods** |
| Generate a systemd unit | third-party tooling | `podman generate systemd` |
| Export to Kubernetes YAML | `docker compose convert` (limited) | `podman generate kube` |

---

## 16. Roadmap & Further Reading

Carried over from your original README's roadmap, still relevant on top of this stack:

- Add TLS between the containers (reverse proxy in front of OpenNMS's `:8980`)
- Add a monitoring dashboard on top of this stack (Grafana reading OpenNMS's
  performance data)
- Push these same images to a cloud registry (ECR on AWS / ACR on Azure - see below) and
  run the stack on ECS/AKS instead of locally, as a natural "local containers → cloud
  deployment" next step
- Extend the Python container into a real scheduled health-checker (cron or a Kubernetes
  CronJob) instead of a manually-triggered script, so `send_event.py` actually monitors a
  real service and emits events automatically on state changes

**Reference docs:**
- OpenNMS Horizon documentation - Events & Alarms deep-dive (`docs.opennms.com`)
- OpenNMS REST API reference (`/rest/events`, `/rest/nodes`, `/rest/alarms`)
- Podman documentation - `docs.podman.io`
- `podman-compose` project - GitHub
- PostgreSQL documentation
