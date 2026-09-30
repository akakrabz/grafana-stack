#!/usr/bin/env bash
# OPTIONAL shortcut: creates the Docker-capable LXC on a Proxmox host and runs
# lxc/setup-docker-host.sh inside it. Equivalent to the manual steps in the README.
# Run ON THE PVE HOST as root.
#
#   CTID=200 STORAGE=local-lvm IP=192.168.1.50/24 GW=192.168.1.1 ./create-lxc.sh
#   (IP defaults to dhcp; template defaults to newest Debian 13, falls back to 12)
set -euo pipefail

CTID="${CTID:-200}"
CT_HOSTNAME="${CT_HOSTNAME:-monitoring}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
DEBIAN_VERSION="${DEBIAN_VERSION:-13}"
DISK_GB="${DISK_GB:-24}"
CORES="${CORES:-2}"
MEMORY_MB="${MEMORY_MB:-4096}"
SWAP_MB="${SWAP_MB:-512}"
BRIDGE="${BRIDGE:-vmbr0}"
IP="${IP:-dhcp}"
GW="${GW:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-$(openssl rand -base64 18)}"
REPO_URL="${REPO_URL:-https://github.com/akakrabz/grafana-stack.git}"
REPO_REF="${REPO_REF:-main}"

echo ">> Template"
pveam update >/dev/null
pick_template() { pveam available --section system | awk -v v="debian-$1-standard" '$2 ~ v {print $2}' | sort -V | tail -1; }
TEMPLATE="$(pick_template "$DEBIAN_VERSION")"
[ -n "$TEMPLATE" ] || { echo "   no Debian $DEBIAN_VERSION template, trying 12"; TEMPLATE="$(pick_template 12)"; }
[ -n "$TEMPLATE" ] || { echo "no debian template available"; exit 1; }
pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE" || pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
echo "   using $TEMPLATE"

NET="name=eth0,bridge=${BRIDGE},ip=${IP}"; [ -n "$GW" ] && NET="${NET},gw=${GW}"

echo ">> Creating CT $CTID ($CT_HOSTNAME)"
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$CT_HOSTNAME" --unprivileged 1 --features nesting=1,keyctl=1 \
  --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB" \
  --rootfs "${STORAGE}:${DISK_GB}" --net0 "$NET" \
  --password "$ROOT_PASSWORD" --onboot 1 --ostype debian --tags monitoring
pct start "$CTID"
for i in $(seq 1 30); do pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break; sleep 2; done

echo ">> Cloning repo inside the CT and running lxc/setup-docker-host.sh"
pct exec "$CTID" -- bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq git
git clone --branch '$REPO_REF' --depth 1 '$REPO_URL' /opt/grafana-stack
/opt/grafana-stack/lxc/setup-docker-host.sh
"
echo
echo "CT $CTID root password: $ROOT_PASSWORD"
