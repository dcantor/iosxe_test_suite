#!/usr/bin/env python3
"""Raw SNMP trap capture. One line per datagram: "<epoch> <source ip> <hex>".

Runs on the NMS beside snmptrapd, on a second port the routers also target.
snmptrapd cannot show that a trap was encrypted in flight, because by the time it
writes a log line it has already authenticated and decrypted; this keeps the
bytes exactly as they arrived so the tests can decode the BER themselves and
assert on the wire format.

One socket serves every router -- unlike the busybox nc collector it replaces,
which attached to its first sender and silently dropped all the others.
"""
import socket
import sys
import time


def main():
    port, path = int(sys.argv[1]), sys.argv[2]
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", port))
    with open(path, "a", buffering=1) as fh:
        while True:
            data, addr = s.recvfrom(65535)
            fh.write(f"{time.time():.3f} {addr[0]} {data.hex()}\n")


if __name__ == "__main__":
    main()
