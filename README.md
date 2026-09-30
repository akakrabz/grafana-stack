# grafana-stack — Proxmox VE monitoring (InfluxDB 2 + Grafana)

A monitoring stack for Proxmox VE that deploys straight from this git repo via
**Portainer** (Business Edition git stacks). Runs in any Docker host — the intended
setup is an LXC container on the Proxmox node itself running the Portainer Agent.

Nothing here is hardware-specific. Base metrics come from Proxmox itself; hardware
extras (BMC/IPMI, lm-sensors, SMART, NVIDIA/AMD GPU) are optional modules that the
host installer enables only when they actually work on your machine.

```
Hypervisor host (Proxmox VE)                      Docker host (LXC + Portainer Agent)
┌──────────────────────────────────┐              ┌─────────────────────────────────────┐
│ PVE metric server (built-in) ────┼──push───────▶│ InfluxDB 2.x  :8086                 │
│   nodes / VMs / CTs / storage    │              │      ▲  Flux                        │
│                                  │              │ Grafana       :3000 (provisioned)   │
│ Telegraf (optional) ─────────────┼──push───────▶│ Telegraf (stack/docker metrics)     │
│   base OS + [ipmi][sensors]      │              └─────────────────────────────────────┘
│             [smart][nvidia][amd] │
└──────────────────────────────────┘
```

## What you get

| Source | Needs | Data | Dashboard |
|---|---|---|---|
| PVE built-in metric server | nothing on the host | node CPU/RAM/load/IO-wait/NICs; every VM & CT (CPU, RAM, net, disk I/O, uptime); storage pools | **Proxmox Overview** |
| Telegraf base | Telegraf on host | host CPU breakdown, disk throughput/IOPS, kernel/thermal zones | **Host Hardware** |
| module `ipmi` | working `ipmitool` + `/dev/ipmi0` | BMC temps, fans, PSU watts, voltages, sensor status | Host Hardware |
| module `sensors` | lm-sensors finds chips | core/board temps | Host Hardware |
| module `smart` | `smartctl --scan` sees disks | disk temps, health, error counters | Host Hardware |
| module `nvidia` | `nvidia-smi` works (any driver age) | util, VRAM, temp, clocks, power/fan where reported | **GPU** |
| module `amd` | `rocm-smi` | same, AMD | GPU (needs panel tweaks) |
| Telegraf in stack | – | Docker container metrics of the stack itself | (Explore) |

Panels whose module isn't enabled simply stay empty; nothing breaks.

## Repo layout

```
docker-compose.yml                 the stack Portainer deploys
.env.example                       every variable the stack needs
grafana/provisioning/              datasource + dashboard provider (auto-loaded)
grafana/dashboards/*.json          Proxmox Overview, Host Hardware, GPU
lxc/setup-docker-host.sh           run inside the container: Docker + Portainer Agent
proxmox/create-lxc.sh              OPTIONAL: creates the container from the PVE shell
proxmox/configure-metric-server.sh registers InfluxDB as PVE's metric server
telegraf/host/install.sh           host Telegraf installer with hardware probing
telegraf/host/telegraf.conf        base host config (always on)
telegraf/host/optional/*.conf      ipmi / sensors / smart / nvidia / amd modules
telegraf/stack/telegraf.conf       Telegraf inside the stack (docker metrics)
```

---

## Setup

### Step 1 — Create the container

Any Debian 12/13 (or Ubuntu) LXC works. Docker inside an LXC needs **nesting**; these
are the settings that matter:

| Setting | Value | Why |
|---|---|---|
| Template | `debian-13-standard` (12 also fine) | `setup-docker-host.sh` detects the codename |
| Unprivileged | **yes** | works fine with nesting; safer |
| Features | **nesting = 1**, **keyctl = 1** | required for dockerd / containerd |
| Resources | 2 cores, 4 GB RAM, 20–30 GB disk | InfluxDB + Grafana are light; disk grows with retention |
| Network | static IP or DHCP reservation | Portainer, PVE and Telegraf all point at this IP |
| Start at boot | yes | |

**PVE web UI:** *Create CT* → tick *Unprivileged* → pick template → after creation go to
*Options → Features* and enable *Nesting* and *keyctl* → start it.

**PVE shell equivalent** (or just run `proxmox/create-lxc.sh`, which does steps 1–2 for you):
```bash
pct create 200 local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst \
  --hostname monitoring --unprivileged 1 --features nesting=1,keyctl=1 \
  --cores 2 --memory 4096 --rootfs local-lvm:24 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp --onboot 1 --password
pct start 200
```

### Step 2 — Inside the container: clone this repo and run the helper

```bash
apt-get update && apt-get install -y git
git clone https://github.com/akakrabz/grafana-stack.git /opt/grafana-stack
/opt/grafana-stack/lxc/setup-docker-host.sh
```
The script installs Docker CE + compose plugin (Debian 12/13, Ubuntu), starts the
**Portainer Agent on :9001**, creates `/opt/stacks`, and prints the three values you need
next: the container IP, the **docker GID**, and the stacks path. It is idempotent.

> Pin the agent to your Portainer server's version with `PORTAINER_AGENT_VERSION=2.27.1`
> if the versions must match (Portainer warns when they don't).

### Step 3 — Put the repo into Portainer

1. **Environments → Add environment → Docker Standalone → Agent**
   URL = `CT_IP:9001`. Connect.
2. **Stacks → Add stack → Repository**
   - Repository URL: `https://github.com/akakrabz/grafana-stack` (add credentials if private)
   - Reference: `refs/heads/main` — Compose path: `docker-compose.yml`
   - **Enable relative path volumes** (BE feature) — *required*: the `./grafana/...` and
     `./telegraf/...` mounts must resolve to the cloned repo on the agent host.
     Local filesystem path: `/opt/stacks`
   - **GitOps updates**: polling (e.g. 5 min) or a webhook → every `git push` redeploys
   - **Environment variables**: *Advanced mode* → paste `.env.example` → set real values.
     `INFLUXDB_ADMIN_TOKEN` = `openssl rand -hex 32`. `DOCKER_GID` = value from step 2.
3. **Deploy the stack.** Grafana: `http://CT_IP:3000` — datasource and all dashboards are
   already there (folder *Proxmox*). InfluxDB UI: `http://CT_IP:8086`.

### Step 4 — Point Proxmox at InfluxDB (on the PVE host, once)

```bash
git clone https://github.com/akakrabz/grafana-stack.git /opt/grafana-stack   # if not already
INFLUX_HOST=CT_IP INFLUX_TOKEN=<INFLUXDB_ADMIN_TOKEN> /opt/grafana-stack/proxmox/configure-metric-server.sh
```
UI equivalent: *Datacenter → Metric Server → Add → InfluxDB*: server = CT_IP, port 8086,
protocol **HTTP**, organization / bucket / token from the stack env. Data shows within ~30 s.
This gives you the whole *Proxmox Overview* dashboard with **no agent on the host**.

### Step 5 (optional) — Hardware & GPU metrics: Telegraf on the host

```bash
/opt/grafana-stack/telegraf/host/install.sh --probe        # dry run: shows what would be enabled
INFLUX_URL=http://CT_IP:8086 INFLUX_TOKEN=<token> /opt/grafana-stack/telegraf/host/install.sh
```
The installer adds Telegraf plus `ipmitool`, `smartmontools`, `lm-sensors`, then **probes**
each module and writes only the working ones to `/etc/telegraf/telegraf.d/`:

| Module | Enabled when | If it's off |
|---|---|---|
| `ipmi` | `/dev/ipmi0` exists **and** `ipmitool sensor` returns rows | BMC unreachable locally (dead/odd BMC NIC, no driver). Either live without it, or poll the BMC over the network: set `servers = ["user:pass@lanplus(BMC_IP)"]` in `optional/ipmi.conf` and `ENABLE=ipmi` |
| `sensors` | `sensors` prints readings | run `sensors-detect` manually; some boards expose nothing |
| `smart` | `smartctl --scan` lists disks | disks behind a RAID controller: set `devices = ["/dev/sda -d megaraid,0", …]` and `ENABLE=smart` |
| `nvidia` | `nvidia-smi -q -x` succeeds | install/repair the NVIDIA driver; legacy branches (390/470) work — fields the card doesn't report (power on bus-powered cards, fan on passive ones) are just absent |
| `amd` | `/opt/rocm/bin/rocm-smi` runs | install ROCm |

Force decisions with `ENABLE=ipmi,smart` / `DISABLE=nvidia`. Re-run any time; it's
idempotent. Check `journalctl -u telegraf -f` for plugin errors.

**GPU passed through to a VM?** The host can't see it. Install Telegraf inside that VM with
just `telegraf/host/telegraf.conf` + `optional/nvidia.conf` (same installer works in a VM).

---

## Day-2

- **Update**: edit → commit → push. Portainer redeploys on poll/webhook. Dashboard JSON is
  re-read by Grafana every 30 s, so dashboard edits don't even need a redeploy. Dashboards
  edited in the UI: *Share → Export → JSON* → commit into `grafana/dashboards/`.
- **Second host / cluster**: point additional PVE nodes' metric servers (and Telegraf) at
  the same InfluxDB — every dashboard has a node/host selector. Or deploy the repo as a
  second stack with a different env.
- **Retention**: `INFLUXDB_RETENTION` (default 30d) only applies on first init; change it
  later in the InfluxDB UI (*Load Data → Buckets*).
- **Local test without Portainer**: `cp .env.example .env`, edit, `docker compose up -d`.

## Troubleshooting

| Symptom | Check |
|---|---|
| Stack fails: `INFLUXDB_ADMIN_PASSWORD` unset | env vars not pasted in Portainer |
| Grafana: "datasource not found" / mounts empty | *relative path volumes* not enabled, or wrong local filesystem path |
| Proxmox Overview empty | `pvesh get /cluster/metrics/server`; token/org/bucket match the stack env; port 8086 reachable from the PVE host |
| Docker won't start in the LXC | `nesting=1` missing (*Options → Features*) |
| Telegraf sends nothing | `systemctl status telegraf`, then `telegraf --config /etc/telegraf/telegraf.conf --config-directory /etc/telegraf/telegraf.d --test` |
| GPU panel empty on old driver | `nvidia-smi -q -x \| head`; if it errors, the driver isn't loaded for that card |
