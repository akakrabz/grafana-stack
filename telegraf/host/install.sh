#!/usr/bin/env bash
# Installs Telegraf on the HYPERVISOR HOST (Proxmox / any Debian-Ubuntu box) and
# enables only the hardware modules that actually work here. Safe to re-run.
#
#   INFLUX_URL=http://192.168.1.50:8086 INFLUX_TOKEN=xxxx ./install.sh
#   ./install.sh --probe          # just show what would be enabled, change nothing
#   ENABLE=ipmi,nvidia ./install.sh   # force modules on regardless of probe
#   DISABLE=smart ./install.sh        # force modules off
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PROBE_ONLY=0; [ "${1:-}" = "--probe" ] && PROBE_ONLY=1

INFLUX_ORG="${INFLUX_ORG:-homelab}"
INFLUX_BUCKET="${INFLUX_BUCKET:-proxmox}"
if [ "$PROBE_ONLY" = 0 ]; then
  : "${INFLUX_URL:?set INFLUX_URL, e.g. http://192.168.1.50:8086}"
  : "${INFLUX_TOKEN:?set INFLUX_TOKEN (INFLUXDB_ADMIN_TOKEN from the stack)}"
fi
export DEBIAN_FRONTEND=noninteractive
log()  { printf '%s\n' ">> $*"; }
ok()   { printf '   \e[32m[on ]\e[0m %s\n' "$*"; }
skip() { printf '   \e[33m[off]\e[0m %s\n' "$*"; }

# ---------------------------------------------------------------- packages
if [ "$PROBE_ONLY" = 0 ]; then
  log "InfluxData apt repo + packages"
  apt-get install -y -qq curl gnupg ca-certificates >/dev/null
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://repos.influxdata.com/influxdata-archive.key | gpg --dearmor --yes -o /etc/apt/keyrings/influxdata-archive.gpg
  echo "deb [signed-by=/etc/apt/keyrings/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main" > /etc/apt/sources.list.d/influxdata.list
  apt-get update -qq
  # hardware tools are cheap; install them all, the probe decides what gets used
  apt-get install -y -qq telegraf ipmitool smartmontools lm-sensors >/dev/null
  for m in ipmi_devintf ipmi_si ipmi_msghandler; do modprobe "$m" 2>/dev/null || true; done
  printf 'ipmi_msghandler\nipmi_devintf\nipmi_si\n' > /etc/modules-load.d/ipmi.conf
  yes "" | sensors-detect >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- probes
declare -A WANT
probe_ipmi() {
  command -v ipmitool >/dev/null || return 1
  [ -e /dev/ipmi0 ] || [ -e /dev/ipmi/0 ] || [ -e /dev/ipmidev/0 ] || return 1
  timeout 25 ipmitool sensor 2>/dev/null | grep -q '|' 
}
probe_sensors() {
  command -v sensors >/dev/null || return 1
  sensors 2>/dev/null | grep -Eq '°C|RPM|V$|W$'
}
probe_smart() {
  command -v smartctl >/dev/null || return 1
  smartctl --scan 2>/dev/null | grep -q '^/dev'
}
probe_nvidia() {
  command -v nvidia-smi >/dev/null || return 1
  timeout 15 nvidia-smi -q -x 2>/dev/null | grep -q '<gpu '
}
probe_amd() {
  [ -x /opt/rocm/bin/rocm-smi ] || return 1
  timeout 15 /opt/rocm/bin/rocm-smi >/dev/null 2>&1
}

log "Probing hardware modules"
for mod in ipmi sensors smart nvidia amd; do
  if "probe_$mod"; then WANT[$mod]=1; else WANT[$mod]=0; fi
done
# manual overrides
IFS=, read -ra en <<< "${ENABLE:-}";  for m in "${en[@]}";  do [ -n "$m" ] && WANT[$m]=1; done
IFS=, read -ra dis <<< "${DISABLE:-}"; for m in "${dis[@]}"; do [ -n "$m" ] && WANT[$m]=0; done

reason() {
  case "$1" in
    ipmi)    echo "ipmitool + /dev/ipmi0 + 'ipmitool sensor' returning rows (BMC/iDRAC/iLO)";;
    sensors) echo "lm-sensors reporting temps/fans (run sensors-detect if not)";;
    smart)   echo "smartctl --scan finding disks (RAID-hidden disks need manual 'devices')";;
    nvidia)  echo "nvidia-smi -q -x succeeding (driver loaded)";;
    amd)     echo "/opt/rocm/bin/rocm-smi present";;
  esac
}
for mod in ipmi sensors smart nvidia amd; do
  if [ "${WANT[$mod]}" = 1 ]; then ok "$mod"; else skip "$mod  - needs: $(reason "$mod")"; fi
done
[ "$PROBE_ONLY" = 1 ] && exit 0

# ---------------------------------------------------------------- privileges
log "sudoers for telegraf"
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
getent group video >/dev/null && usermod -aG video telegraf || true
getent group render >/dev/null && usermod -aG render telegraf || true

# ---------------------------------------------------------------- config
log "Writing /etc/telegraf"
install -m 0644 "$HERE/telegraf.conf" /etc/telegraf/telegraf.conf
mkdir -p /etc/telegraf/telegraf.d
rm -f /etc/telegraf/telegraf.d/{ipmi,sensors,smart,nvidia,amd}.conf
for mod in ipmi sensors smart nvidia amd; do
  [ "${WANT[$mod]}" = 1 ] && install -m 0644 "$HERE/optional/$mod.conf" "/etc/telegraf/telegraf.d/$mod.conf"
done
cat > /etc/default/telegraf <<ENV
INFLUX_URL=${INFLUX_URL}
INFLUX_TOKEN=${INFLUX_TOKEN}
INFLUX_ORG=${INFLUX_ORG}
INFLUX_BUCKET=${INFLUX_BUCKET}
ENV
chmod 0600 /etc/default/telegraf

log "Dry run of enabled inputs"
set +e
sudo -u telegraf env $(cat /etc/default/telegraf | xargs) \
  telegraf --config /etc/telegraf/telegraf.conf --config-directory /etc/telegraf/telegraf.d --test 2>&1 \
  | grep -E '^(> (ipmi_sensor|sensors|smart_device|nvidia_smi|amd_rocm_smi)|E!)' | cut -c1-160 | sort -u | head -20
set -e

systemctl enable --now telegraf >/dev/null
systemctl restart telegraf
sleep 3
systemctl --no-pager --lines=0 status telegraf | sed -n '1,3p'
echo
echo "Done. Enabled modules: $(for m in ipmi sensors smart nvidia amd; do [ "${WANT[$m]}" = 1 ] && printf '%s ' "$m"; done)"
echo "Logs: journalctl -u telegraf -f    Re-probe: $0 --probe    Force: ENABLE=ipmi $0"
