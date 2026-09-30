#!/usr/bin/env bash
# Installs Telegraf + IPMI/SMART/sensors tooling on the Proxmox VE host and
# points it at the stack's InfluxDB. Run ON THE PVE HOST as root.
#
# Usage:  INFLUX_URL=http://192.168.1.50:8086 INFLUX_TOKEN=xxxx ./install-pve-host.sh
set -euo pipefail

INFLUX_URL="${INFLUX_URL:?set INFLUX_URL, e.g. http://192.168.1.50:8086}"
INFLUX_TOKEN="${INFLUX_TOKEN:?set INFLUX_TOKEN}"
INFLUX_ORG="${INFLUX_ORG:-homelab}"
INFLUX_BUCKET="${INFLUX_BUCKET:-proxmox}"
HERE="$(cd "$(dirname "$0")" && pwd)"

export DEBIAN_FRONTEND=noninteractive
echo ">> InfluxData apt repo"
apt-get install -y -qq curl gnupg ca-certificates
curl -fsSL https://repos.influxdata.com/influxdata-archive.key \
  | gpg --dearmor -o /etc/apt/keyrings/influxdata-archive.gpg
echo "deb [signed-by=/etc/apt/keyrings/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main" \
  > /etc/apt/sources.list.d/influxdata.list
apt-get update -qq
echo ">> Installing telegraf + ipmitool + smartmontools + lm-sensors"
apt-get install -y -qq telegraf ipmitool smartmontools lm-sensors

echo ">> Loading IPMI kernel modules"
for m in ipmi_devintf ipmi_si ipmi_msghandler; do modprobe "$m" || true; echo "$m"; done > /etc/modules-load.d/ipmi.conf
sensors-detect --auto >/dev/null 2>&1 || true

echo ">> sudoers for telegraf (ipmitool / smartctl / nvme)"
cat > /etc/sudoers.d/telegraf <<'SUDO'
Cmnd_Alias IPMITOOL = /usr/bin/ipmitool *
Cmnd_Alias SMARTCTL = /usr/sbin/smartctl *
Cmnd_Alias NVME     = /usr/sbin/nvme *
telegraf ALL=(root) NOPASSWD: IPMITOOL, SMARTCTL, NVME
Defaults!IPMITOOL !logfile, !syslog, !pam_session
Defaults!SMARTCTL !logfile, !syslog, !pam_session
Defaults!NVME !logfile, !syslog, !pam_session
SUDO
chmod 0440 /etc/sudoers.d/telegraf
usermod -aG video telegraf 2>/dev/null || true   # nvidia device access on some setups

echo ">> Writing config"
install -m 0644 "$HERE/telegraf-pve-host.conf" /etc/telegraf/telegraf.conf
cat > /etc/default/telegraf <<ENV
INFLUX_URL=${INFLUX_URL}
INFLUX_TOKEN=${INFLUX_TOKEN}
INFLUX_ORG=${INFLUX_ORG}
INFLUX_BUCKET=${INFLUX_BUCKET}
ENV
chmod 0600 /etc/default/telegraf

if ! command -v nvidia-smi >/dev/null; then
  echo ">> nvidia-smi not found: disabling [[inputs.nvidia_smi]] (install the NVIDIA driver, then re-enable)"
  sed -i 's/^\[\[inputs.nvidia_smi\]\]/# [[inputs.nvidia_smi]]/; s/^  bin_path = "\/usr\/bin\/nvidia-smi"/#   bin_path = "\/usr\/bin\/nvidia-smi"/; s/^  timeout = "10s"$/#   timeout = "10s"/' /etc/telegraf/telegraf.conf
fi

echo ">> Test run"
sudo -u telegraf telegraf --config /etc/telegraf/telegraf.conf --test --input-filter ipmi_sensor:sensors:nvidia_smi 2>&1 | tail -20 || true

systemctl enable --now telegraf
systemctl restart telegraf
sleep 3
systemctl --no-pager status telegraf | head -5
echo
echo "Done. Check 'journalctl -u telegraf -f' for plugin errors."
echo "If SMART shows nothing and disks are behind the PERC: run 'smartctl --scan' and set 'devices' in inputs.smart."
