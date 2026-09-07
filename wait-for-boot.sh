#!/usr/bin/env bash
# Blocks until a router's SSH server answers.  usage: ./wait-for-boot.sh R1|R2 [timeout]
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env
source ./lib.sh
router_vars "${1:?usage: $0 R1|R2 [timeout]}"
DEADLINE=$(( $(date +%s) + ${2:-900} ))
# A bare TCP connect is not enough. QEMU's user-mode NAT accepts the forwarded
# port on the host side and only then tries to reach the guest, so the port looks
# open from the moment the VM starts -- minutes before IOS-XE is listening. Wait
# for a real SSH banner instead, which is what the Python tools already do.
ready() {
  local banner
  banner=$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${SSH} && head -c 4 <&3" 2>/dev/null) || return 1
  [[ "$banner" == SSH-* ]]
}

echo "Waiting for ${ROUTER} (${NAME}) SSH on 127.0.0.1:${SSH} ..."
until ready; do
  if [[ $(date +%s) -ge $DEADLINE ]]; then
    echo "${ROUTER}: TIMEOUT. Console: telnet 127.0.0.1 ${CONSOLE}" >&2
    exit 1
  fi
  sleep 10
done
echo "${ROUTER} (${NAME}) is up."
