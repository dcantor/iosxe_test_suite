#!/usr/bin/env bash
# Builds the whole testbed into a single portable KVM image.
#
# The result is one qcow2 containing Ubuntu, the toolchain, this repository and
# every base image -- including the Cisco one. Boot it on any KVM host with
# nested virtualisation and enough memory, and ./start-lab.sh inside brings up
# all seven inner VMs.
#
# Why this works cleanly: nothing in the lab touches the host network. Every
# link is a QEMU netdev on loopback -- socket for the router links, multicast
# pinned to lo for the LANs and the out-of-band segment, user-mode NAT for
# management -- so the lab is indifferent to the machine underneath it.
#
#   usage: ./package-lab.sh [output.qcow2]
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env

OUT="${1:-dist/c8000v-lab.qcow2}"
[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
BUILD_RAM=4096            # only the copy and the venv build happen at this size
BUILD_SSH=2299
DISK_SIZE=70G
WORK="$PWD/run/pkg"

mkdir -p "$(dirname "$OUT")" "$WORK"

BASE="images/${NMS_IMAGE}"
[[ -f "$BASE" ]] || { echo "ERROR: $BASE not found" >&2; exit 1; }

echo "==> Preparing the outer disk (standalone, not an overlay)"
qemu-img convert -O qcow2 "$BASE" "$OUT"
qemu-img resize -q "$OUT" "$DISK_SIZE"

echo "==> Build key (used only to copy the payload in; removed afterwards)"
rm -f "$WORK/buildkey" "$WORK/buildkey.pub"
ssh-keygen -q -t ed25519 -N "" -f "$WORK/buildkey" -C "lab-package-build"

echo "==> cloud-init seed"
cat > "$WORK/meta-data" <<META
instance-id: c8000v-lab-appliance
local-hostname: c8000v-lab
META
cat > "$WORK/user-data" <<USER
#cloud-config
hostname: c8000v-lab
ssh_pwauth: true
users:
  - name: ${VM_USER}
    plain_text_passwd: '${VM_PASS}'
    lock_passwd: false
    shell: /bin/bash
    sudo: 'ALL=(ALL) NOPASSWD:ALL'
    groups: [sudo, kvm]
    ssh_authorized_keys:
      - $(cat "$WORK/buildkey.pub")
package_update: true
packages:
  - qemu-system-x86
  - qemu-utils
  - genisoimage
  - python3-venv
  - python3-dev
  - gcc
  - curl
  - net-tools
growpart:
  mode: auto
  devices: ['/']
runcmd:
  - [ sh, -c, "usermod -aG kvm ${VM_USER} || true" ]
  - [ sh, -c, "touch /var/lib/cloud/appliance-ready" ]
USER
if command -v genisoimage >/dev/null; then
  genisoimage -quiet -output "$WORK/seed.iso" -volid cidata -joliet -rock \
    "$WORK/meta-data" "$WORK/user-data"
else
  xorrisofs -quiet -output "$WORK/seed.iso" -volid cidata -joliet -rock \
    "$WORK/meta-data" "$WORK/user-data"
fi

echo "==> Booting the appliance for the build (${BUILD_RAM} MB)"
qemu-system-x86_64 \
  -name c8000v-lab-build \
  -machine pc,accel=kvm -cpu host -smp 4 -m "${BUILD_RAM}" \
  -drive if=virtio,file="$OUT",format=qcow2,cache=writeback \
  -drive if=virtio,file="$WORK/seed.iso",format=raw,readonly=on \
  -netdev user,id=mgmt,hostfwd=tcp:127.0.0.1:${BUILD_SSH}-:22 \
  -device virtio-net-pci,netdev=mgmt \
  -display none -daemonize -pidfile "$WORK/build.pid"

SSHOPTS=(-i "$WORK/buildkey" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
         -o LogLevel=ERROR -p "$BUILD_SSH")
echo "==> Waiting for the appliance and its cloud-init"
for _ in $(seq 1 90); do
  ssh "${SSHOPTS[@]}" "${VM_USER}@127.0.0.1" true 2>/dev/null && break
  sleep 10
done
ssh "${SSHOPTS[@]}" "${VM_USER}@127.0.0.1" "cloud-init status --wait >/dev/null 2>&1 || true"

echo "==> Copying the lab in (images included)"
tar --exclude=./run --exclude=./results --exclude=./.venv --exclude=./dist \
    --exclude=./.git -czf - . |
  ssh "${SSHOPTS[@]}" "${VM_USER}@127.0.0.1" \
    "mkdir -p ~/c8000v-lab && tar -xzf - -C ~/c8000v-lab"

echo "==> Building the Python environment inside the appliance"
ssh "${SSHOPTS[@]}" "${VM_USER}@127.0.0.1" bash -lc "'
  cd ~/c8000v-lab &&
  python3 -m venv .venv &&
  ./.venv/bin/pip -q install --upgrade pip &&
  ./.venv/bin/pip -q install -r requirements.txt
'"

echo "==> Installing headless Chrome (renders docs/topology.html to PDF)"
# Not in the noble archive as a deb -- chromium there is a snap stub -- so the
# upstream package is used. It is only ever run headless by
# tools/make_topology_pdf.sh; nothing in the lab needs a browser otherwise.
ssh "${SSHOPTS[@]}" "${VM_USER}@127.0.0.1" bash -lc "'
  set -e
  cd /tmp
  curl -sSLo chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y ./chrome.deb >/dev/null
  rm -f chrome.deb
  google-chrome --version
'"

echo "==> Verifying the appliance can nest"
ssh "${SSHOPTS[@]}" "${VM_USER}@127.0.0.1" bash -lc "'
  test -e /dev/kvm && echo \"  /dev/kvm present\" || { echo \"  NO /dev/kvm -- nested virtualisation is not available\"; exit 1; }
  grep -qE \"vmx|svm\" /proc/cpuinfo && echo \"  CPU exposes virtualisation extensions\" || { echo \"  CPU lacks vmx/svm\"; exit 1; }
  ls ~/c8000v-lab/images/
'"

echo "==> Removing the build key and shutting down"
ssh "${SSHOPTS[@]}" "${VM_USER}@127.0.0.1" \
  "rm -f ~/.ssh/authorized_keys && sudo cloud-init clean --logs >/dev/null 2>&1 || true; sudo poweroff" || true
# QEMU removes its own pidfile when it exits, so the file disappearing is
# itself the signal that the appliance has shut down.
for _ in $(seq 1 30); do
  [[ -f "$WORK/build.pid" ]] || break
  kill -0 "$(cat "$WORK/build.pid" 2>/dev/null)" 2>/dev/null || break
  sleep 5
done
rm -f "$WORK/buildkey" "$WORK/buildkey.pub" "$WORK/build.pid"

echo "==> Compacting"
qemu-img convert -O qcow2 -c "$OUT" "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo
echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"
echo "Boot it with ./run-lab-vm.sh, or on another host:"
echo "  qemu-system-x86_64 -machine pc,accel=kvm -cpu host -smp 8 -m 30720 \\"
echo "    -drive if=virtio,file=c8000v-lab.qcow2,format=qcow2 \\"
echo "    -netdev user,id=n,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n \\"
echo "    -display none -daemonize"
