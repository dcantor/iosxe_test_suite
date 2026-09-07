#!/usr/bin/env bash
# Runs the Robot suite. All device coordinates come from lab.env.
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env

# If any argument is an existing path, treat the arguments as the complete target
# list; otherwise they are options and the default target is the whole suite.
ROBOT_ARGS=("$@")
target_given=0
for a in "$@"; do
  [[ -e "$a" ]] && target_given=1
done
[[ $target_given -eq 1 ]] || ROBOT_ARGS+=(tests/)

./.venv/bin/robot \
  --outputdir results \
  --variable R1_HOST:127.0.0.1 \
  --variable R1_PORT:${R1_SSH}  --variable R2_PORT:${R2_SSH}  --variable R3_PORT:${R3_SSH} \
  --variable USERNAME:${VM_USER} --variable PASSWORD:${VM_PASS} \
  --variable R1_NAME:${R1_NAME} --variable R2_NAME:${R2_NAME} --variable R3_NAME:${R3_NAME} \
  --variable R1_ASN:${R1_ASN}   --variable R2_ASN:${R2_ASN}   --variable R3_ASN:${R3_ASN} \
  --variable R2_LINK_HUB:${R2_LINK_HUB}     --variable R2_LINK_LOCAL:${R2_LINK_LOCAL} \
  --variable R3_LINK_HUB:${R3_LINK_HUB}     --variable R3_LINK_LOCAL:${R3_LINK_LOCAL} \
  --variable R2_HUB_INTF:${R2_HUB_INTF}     --variable R3_HUB_INTF:${R3_HUB_INTF} \
  --variable R2_HUB_TUNNEL:Tunnel${R2_HUB_TUNNEL_ID} --variable R3_HUB_TUNNEL:Tunnel${R3_HUB_TUNNEL_ID} \
  --variable R2_TUNNEL_HUB:${R2_TUNNEL_HUB} --variable R2_TUNNEL_LOCAL:${R2_TUNNEL_LOCAL} \
  --variable R3_TUNNEL_HUB:${R3_TUNNEL_HUB} --variable R3_TUNNEL_LOCAL:${R3_TUNNEL_LOCAL} \
  --variable R1_LOOPBACK:${R1_LOOPBACK} --variable R2_LOOPBACK:${R2_LOOPBACK} --variable R3_LOOPBACK:${R3_LOOPBACK} \
  --variable R1_BGP_PREFIX:${R1_BGP_PREFIX} --variable R2_BGP_PREFIX:${R2_BGP_PREFIX} --variable R3_BGP_PREFIX:${R3_BGP_PREFIX} \
  --variable R1_LAN_IP:${R1_LAN_IP}   --variable R2_LAN_IP:${R2_LAN_IP}   --variable R3_LAN_IP:${R3_LAN_IP} \
  --variable R1_LAN_NET:${R1_LAN_NET} --variable R2_LAN_NET:${R2_LAN_NET} --variable R3_LAN_NET:${R3_LAN_NET} \
  --variable BGP_PASSWORD:${BGP_PASSWORD} \
  --variable H1_PORT:${H1_SSH} --variable H2_PORT:${H2_SSH} --variable H3_PORT:${H3_SSH} \
  --variable H1_IP:${H1_IP}    --variable H2_IP:${H2_IP}    --variable H3_IP:${H3_IP} \
  --variable HOST_USER:${HOST_USER} --variable HOST_PASSWORD:${HOST_PASS} \
  --variable H1_NAT_IP:${H1_NAT_IP}   --variable H2_NAT_IP:${H2_NAT_IP}   --variable H3_NAT_IP:${H3_NAT_IP} \
  --variable R1_NAT_NET:${R1_NAT_NET} --variable R2_NAT_NET:${R2_NAT_NET} --variable R3_NAT_NET:${R3_NAT_NET} \
  --variable NAT_DOMAIN:${NAT_DOMAIN} \
  --variable STATIC_OCTET_FIRST:${STATIC_HOST_OFFSET} \
  --variable STATIC_OCTET_LAST:$((STATIC_HOST_OFFSET + NAT_STATIC_COUNT - 1)) \
  --variable DYN_OCTET_FIRST:${DYNAMIC_HOST_OFFSET} \
  --variable DYN_OCTET_LAST:$((DYNAMIC_HOST_OFFSET + NAT_DYNAMIC_COUNT - 1)) \
  --variable POOL_OCTET_FIRST:${POOL_OFFSET} \
  --variable POOL_OCTET_LAST:$((POOL_OFFSET + NAT_DYNAMIC_COUNT - 1)) \
  --variable SNMP_POLL_USER:${SNMP_USER} \
  --variable SNMP_AUTH_PASS:${SNMP_AUTH_PASS} --variable SNMP_PRIV_PASS:${SNMP_PRIV_PASS} \
  --variable NMS_IP:${NMS_IP} --variable NMS_PORT:${NMS_SSH} \
  --variable NMS_OOB_IP:${NMS_OOB_IP} --variable MGMT_VRF:${MGMT_VRF} \
  --variable OOB_NET:${OOB_NET} --variable OOB_PREFIX:${OOB_PREFIX} \
  --variable R1_OOB_IP:${R1_OOB_IP} --variable R2_OOB_IP:${R2_OOB_IP} --variable R3_OOB_IP:${R3_OOB_IP} \
  --variable R1_OOB_INTF:${R1_OOB_INTF} --variable R2_OOB_INTF:${R2_OOB_INTF} --variable R3_OOB_INTF:${R3_OOB_INTF} \
  --variable TACACS_KEY:${TACACS_KEY} --variable TACACS_PORT:${TACACS_PORT} \
  --variable ADMIN_USER:${TACACS_ADMIN_USER} --variable ADMIN_PASS:${TACACS_ADMIN_PASS} \
  --variable OPS_USER:${TACACS_OPS_USER} --variable OPS_PASS:${TACACS_OPS_PASS} \
  --variable TAC_GROUP:${TACACS_GROUP} \
  "${ROBOT_ARGS[@]}" && rc=0 || rc=$?

# ---- archive this run -------------------------------------------------------
# Robot overwrites output.xml / log.html / report.html in place, so without this
# each run destroys the previous one's evidence. The newest run also stays at the
# results/ root so existing tooling keeps working.
ARCHIVE="results/results_$(date +%Y-%m-%d_%H%M%S)"
mkdir -p "$ARCHIVE"
for f in results/output.xml results/log.html results/report.html; do
  [[ -f "$f" ]] && cp "$f" "$ARCHIVE"/
done
shopt -s nullglob
for f in results/*.txt; do cp "$f" "$ARCHIVE"/; done
shopt -u nullglob

# self-contained human-readable records, archived alongside the raw output:
# the command-by-command evidence, and the topology the run was executed against.
made=()
if ./.venv/bin/python tools/make_report.py results/output.xml "$ARCHIVE/test-evidence.pdf" >/dev/null 2>&1; then
  cp "$ARCHIVE/test-evidence.pdf" results/
  made+=("test-evidence.pdf")
else
  echo "WARNING: test-evidence.pdf generation failed" >&2
fi
if ./tools/make_topology_pdf.sh "$ARCHIVE/topology.pdf" >/dev/null 2>&1; then
  cp "$ARCHIVE/topology.pdf" results/
  made+=("topology.pdf")
else
  echo "WARNING: topology.pdf generation failed" >&2
fi
printf 'Archived: %s (robot output, device captures%s%s)\n' "$ARCHIVE" "${made:+, }" "$(printf '%s, ' "${made[@]}" | sed 's/, $//')"
exit $rc
