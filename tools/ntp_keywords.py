"""Robot keywords for reading NTP state off IOS-XE."""
import re
from datetime import datetime

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nms_lib import Nms  # noqa: E402

# "20:02:51.645 UTC Sun Sep 6 2026", sometimes prefixed with * or . by the CLI
CLOCK_RE = re.compile(
    r"[.*]?(\d{2}):(\d{2}):(\d{2})\.(\d+)\s+(\S+)\s+\w{3}\s+(\w{3})\s+(\d{1,2})\s+(\d{4})")
MONTHS = {m: i for i, m in enumerate(
    "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(), start=1)}


class ntp_keywords:
    ROBOT_LIBRARY_SCOPE = "GLOBAL"

    _nms = None

    def nms_chrony(self, command):
        """Run a chronyc command on the NMS.

        The NMS is the lab's NTP server now, so its own upstream health is a
        precondition for anything the routers are asserted to do rather than a
        separate concern.
        """
        if ntp_keywords._nms is None:
            ntp_keywords._nms = Nms().connect()
        return ntp_keywords._nms.run(command)

    def close_nms_session(self):
        if ntp_keywords._nms is not None:
            ntp_keywords._nms.close()
            ntp_keywords._nms = None

    def parse_ios_clock(self, text):
        """'show clock' output -> datetime. Raises if it cannot be read."""
        m = CLOCK_RE.search(text)
        if not m:
            raise AssertionError(f"could not read a clock from: {text.strip()[:120]!r}")
        hh, mm, ss, frac, _tz, mon, day, year = m.groups()
        return datetime(int(year), MONTHS[mon], int(day), int(hh), int(mm), int(ss),
                        int(frac.ljust(6, "0")[:6]))

    def clock_skew_seconds(self, text_a, text_b):
        """Absolute difference between two 'show clock' outputs, in seconds."""
        a = self.parse_ios_clock(text_a)
        b = self.parse_ios_clock(text_b)
        return abs((a - b).total_seconds())

    def association_rows(self, text):
        """Parsed rows of 'show ntp associations'."""
        rows = []
        for line in text.splitlines():
            m = re.match(r"\s*([*+#\-x ~]*)~?(\d+\.\d+\.\d+\.\d+)\s+(\S+)\s+(\d+)\s+"
                         r"(\S+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(\S+)", line)
            if m:
                flags, addr, ref, st, when, poll, reach, delay, offset, disp = m.groups()
                rows.append({
                    "flags": flags.strip(), "address": addr, "ref": ref,
                    "stratum": int(st), "reach": int(reach),
                    "delay": float(delay), "offset": float(offset), "disp": float(disp),
                    "selected": "*" in flags, "candidate": "+" in flags,
                })
        return rows

    def reachable_associations(self, rows):
        return [r for r in rows if r["reach"] > 0]

    def selected_association(self, rows):
        sel = [r for r in rows if r["selected"]]
        return sel[0] if sel else None
