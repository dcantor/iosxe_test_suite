#!/usr/bin/env python3
"""Configure the Linux hosts' LAN interface and route.

Cirros ignores the NoCloud seed on this image (the disk is present and correctly
labelled, but cirros-init never consumes it), so rather than depend on its
datasource the hosts are provisioned over SSH -- the same boot-then-provision
pattern the routers use. Idempotent: safe to re-run at any time.
"""
import argparse
import os
import socket
import sys
import time

from SSHLibrary import SSHLibrary

LAB_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROMPT = r"REGEXP:\$ $"


def load_env(path=None):
    env = {}
    with open(path or os.path.join(LAB_DIR, "lab.env")) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"')
    return env


def wait_for_ssh(port, timeout=300):
    """Wait for a real SSH banner: QEMU's forwarded port opens before sshd does."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
                s.settimeout(5)
                if s.recv(4).startswith(b"SSH-"):
                    return True
        except OSError:
            pass
        time.sleep(5)
    return False


def configure(env, host):
    port = int(env[f"{host}_SSH"])
    name = env[f"{host}_NAME"]
    router = env[f"{host}_ROUTER"]
    ip = env[f"{host}_IP"]
    prefix = env["LAN_PREFIX"]
    gateway = env[f"{router}_LAN_IP"]
    # every other host's LAN, reached through this host's own gateway
    peer_nets = [env[f'{env[f"{o}_ROUTER"]}_LAN_NET']
                 for o in env["HOSTS"].split() if o != host]

    if not wait_for_ssh(port):
        raise RuntimeError(f"{name}: no SSH on port {port}")

    s = SSHLibrary(timeout="60s")
    s.open_connection("127.0.0.1", port=port, width=200, prompt=PROMPT)
    s.login(env["HOST_USER"], env["HOST_PASS"], delay="3s")

    def sh(cmd):
        s.write(cmd)
        return s.read_until_prompt(strip_prompt=True).replace(cmd, "", 1).strip()

    print(f"[{host}] configuring eth1 = {ip}/{prefix} via {gateway}, routes to {peer_nets}")
    sh("sudo ip link set eth1 up")
    sh("sudo ip addr flush dev eth1")          # drops the 169.254 autoconf address
    # Two blocks of addresses, assigned with shell loops rather than one SSH
    # round trip each: 40 per host would otherwise be 120 round trips for the lab.
    lan24 = ip.rsplit(".", 1)[0]
    s_off = int(env["STATIC_HOST_OFFSET"]); s_n = int(env["NAT_STATIC_COUNT"])
    d_off = int(env["DYNAMIC_HOST_OFFSET"]); d_n = int(env["NAT_DYNAMIC_COUNT"])
    statics = [f"{lan24}.{s_off+i}" for i in range(s_n)]
    dynamics = [f"{lan24}.{d_off+i}" for i in range(d_n)]
    sh(f"for i in $(seq {s_off} {s_off+s_n-1}); do "
       f"sudo ip addr add {lan24}.$i/{prefix} dev eth1 2>/dev/null; done; echo done")
    sh(f"for i in $(seq {d_off} {d_off+d_n-1}); do "
       f"sudo ip addr add {lan24}.$i/{prefix} dev eth1 2>/dev/null; done; echo done")
    for net in peer_nets:
        sh(f"sudo ip route replace {net}/{prefix} via {gateway} dev eth1")
    # the NAT domain: peers are also reachable at their mapped addresses
    sh(f"sudo ip route replace {env['NAT_DOMAIN']}/{env['NAT_DOMAIN_PREFIX']} via {gateway} dev eth1")

    addr = sh("ip addr show eth1 | grep 'inet '")     # kept: the original check reads this
    n_out = sh("ip addr show eth1 | grep -c 'inet '")
    count = int(n_out.split()[0]) if n_out.split() and n_out.split()[0].isdigit() else 0
    for probe in (statics[0], statics[-1], dynamics[0], dynamics[-1]):
        if probe not in sh(f"ip addr show eth1 | grep '{probe}/'"):
            raise RuntimeError(f"{name}: eth1 is missing {probe}")
    print(f"[{host}] static : {statics[0]} - {statics[-1]} ({s_n} addresses, 1:1 NAT)")
    print(f"[{host}] pool   : {dynamics[0]} - {dynamics[-1]} ({d_n} addresses, dynamic NAT)")
    print(f"[{host}] eth1 now holds {count} addresses")
    routes = sh("ip route")
    print(f"[{host}] eth1   : {addr}")
    if ip not in addr:
        raise RuntimeError(f"{name}: eth1 did not take {ip}")
    for net in peer_nets:
        if net not in routes:
            raise RuntimeError(f"{name}: route to {net} missing")
        print(f"[{host}] route  : {net}/{prefix} via {gateway}")
    if env["NAT_DOMAIN"] not in routes:
        raise RuntimeError(f"{name}: route to the NAT domain missing")
    print(f"[{host}] route  : {env['NAT_DOMAIN']}/{env['NAT_DOMAIN_PREFIX']} via {gateway} (NAT domain)")
    s.close_all_connections()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hosts", default="")
    args = ap.parse_args()
    env = load_env()
    hosts = args.hosts.split(",") if args.hosts else env["HOSTS"].split()
    for h in [x.strip() for x in hosts if x.strip()]:
        configure(env, h)
    print("host provisioning complete")


if __name__ == "__main__":
    main()
