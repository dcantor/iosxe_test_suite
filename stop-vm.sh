#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ -f run/vm.pid ]] && kill -0 "$(cat run/vm.pid)" 2>/dev/null; then
  kill "$(cat run/vm.pid)"; echo "Stopped."
else
  echo "Not running."
fi
rm -f run/vm.pid
