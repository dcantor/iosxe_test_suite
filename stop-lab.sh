#!/usr/bin/env bash
# Stops every VM.  ./stop-lab.sh --clean also deletes disks and ISOs.
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env
for v in NMS $HOSTS $ROUTERS; do
  pidf="run/${v}.pid"
  if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    kill "$(cat "$pidf")" && echo "${v} stopped."
  else
    echo "${v} not running."
  fi
  rm -f "$pidf"
done
if [[ "${1:-}" == "--clean" ]]; then
  rm -f run/*.qcow2 run/*.iso
  echo "Removed overlay disks and ISOs; next start is factory-fresh."
fi
