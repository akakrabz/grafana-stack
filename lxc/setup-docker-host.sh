#!/usr/bin/env bash
# Run INSIDE the freshly created LXC (or any Debian/Ubuntu box) as root.
# Installs Docker CE + compose plugin and the Portainer Agent. Idempotent.
#
#   apt-get update && apt-get install -y git
#   git clone https://github.com/akakrabz/grafana-stack.git /opt/grafana-stack
#   /opt/grafana-stack/lxc/setup-docker-host.sh
#
# Tested targets: Debian 12 (bookworm), Debian 13 (trixie), Ubuntu 22.04/24.04.
set -euo pipefail

PORTAINER_AGENT_VERSION="${PORTAINER_AGENT_VERSION:-latest}"   # e.g. 2.27.1 to pin
AGENT_PORT="${AGENT_PORT:-9001}"
STACKS_DIR="${STACKS_DIR:-/opt/stacks}"        # Portainer "local filesystem path" for git stacks

. /etc/os-release
DISTRO="$ID"                 # debian | ubuntu
CODENAME="${VERSION_CODENAME:-}"
case "$DISTRO" in
  debian|ubuntu) ;;
  *) echo "Unsupported distro: $DISTRO (script targets Debian/Ubuntu)"; exit 1 ;;
esac
export DEBIAN_FRONTEND=noninteractive

echo ">> [1/5] Sanity: is nesting enabled? (Docker needs it inside LXC)"
if [ -f /proc/1/environ ] && grep -qa container=lxc /proc/1/environ; then
  if ! mount | grep -q '^cgroup2 on /sys/fs/cgroup' ; then
    echo "   WARNING: cgroup2 not mounted - container may lack nesting=1. Continuing anyway."
  fi
fi

echo ">> [2/5] Base packages"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git

echo ">> [3/5] Docker CE ($DISTRO $CODENAME)"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DISTRO} ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
if ! apt-get update -qq 2>/dev/null; then
  # very new release without a docker repo yet -> fall back to previous stable codename
  FALLBACK=bookworm; [ "$DISTRO" = ubuntu ] && FALLBACK=noble
  echo "   no Docker repo for '$CODENAME' yet, falling back to '$FALLBACK' packages"
  sed -i "s/ ${CODENAME} stable/ ${FALLBACK} stable/" /etc/apt/sources.list.d/docker.list
  apt-get update -qq
fi
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker info >/dev/null 2>&1 || { echo "Docker daemon failed to start. In LXC this is almost always nesting=1 missing."; exit 1; }

echo ">> [4/5] Portainer Agent"
if docker ps -a --format '{{.Names}}' | grep -qx portainer_agent; then
  echo "   portainer_agent exists - leaving it alone (docker rm -f portainer_agent to reinstall)"
else
  docker volume create portainer_agent_data >/dev/null
  docker run -d \
    -p "${AGENT_PORT}:9001" \
    --name portainer_agent \
    --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /var/lib/docker/volumes:/var/lib/docker/volumes \
    -v /:/host \
    "portainer/agent:${PORTAINER_AGENT_VERSION}"
fi

echo ">> [5/5] Stacks directory for Portainer relative-path volumes"
mkdir -p "$STACKS_DIR"

IP="$(hostname -I | awk '{print $1}')"
DOCKER_GID="$(getent group docker | cut -d: -f3)"
cat <<SUMMARY

============================================================
 Docker host ready
   Portainer agent : ${IP}:${AGENT_PORT}
   docker GID      : ${DOCKER_GID}      -> stack env DOCKER_GID
   stacks dir      : ${STACKS_DIR}      -> stack "local filesystem path"
------------------------------------------------------------
 Next: Portainer -> Environments -> Add -> Docker Standalone -> Agent
       URL = ${IP}:${AGENT_PORT}
       then Stacks -> Add stack -> Repository (see README step 3)
============================================================
SUMMARY
