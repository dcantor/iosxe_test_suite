#!/usr/bin/env python3
"""Bring the NMS to a known state and prove it can reach every router.

cloud-init does the real work on first boot (address, routes, packages); this
verifies that outcome and repairs it, so a re-used overlay disk or a half
finished cloud-init does not silently leave the polling tests untestable.
Idempotent: safe to re-run at any time.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nms_collectors                     # noqa: E402
from nms_lib import LAB_DIR, Nms, load_env  # noqa: E402

PACKAGES = ["snmp", "snmptrapd", "iputils-ping", "rsyslog", "chrony"]
# tac_plus was dropped from Ubuntu after jammy, but the .deb is still in the
# universe pool and the daemon itself is C. Its only unmet dependency is
# "python", meaning Python 2, which noble does not ship and which the daemon
# does not use -- it is there for an auxiliary script. So it is installed with
# that one dependency ignored rather than not at all.
TACACS_POOL = "http://archive.ubuntu.com/ubuntu/pool/universe/t/tacacs%2b/"
TACACS_DEB = "tacacs%2b_4.0.4.27a-3_amd64.deb"
TACACS_LIB_DEB = "libtacacs%2b1_4.0.4.27a-3_amd64.deb"
BINARIES = {"snmp": "snmpwalk", "snmptrapd": "snmptrapd",
            "iputils-ping": "ping", "rsyslog": "rsyslogd", "chrony": "chronyd"}


def main():
    env = load_env()
    n = Nms(env).connect()
    ip, prefix = env["NMS_IP"], env["LAN_PREFIX"]
    gw = env[f'{env["NMS_ROUTER"]}_LAN_IP']

    # cloud-init may still be installing packages on a cold boot
    n.run("cloud-init status --wait >/dev/null 2>&1 || true")

    missing = [p for p in PACKAGES
               if n.run(f"command -v {BINARIES[p]} >/dev/null && echo yes || echo no") != "yes"]
    if missing:
        print(f"[nms] installing {' '.join(missing)}")
        out, rc = n.run("sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update && "
                        "sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "
                        + " ".join(missing), rc=True)
        if rc != 0:
            raise SystemExit(f"[nms] package install failed:\n{out}")

    # NIC order: 1 = QEMU user NAT, 2 = hub LAN, 3 = out-of-band management.
    # Names come from the PCI slot, not from us, so they are read rather than assumed.
    nics = n.run("ip -o link | awk -F': ' '$2 !~ /^lo$/ {print $2}'").split()
    if len(nics) < 3:
        raise SystemExit(f"[nms] expected three NICs, found {nics}")
    dev, oob_dev = nics[1], nics[2]
    if ip not in n.run(f"ip -4 addr show {dev}"):
        print(f"[nms] setting {ip}/{prefix} on {dev}")
        n.run(f"sudo ip link set {dev} up && sudo ip addr add {ip}/{prefix} dev {dev}")
    oob_ip, oob_prefix = env["NMS_OOB_IP"], env["OOB_PREFIX"]
    if oob_ip not in n.run(f"ip -4 addr show {oob_dev}"):
        print(f"[nms] setting {oob_ip}/{oob_prefix} on {oob_dev} (out-of-band)")
        n.run(f"sudo ip link set {oob_dev} up && "
              f"sudo ip addr add {oob_ip}/{oob_prefix} dev {oob_dev}")

    nets = [env[f'{env[f"{h}_ROUTER"]}_LAN_NET'] for h in env["HOSTS"].split()]
    nets.append(env["NAT_DOMAIN"])
    prefixes = [env["LAN_PREFIX"]] * (len(nets) - 1) + [env["NAT_DOMAIN_PREFIX"]]
    for net, pfx in zip(nets, prefixes):
        if net == env[f'{env["NMS_ROUTER"]}_LAN_NET']:
            continue                        # directly connected
        n.run(f"sudo ip route replace {net}/{pfx} via {gw}")

    print(f"[nms] {n.run('hostname')} on {dev} = "
          f"{n.run(f'ip -4 -br addr show {dev}')}")

    # reachability first: the collectors need to poll each router for its
    # engine ID before snmptrapd can be configured to decrypt its traps
    install_tacacs(n)
    check_reachability(env, n)
    check_oob_reachability(env, n)
    nms_collectors.configure(n, env, LAB_DIR)
    n.close()


def install_tacacs(n):
    """Install the Shrubbery tac_plus server, if it is not already there."""
    if n.run("command -v tac_plus >/dev/null && echo yes || echo no") == "yes":
        return
    print("[nms] installing tac_plus")
    out, rc = n.run(
        f"cd /tmp && curl -sSLo libtac.deb '{TACACS_POOL}{TACACS_LIB_DEB}' && "
        f"curl -sSLo tacacs.deb '{TACACS_POOL}{TACACS_DEB}' && "
        "sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y libwrap0 >/dev/null 2>&1; "
        "sudo dpkg -i /tmp/libtac.deb >/dev/null 2>&1 && "
        "sudo dpkg -i --ignore-depends=python /tmp/tacacs.deb >/dev/null 2>&1; "
        "command -v tac_plus >/dev/null && echo installed || echo failed", rc=True)
    if "installed" not in out:
        raise SystemExit(f"[nms] tac_plus install failed: {out}")


def check_oob_reachability(env, n):
    """Every router must answer on the flat management network."""
    for r in env["ROUTERS"].split():
        target = env[f"{r}_OOB_IP"]
        for _ in range(12):
            out, _rc = n.run(f"ping -c2 -W2 {target} >/dev/null 2>&1; echo $?", rc=True)
            if out.strip().endswith("0"):
                print(f"[nms] reaches {r} out-of-band at {target}")
                break
            time.sleep(10)
        else:
            raise SystemExit(f"[nms] cannot reach {r} out-of-band at {target}")


def check_reachability(env, n):
    # every router's LAN interface -- the SNMP agents we poll
    for r in env["ROUTERS"].split():
        target = env[f"{r}_LAN_IP"]
        for attempt in range(12):
            out, rc = n.run(f"ping -c2 -W2 {target} >/dev/null 2>&1; echo $?", rc=True)
            if out.strip().endswith("0"):
                print(f"[nms] reaches {r} at {target}")
                break
            time.sleep(10)
        else:
            raise SystemExit(f"[nms] cannot reach {r} at {target}")


if __name__ == "__main__":
    main()
