# grafana-stack — Proxmox VE monitoring (InfluxDB 2 + Grafana)

Git-deployable monitoring stack for a Proxmox VE host (Dell R710 + GPU), built to be
cloned and deployed straight from **Portainer Business Edition** onto a Docker LXC
running the Portainer Agent.

```
Proxmox host (R710)                          LXC "monitoring" (Docker + Portainer Agent)
┌──────────────────────────────┐             ┌─────────────────────────────────────┐
│ PVE metric server ───────────┼──push──────▶│ InfluxDB 2.x  :8086                 │
│   nodes / VMs / CTs / storage│             │     ▲                               │
│                              │             │     │ Flux                          │
│ Telegraf (host) ─────────────┼──push──────▶│ Grafana       :3000  (provisioned)  │
│   IPMI, SMART, sensors, GPU  │             │ Telegraf (docker metrics of the LXC)│
└──────────────────────────────┘             └─────────────────────────────────────┘
```

## What gets monitored

| Source | Data | Dashboard |
|---|---|---|
| **PVE built-in metric server** (no agent needed) | Node CPU / RAM / load / IO-wait / NICs, every VM & CT (CPU, RAM, net, disk I/O, uptime), storage pool usage | `Proxmox Overview` |
| **Telegraf on the PVE host** – `ipmi_sensor` (iDRAC6) | Inlet/ambient temps, fan RPM, PSU power draw, voltages, sensor status | `R710 Hardware` |
| Telegraf – `smart` | Disk temps, SMART health, error counters | `R710 Hardware` |
| Telegraf – `sensors` / `temp` / `cpu` / `diskio` | Core temps, host CPU breakdown, disk throughput & IOPS | `R710 Hardware` |
| Telegraf – `nvidia_smi` (or `amd_rocm_smi`) | GPU util, VRAM, temp, power, clocks, fan | `GPU` |
| Telegraf in the stack – `docker` | Container CPU/mem/net of the stack itself | (use Explore) |

## Repo layout

```
docker-compose.yml               stack file used by Portainer
.env.example                     every variable the stack needs
grafana/provisioning/            datasource + dashboard provider (auto-loaded)
grafana/dashboards/*.json        the three dashboards
telegraf/telegraf-stack.conf     Telegraf inside the stack (docker metrics)
telegraf/telegraf-pve-host.conf  Telegraf on the PVE host (hardware/GPU)
telegraf/install-pve-host.sh     installs + configures host Telegraf
proxmox/create-lxc.sh            creates the Docker LXC + Portainer Agent
proxmox/configure-metric-server.sh  points PVE's metric server at InfluxDB
```

## Deploy (first time)

### 1. Create the LXC on the Proxmox host
```bash
git clone <this repo> && cd grafana-stack/proxmox
CTID=200 STORAGE=local-lvm IP=192.168.1.50/24 GW=192.168.1.1 ./create-lxc.sh
```
Unprivileged Debian 12 CT with `nesting=1,keyctl=1`, Docker CE and `portainer/agent` on
`:9001`. The script prints the CT IP, root password and the **docker GID** (needed below).

### 2. Add the environment in Portainer BE
*Environments → Add environment → Docker Standalone → Agent* → `CT_IP:9001`.

### 3. Deploy the stack from git
*Stacks → Add stack → Repository*
- Repository URL: this repo, reference `refs/heads/main`, compose path `docker-compose.yml`
- **Enable relative path volumes** (Portainer BE feature) — required so the
  `./grafana/...` and `./telegraf/...` bind mounts resolve to the cloned repo on the agent.
  Local filesystem path: e.g. `/opt/stacks`
- GitOps updates: enable polling (e.g. 5m) or a webhook so every `git push` redeploys
- Environment variables: paste `.env.example` and set real values. Generate the token with
  `openssl rand -hex 32`. Set `DOCKER_GID` to the value printed by step 1.

Deploy. Grafana comes up at `http://CT_IP:3000` with the InfluxDB datasource and all
three dashboards already provisioned (folder **Proxmox**). Home dashboard = Proxmox Overview.

### 4. Point Proxmox at InfluxDB (on the PVE host)
```bash
INFLUX_HOST=192.168.1.50 INFLUX_TOKEN=<INFLUXDB_ADMIN_TOKEN> ./proxmox/configure-metric-server.sh
```
Equivalent UI path: *Datacenter → Metric Server → Add → InfluxDB* (protocol HTTP, port 8086,
organization/bucket/token from the stack env). Data appears within ~30 s.

### 5. Hardware + GPU metrics (on the PVE host)
```bash
INFLUX_URL=http://192.168.1.50:8086 INFLUX_TOKEN=<INFLUXDB_ADMIN_TOKEN> ./telegraf/install-pve-host.sh
```
Installs Telegraf from InfluxData's repo plus `ipmitool`, `smartmontools`, `lm-sensors`,
loads the IPMI kernel modules for the iDRAC6, and adds a sudoers rule so Telegraf can run
`ipmitool` / `smartctl`. `journalctl -u telegraf -f` shows any plugin errors.

## Notes for the R710

- **IPMI**: the iDRAC6 exposes `Ambient Temp`, `FAN1–6 RPM`, `System Level` (input watts),
  voltages, PSU and intrusion status. The dashboard's stat panels match on those names;
  check *IPMI sensor status* table for the exact names if a panel is empty.
- **SMART behind a PERC H700**: disks are hidden behind the RAID controller. Run
  `smartctl --scan` and set `devices = ["/dev/sda -d megaraid,0", ...]` in
  `telegraf/telegraf-pve-host.conf` (`[[inputs.smart]]`).
- **GPU**: `nvidia_smi` needs the proprietary NVIDIA driver on the host (`nvidia-smi` on
  PATH). The install script comments the plugin out if `nvidia-smi` is missing. For an AMD
  card, swap in the `amd_rocm_smi` block (already in the config, commented). If the GPU is
  passed through to a VM, run Telegraf **inside that VM** with just the GPU input instead.
- **Old CPUs (Xeon 55xx/56xx)**: `sensors-detect` finds `coretemp`; nothing else is needed.

## Updating

Edit, commit, push. Portainer redeploys on its next poll / webhook. Dashboards JSON is
re-read by Grafana every 30 s (provider `updateIntervalSeconds`), so dashboard-only
changes don't even need a redeploy. Dashboards edited in the UI can be exported
(*Share → Export → JSON*) and committed back to `grafana/dashboards/`.

## Cloning to another host

Only the environment variables are host-specific. Deploy the same repo as a second
Portainer stack with a different env, then point the other PVE node's metric server and
Telegraf at it — or point several nodes at one InfluxDB; every dashboard has a `node` /
`host` selector.

## Local test without Portainer
```bash
cp .env.example .env   # edit values
docker compose up -d
```
