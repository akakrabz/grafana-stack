#!/usr/bin/env bash
# Creates a Docker-capable Debian 12 LXC on Proxmox VE and installs
# Docker + the Portainer Agent inside it. Run this ON THE PVE HOST as root.
#
# Usage:  ./create-lxc.sh            (uses the defaults below)
#         CTID=210 STORAGE=local-zfs BRIDGE=vmbr0 IP=192.168.1.50/24 GW=192.168.1.1 ./create-lxc.sh
set -euo pipefail

CTID="${CTID:-200}"
HOSTNAME="${HOSTNAME_CT:-monitoring}"
STORAGE="${STORAGE:-local-lvm}"          # rootfs storage
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
DISK_GB="${DISK_GB:-24}"
CORES="${CORES:-2}"
MEMORY_MB="${MEMORY_MB:-4096}"
SWAP_MB="${SWAP_MB:-512}"
BRIDGE="${BRIDGE:-vmbr0}"
IP="${IP:-dhcp}"                         # e.g. 192.168.1.50/24
GW="${GW:-}"                             # required if IP is static
ROOT_PASSWORD="${ROOT_PASSWORD:-$(openssl rand -base64 18)}"
PORTAINER_AGENT_VERSION="${PORTAINER_AGENT_VERSION:-2.21.4}"

echo ">> Refreshing template list"
pveam update >/dev/null
TEMPLATE="$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -1)"
[ -n "$TEMPLATE" ] || { echo "no debian-12 template found"; exit 1; }
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  echo ">> Downloading $TEMPLATE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

NET="name=eth0,bridge=${BRIDGE},ip=${IP}"
[ -n "$GW" ] && NET="${NET},gw=${GW}"

echo ">> Creating CT $CTID ($HOSTNAME)"
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$HOSTNAME" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "$NET" \
  --password "$ROOT_PASSWORD" \
  --onboot 1 \
  --ostype debian \
  --tags monitoring

pct start "$CTID"
echo ">> Waiting for network"
for i in $(seq 1 30); do
  pct exec "$CTID" -- bash -c 'getent hosts deb.debian.org' >/dev/null 2>&1 && break
  sleep 2
done

echo ">> Installing Docker"
pct exec "$CTID" -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
'

echo ">> Installing Portainer Agent ${PORTAINER_AGENT_VERSION}"
pct exec "$CTID" -- bash -c "
docker volume create portainer_agent_data >/dev/null
docker run -d \
  -p 9001:9001 \
  --name portainer_agent \
  --restart=always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/lib/docker/volumes:/var/lib/docker/volumes \
  -v /:/host \
  portainer/agent:${PORTAINER_AGENT_VERSION}
"

CT_IP="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
DOCKER_GID="$(pct exec "$CTID" -- getent group docker | cut -d: -f3)"

cat <<SUMMARY

============================================================
 LXC $CTID ($HOSTNAME) is up
   IP:              $CT_IP
   root password:   $ROOT_PASSWORD
   Portainer agent: $CT_IP:9001
   docker GID:      $DOCKER_GID   (set DOCKER_GID in the stack env)
------------------------------------------------------------
 Next: in Portainer BE -> Environments -> Add -> Docker Standalone
       -> Agent, URL = $CT_IP:9001
============================================================
SUMMARY
