#!/usr/bin/env bash
# Builds the cloud-init NoCloud seed for one Linux host.
#   usage: ./make-host-seed.sh H1|H2
# Cirros reads a filesystem labelled "cidata"; user-data is a plain shell script.
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env
source ./host-lib.sh
host_vars "${1:?usage: $0 H1|H2}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/meta-data" <<META
instance-id: ${NAME}
local-hostname: ${NAME}
META

# eth0 is management (QEMU user-mode NAT, DHCP). eth1 faces the router.
# Only the far LAN is routed via eth1, so management traffic is untouched and
# host-to-host traffic is forced through the router and its IPsec tunnel.
cat > "$work/user-data" <<USER
#!/bin/sh
ip link set eth1 up
ip addr add ${IP}/${LAN_PREFIX} dev eth1
for net in ${PEER_NETS}; do ip route add \${net}/${LAN_PREFIX} via ${GATEWAY} dev eth1; done
echo "${NAME}: eth1=${IP}/${LAN_PREFIX} gw=${GATEWAY} routes->${PEER_NETS}" > /tmp/lab-net.log
USER

mkdir -p run
iso="run/${HOST}-seed.iso"
if command -v genisoimage >/dev/null; then
  genisoimage -quiet -output "$iso" -volid cidata -joliet -rock "$work/meta-data" "$work/user-data"
else
  xorrisofs -quiet -output "$iso" -volid cidata -joliet -rock "$work/meta-data" "$work/user-data"
fi
echo "Wrote $iso  (${NAME}: ${IP}/${LAN_PREFIX} via ${GATEWAY}, routes to: ${PEER_NETS})"
