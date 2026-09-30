#!/usr/bin/env bash
# Registers the stack's InfluxDB as a Proxmox "External Metric Server".
# PVE will then push node / VM / CT / storage metrics every ~10s.
# Run ON THE PVE HOST as root, after the stack is running.
#
# Usage:  INFLUX_HOST=192.168.1.50 INFLUX_TOKEN=xxxx ./configure-metric-server.sh
set -euo pipefail

NAME="${NAME:-influxdb-monitoring}"
INFLUX_HOST="${INFLUX_HOST:?set INFLUX_HOST (IP/hostname of the monitoring LXC)}"
INFLUX_PORT="${INFLUX_PORT:-8086}"
INFLUX_ORG="${INFLUX_ORG:-homelab}"
INFLUX_BUCKET="${INFLUX_BUCKET:-proxmox}"
INFLUX_TOKEN="${INFLUX_TOKEN:?set INFLUX_TOKEN (INFLUXDB_ADMIN_TOKEN from the stack)}"

if pvesh get /cluster/metrics/server --output-format json | grep -q "\"id\":\"${NAME}\""; then
  echo ">> Updating existing metric server '${NAME}'"
  pvesh set "/cluster/metrics/server/${NAME}" \
    --server "$INFLUX_HOST" --port "$INFLUX_PORT" \
    --organization "$INFLUX_ORG" --bucket "$INFLUX_BUCKET" --token "$INFLUX_TOKEN" \
    --influxdbproto http --disable 0
else
  echo ">> Creating metric server '${NAME}'"
  pvesh create /cluster/metrics/server/"${NAME}" \
    --type influxdb \
    --server "$INFLUX_HOST" --port "$INFLUX_PORT" \
    --organization "$INFLUX_ORG" --bucket "$INFLUX_BUCKET" --token "$INFLUX_TOKEN" \
    --influxdbproto http \
    --max-body-size 25000000 \
    --timeout 5
fi

echo ">> Verifying data arrives (waiting 20s)..."
sleep 20
curl -fsS "http://${INFLUX_HOST}:${INFLUX_PORT}/api/v2/query?org=${INFLUX_ORG}" \
  -H "Authorization: Token ${INFLUX_TOKEN}" \
  -H "Content-Type: application/vnd.flux" \
  -H "Accept: application/csv" \
  --data 'from(bucket:"'"${INFLUX_BUCKET}"'") |> range(start:-2m) |> filter(fn:(r)=> r._measurement=="cpustat") |> group(columns:["host"]) |> distinct(column:"host") |> keep(columns:["_value"])' \
  | grep -v '^$' | tail -n +2 | cut -d, -f4 | sort -u | sed 's/^/   node reporting: /' \
  || echo "   (no data yet - check Datacenter -> Metric Server in the PVE UI)"
