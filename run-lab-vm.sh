#!/usr/bin/env bash
# Boots the packaged appliance built by ./package-lab.sh.
#
# The inner lab needs the full memory it always did -- three routers at 8 GB
# each plus the hosts and the NMS -- so the appliance is sized for that rather
# than for the outer OS. "-cpu host" is not a preference: without it the guest
# sees no vmx/svm and nothing inside can start.
#
#   usage: ./run-lab-vm.sh [image.qcow2]
set -euo pipefail
cd "$(dirname "$0")"

IMG="${1:-dist/c8000v-lab.qcow2}"
RAM=${LAB_VM_RAM_MB:-30720}
CPUS=${LAB_VM_CPUS:-8}
SSH_PORT=${LAB_VM_SSH:-2299}

[[ -f "$IMG" ]] || { echo "ERROR: $IMG not found -- run ./package-lab.sh first" >&2; exit 1; }
[[ -r /dev/kvm && -w /dev/kvm ]] || { echo "ERROR: no access to /dev/kvm" >&2; exit 1; }
nested=$(cat /sys/module/kvm_intel/parameters/nested 2>/dev/null ||
         cat /sys/module/kvm_amd/parameters/nested 2>/dev/null || echo N)
case "$nested" in
  1|Y|y) ;;
  *) echo "ERROR: nested virtualisation is off on this host." >&2
     echo "  Intel: echo 'options kvm_intel nested=1' | sudo tee /etc/modprobe.d/kvm.conf" >&2
     echo "  AMD  : echo 'options kvm_amd nested=1'   | sudo tee /etc/modprobe.d/kvm.conf" >&2
     echo "  then reload the module or reboot." >&2
     exit 1 ;;
esac

mkdir -p run
qemu-system-x86_64 \
  -name c8000v-lab-appliance \
  -machine pc,accel=kvm -cpu host -smp "$CPUS" -m "$RAM" \
  -drive if=virtio,file="$IMG",format=qcow2,cache=writeback \
  -netdev user,id=mgmt,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22 \
  -device virtio-net-pci,netdev=mgmt \
  -display none -daemonize -pidfile run/appliance.pid

echo "Appliance started, pid $(cat run/appliance.pid)  (${CPUS} vCPU, ${RAM} MB)"
echo "   ssh -p ${SSH_PORT} lab@127.0.0.1        # password: see lab.env"
echo "   then: cd c8000v-lab && ./start-lab.sh && ./run-tests.sh"
