#!/usr/bin/env bash
# One-time host setup for the C8000V lab.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Installing host packages (sudo required)"
sudo apt-get update
sudo apt-get install -y genisoimage python3-venv qemu-system-x86 qemu-utils

echo "==> Creating Python venv for Robot Framework"
python3 -m venv .venv
./.venv/bin/pip install --upgrade pip
./.venv/bin/pip install -r requirements.txt

echo
echo "Done. Next:"
echo "  1. Put the Cisco qcow2 in images/  (see README.md)"
echo "  2. ./start-vm.sh"
echo "  3. ./wait-for-boot.sh"
echo "  4. ./run-tests.sh"
