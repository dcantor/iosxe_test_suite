#!/usr/bin/env bash
# Boots one Linux host.  usage: ./start-host.sh H1|H2
# eth1 joins its router's LAN multicast segment; start order no longer matters.
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env
source ./host-lib.sh
host_vars "${1:?usage: $0 H1|H2}"

IMG="images/${HOST_IMAGE}"
[[ -f "$IMG" ]] || { echo "ERROR: $IMG not found" >&2; exit 1; }

mkdir -p run
DISK="run/${HOST}.qcow2"
[[ -f "$DISK" ]] || qemu-img create -q -f qcow2 -F qcow2 -b "$(realpath "$IMG")" "$DISK"
[[ -f "run/${HOST}-seed.iso" ]] || ./make-host-seed.sh "$HOST"

pidf="run/${HOST}.pid"
if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
  echo "${HOST} (${NAME}) already running, pid $(cat "$pidf")"; exit 0
fi

case "$HOST" in H1) IDX=1 ;; H2) IDX=2 ;; H3) IDX=3 ;; esac
MAC=$(printf "%02d" "$IDX")

qemu-system-x86_64 \
  -name "${NAME}" \
  -machine pc,accel=kvm \
  -cpu host \
  -smp "${HOST_CPUS}" \
  -m "${HOST_RAM_MB}" \
  -drive if=virtio,file="${DISK}",format=qcow2,cache=writeback \
  -drive if=ide,media=cdrom,file="run/${HOST}-seed.iso",readonly=on \
  -netdev user,id=mgmt,hostfwd=tcp:127.0.0.1:${SSH}-:22 \
  -device virtio-net-pci,netdev=mgmt,mac=52:54:00:aa:${MAC}:01 \
  -netdev socket,id=lan,mcast=${LAN_MCAST}:${LAN_PORT},localaddr=${MCAST_LOCALADDR} \
  -device virtio-net-pci,netdev=lan,mac=52:54:00:aa:${MAC}:02 \
  -serial telnet:127.0.0.1:${CONSOLE},server,nowait \
  -display none -daemonize -pidfile "$pidf"

echo "${HOST} (${NAME}) started, pid $(cat "$pidf")"
echo "   ssh     : ssh -p ${SSH} ${HOST_USER}@127.0.0.1"
echo "   console : telnet 127.0.0.1 ${CONSOLE}"
echo "   eth1    : ${IP}/${LAN_PREFIX} -> ${GATEWAY} (routes to: ${PEER_NETS})"
