#!/usr/bin/env bash
# Boots the NMS onto the hub LAN segment alongside h1.
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env

IMG="images/${NMS_IMAGE}"
[[ -f "$IMG" ]] || { echo "ERROR: $IMG not found" >&2; exit 1; }
mkdir -p run
DISK="run/NMS.qcow2"
[[ -f "$DISK" ]] || qemu-img create -q -f qcow2 -F qcow2 -b "$(realpath "$IMG")" "$DISK"
[[ -f run/NMS-seed.iso ]] || ./make-nms-seed.sh

pidf="run/NMS.pid"
if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
  echo "NMS already running, pid $(cat "$pidf")"; exit 0
fi

qemu-system-x86_64 \
  -name "${NMS_NAME}" \
  -machine pc,accel=kvm -cpu host -smp "${NMS_CPUS}" -m "${NMS_RAM_MB}" \
  -drive if=virtio,file="${DISK}",format=qcow2,cache=writeback \
  -drive if=virtio,file=run/NMS-seed.iso,format=raw,readonly=on \
  -netdev user,id=mgmt,hostfwd=tcp:127.0.0.1:${NMS_SSH}-:22 \
  -device virtio-net-pci,netdev=mgmt,mac=52:54:00:bb:01:01 \
  -netdev socket,id=lan,mcast=${R1_LAN_MCAST}:${R1_LAN_PORT},localaddr=${MCAST_LOCALADDR} \
  -device virtio-net-pci,netdev=lan,mac=52:54:00:bb:01:02 \
  -netdev socket,id=oob,mcast=${OOB_MCAST}:${OOB_PORT},localaddr=${MCAST_LOCALADDR} \
  -device virtio-net-pci,netdev=oob,mac=52:54:00:bb:01:03 \
  -serial telnet:127.0.0.1:${NMS_CONSOLE},server,nowait \
  -display none -daemonize -pidfile "$pidf"

echo "NMS (${NMS_NAME}) started, pid $(cat "$pidf")"
echo "   ssh     : ssh -p ${NMS_SSH} ${NMS_USER}@127.0.0.1"
echo "   console : telnet 127.0.0.1 ${NMS_CONSOLE}"
echo "   lab NIC : ${NMS_IP}/${LAN_PREFIX} via ${R1_LAN_IP}"
echo "   oob NIC : ${NMS_OOB_IP}/${OOB_PREFIX} (flat management net)"
