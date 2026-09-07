"""Robot keywords for SNMPv3 traps received on the NMS.

Two collectors receive the same traps, both here, because they prove different
things and neither can do the other's job:

  * snmptrapd, on the standard port, authenticates and decrypts each trap with a
    per-router USM key. Its log is proof the routers' credentials and engine IDs
    are right, and it shows the varbinds -- something the raw capture cannot,
    since the payload is encrypted;
  * a raw capture on a second port keeps the datagrams byte for byte, so the
    tests can decode the BER and assert the payload really is encrypted in
    flight. snmptrapd's log cannot show that: by the time it writes a line it
    has already decrypted.

Both are system services on the NMS, always running. The previous collector was
busybox nc on h1, which forced a separate port per router and, when a stale
listener survived a run, once made a negative test pass while nothing was
arriving at all.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nms_lib import Nms, load_env          # noqa: E402

# snmptrapd -Lf writes two lines per trap: a header naming the source, then the
# varbinds, tab separated.
TRAPD_RE = re.compile(
    r"^(?P<ts>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \S+ "
    r"\[UDP: \[(?P<src>[\d.]+)\]:\d+->\[(?P<dst>[\d.]+)\]:(?P<port>\d+)\]:\n"
    r"(?P<varbinds>.*)$", re.MULTILINE)
# the raw capture writes "<epoch> <source ip> <hex>", one line per datagram
RAW_RE = re.compile(r"^(?P<ts>[\d.]+) (?P<src>[\d.]+) (?P<hex>[0-9a-f]+)$", re.MULTILINE)
TRAP_OID = "iso.3.6.1.6.3.1.1.4.1.0"      # snmpTrapOID.0, the trap's identity


def _tlv(buf, i=0):
    """Decode one BER element: returns (tag, value, next_index)."""
    if i + 2 > len(buf):
        raise ValueError("truncated BER element")
    tag = buf[i]; i += 1
    length = buf[i]; i += 1
    if length & 0x80:
        n = length & 0x7F
        length = int.from_bytes(buf[i:i + n], "big")
        i += n
    return tag, buf[i:i + length], i + length

class snmp_keywords:
    ROBOT_LIBRARY_SCOPE = "GLOBAL"

    def __init__(self):
        self.env = load_env()
        self._nms = None

    # ---- session ---------------------------------------------------------
    def open_trap_collector(self):
        if self._nms is None:
            self._nms = Nms(self.env).connect()
        return self._nms

    def close_trap_collector(self):
        if self._nms is not None:
            self._nms.close()
            self._nms = None

    def trap_collectors_are_running(self):
        return self.open_trap_collector().run(
            "systemctl is-active snmptrapd lab-trapcap | tr '\\n' ' '").strip()

    def trap_collectors_listening_on(self):
        return self.open_trap_collector().run(
            f"sudo ss -lunp | grep -E ':({self.env['SNMP_TRAP_PORT']}|"
            f"{self.env['SNMP_TRAP_RAW_PORT']}) ' || echo NONE")

    # ---- snmptrapd: authenticated and decrypted ---------------------------
    def snmptrapd_log(self):
        return self.open_trap_collector().run(
            f"sudo cat {self.env['SNMP_TRAPD_LOG']} 2>/dev/null || true")

    def snmptrapd_entries(self, text=None):
        blob = self.snmptrapd_log() if text is None else text
        return [m.groupdict() for m in TRAPD_RE.finditer(blob)]

    def snmptrapd_entries_for(self, router):
        # traps are sourced from the OOB interface, so that is the address
        # snmptrapd records as the sender
        want = self.env[f"{router}_OOB_IP"]
        return [e for e in self.snmptrapd_entries() if e["src"] == want]

    def trap_oids_in(self, entries):
        """The snmpTrapOID.0 varbind of each entry -- what kind of trap it was."""
        out = []
        for e in entries:
            m = re.search(re.escape(TRAP_OID) + r"\s+(\S+)", e["varbinds"])
            if m:
                out.append(m.group(1))
        return out

    # ---- raw capture: the bytes as they arrived ---------------------------
    def raw_trap_log(self):
        return self.open_trap_collector().run(
            f"sudo cat {self.env['SYSLOG_DIR']}/traps-raw.log 2>/dev/null || true")

    def raw_traps_for(self, router, text=None):
        """Concatenated datagrams from one router, as bytes."""
        want = self.env[f"{router}_OOB_IP"]
        blob = self.raw_trap_log() if text is None else text
        chunks = [bytes.fromhex(m.group("hex"))
                  for m in RAW_RE.finditer(blob) if m.group("src") == want]
        return b"".join(chunks)

    def decoded_traps_for(self, router):
        return self.decode_v3_traps(self.raw_traps_for(router))

    def senders_in_raw_capture(self):
        return sorted({m.group("src") for m in RAW_RE.finditer(self.raw_trap_log())})

    def decode_v3_traps(self, raw):
        """Parse concatenated SNMPv3 datagrams into dicts.

        Only the fields outside the encrypted payload are readable: version,
        flags, engine id and user name. That is exactly what identifies the
        sender and proves the security level in use.
        """
        out, i = [], 0
        while i < len(raw):
            try:
                tag, msg, nxt = _tlv(raw, i)
            except ValueError:
                break
            if tag != 0x30:
                i += 1
                continue
            try:
                _, ver, p = _tlv(msg, 0)
                _, glob, p2 = _tlv(msg, p)
                _, sec, p3 = _tlv(msg, p2)
                _, secseq, _ = _tlv(sec, 0)
                _, eng, q = _tlv(secseq, 0)
                _, boots, q = _tlv(secseq, q)
                _, etime, q = _tlv(secseq, q)
                _, user, q = _tlv(secseq, q)
                # msgGlobalData: msgID, msgMaxSize, msgFlags, msgSecurityModel
                _, _mid, g = _tlv(glob, 0)
                _, _max, g = _tlv(glob, g)
                _, flags, g = _tlv(glob, g)
                _, secmodel, _ = _tlv(glob, g)
                data_tag = msg[p3] if p3 < len(msg) else None
                out.append({
                    "version": int.from_bytes(ver, "big"),
                    "engine_id": eng.hex(),
                    "engine_boots": int.from_bytes(boots, "big"),
                    "engine_time": int.from_bytes(etime, "big"),
                    "user": user.decode(errors="replace"),
                    "flags": flags[0] if flags else 0,
                    "auth": bool(flags and flags[0] & 0x01),
                    "priv": bool(flags and flags[0] & 0x02),
                    "security_model": int.from_bytes(secmodel, "big"),
                    # an encrypted scopedPDU arrives as an OCTET STRING (0x04);
                    # a readable one would be a SEQUENCE (0x30)
                    "encrypted": data_tag == 0x04,
                })
            except (ValueError, IndexError):
                pass
            i = nxt
        return out
