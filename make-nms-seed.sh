#!/usr/bin/env bash
# Builds the cloud-init seed for the NMS (a real Ubuntu cloud image, so unlike
# the cirros hosts its cloud-init actually works).
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cat > "$work/meta-data" <<META
instance-id: ${NMS_NAME}-001
local-hostname: ${NMS_NAME}
META

cat > "$work/user-data" <<USER
#cloud-config
hostname: ${NMS_NAME}
ssh_pwauth: true
disable_root: false
users:
  - name: ${NMS_USER}
    plain_text_passwd: '${NMS_PASS}'
    lock_passwd: false
    shell: /bin/bash
    sudo: 'ALL=(ALL) NOPASSWD:ALL'
    groups: [sudo]
package_update: true
packages:
  - snmp
  - snmptrapd
  - iputils-ping
  - chrony
write_files:
  - path: /etc/snmp/snmp.conf
    content: |
      # do not require MIBs we have not installed
      mibs :
runcmd:
  # eth1 faces the lab; eth0 stays on the QEMU NAT for package installs
  - [ sh, -c, "ip link set ens4 up || ip link set enp0s4 up || true" ]
  - [ sh, -c, "ip addr add ${NMS_IP}/${LAN_PREFIX} dev ens4 2>/dev/null || ip addr add ${NMS_IP}/${LAN_PREFIX} dev enp0s4 2>/dev/null || true" ]
  - [ sh, -c, "ip route replace ${R2_LAN_NET}/${LAN_PREFIX} via ${R1_LAN_IP} 2>/dev/null || true" ]
  - [ sh, -c, "ip route replace ${R3_LAN_NET}/${LAN_PREFIX} via ${R1_LAN_IP} 2>/dev/null || true" ]
  - [ sh, -c, "ip route replace ${NAT_DOMAIN}/${NAT_DOMAIN_PREFIX} via ${R1_LAN_IP} 2>/dev/null || true" ]
  # third NIC: the flat out-of-band management network
  - [ sh, -c, "ip link set ens5 up || ip link set enp0s5 up || true" ]
  - [ sh, -c, "ip addr add ${NMS_OOB_IP}/${OOB_PREFIX} dev ens5 2>/dev/null || ip addr add ${NMS_OOB_IP}/${OOB_PREFIX} dev enp0s5 2>/dev/null || true" ]
  - [ sh, -c, "touch /var/lib/cloud/nms-ready" ]
USER

mkdir -p run
if command -v genisoimage >/dev/null; then
  genisoimage -quiet -output run/NMS-seed.iso -volid cidata -joliet -rock "$work/meta-data" "$work/user-data"
else
  xorrisofs -quiet -output run/NMS-seed.iso -volid cidata -joliet -rock "$work/meta-data" "$work/user-data"
fi
echo "Wrote run/NMS-seed.iso (${NMS_NAME}: ${NMS_IP}/${LAN_PREFIX}, snmp tools)"
