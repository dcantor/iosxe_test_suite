#!/usr/bin/env bash
# Builds the day0 bootstrap ISO for one router.  usage: ./make-day0.sh R1|R2|R3
# Crypto/BGP are NOT here: the crypto CLI does not exist until a feature licence
# is active, which only takes effect across a reload.
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env
source ./lib.sh
router_vars "${1:?usage: $0 R1|R2|R3}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

{
cat <<CFG
hostname ${NAME}
!
no service config
service timestamps debug datetime msec
service timestamps log datetime msec
!
username ${VM_USER} privilege 15 secret 0 ${VM_PASS}
enable secret 0 ${VM_PASS}
!
ip domain name lab.local
crypto key generate rsa modulus 2048
ip ssh version 2
ip ssh server algorithm authentication password
!
license boot level ${LICENSE_LEVEL} addon ${LICENSE_ADDON}
!
vrf definition ${MGMT_VRF}
 description out-of-band management
 address-family ipv4
 exit-address-family
!
interface GigabitEthernet1
 description MGMT - QEMU user-mode net (DHCP)
 ip address dhcp
 no shutdown
!
CFG

if [[ "$ROLE" == "hub" ]]; then
  cat <<CFG
interface GigabitEthernet2
 description P2P link to ${R2_NAME}
 ip address ${R2_LINK_HUB} ${LINK_MASK}
 no shutdown
!
interface GigabitEthernet3
 description LAN toward ${H1_NAME}
 ip address ${LAN_IP} ${LAN_MASK}
 no shutdown
!
interface GigabitEthernet4
 description P2P link to ${R3_NAME}
 ip address ${R3_LINK_HUB} ${LINK_MASK}
 no shutdown
!
CFG
else
  cat <<CFG
interface GigabitEthernet2
 description P2P link to the hub (${R1_NAME})
 ip address ${LINK_LOCAL} ${LINK_MASK}
 no shutdown
!
interface GigabitEthernet3
 description LAN toward the local host
 ip address ${LAN_IP} ${LAN_MASK}
 no shutdown
!
CFG
fi

cat <<CFG
interface ${OOB_INTF}
 description OOB management - NTP, syslog, SNMP
 vrf forwarding ${MGMT_VRF}
 ip address ${OOB_IP} ${OOB_MASK}
 no shutdown
!
interface Loopback0
 description Protected endpoint
 ip address ${LOOPBACK} 255.255.255.255
!
line con 0
 logging synchronous
 exec-timeout 0 0
!
line vty 0 15
 login local
 transport input ssh
 exec-timeout 0 0
!
netconf-yang
restconf
ip http secure-server
!
end
CFG
} > "$work/iosxe_config.txt"

mkdir -p run
iso="run/${ROUTER}-day0.iso"
if command -v genisoimage >/dev/null; then
  genisoimage -quiet -output "$iso" -l -V "cidata" "$work/iosxe_config.txt"
else
  xorrisofs -quiet -output "$iso" -V "cidata" "$work/iosxe_config.txt"
fi
echo "Wrote $iso  (${NAME}, ${ROLE}: LAN=${LAN_IP}, OOB=${OOB_IP}, Lo0=${LOOPBACK})"
