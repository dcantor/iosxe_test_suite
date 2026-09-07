#!/usr/bin/env bash
# Brings up the whole hub-and-spoke testbed from cold.
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env

echo "==> Building day0 ISOs"
for r in $ROUTERS; do ./make-day0.sh "$r"; done

echo "==> Starting routers (hub first: it owns the listening end of every link)"
./start-vm.sh "$HUB"
sleep 5
for r in $SPOKES; do ./start-vm.sh "$r"; done

echo "==> Waiting for routers to boot"
pids=()
for r in $ROUTERS; do ./wait-for-boot.sh "$r" & pids+=($!); done
for p in "${pids[@]}"; do wait "$p"; done

echo "==> Provisioning licence, IPsec, BGP, NAT and NTP"
./.venv/bin/python -u tools/provision.py all

echo "==> Starting the Linux hosts and the NMS"
for h in $HOSTS; do ./start-host.sh "$h"; done
./start-nms.sh

echo "==> Configuring the Linux hosts"
./.venv/bin/python -u tools/host_provision.py

echo "==> Waiting for the NMS (cloud-init installs the net-snmp tools)"
./.venv/bin/python -u tools/nms_provision.py

echo
echo "Lab is up. Run ./run-tests.sh"
