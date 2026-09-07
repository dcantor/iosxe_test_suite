"""Robot keywords for the syslog collector on the NMS.

The collector is rsyslog, writing each sender's datagrams verbatim into a file
named for its source address. Two consequences the tests rely on:

  * one UDP port serves all three routers. The previous collector was busybox
    `nc` on h1, which attached to its first sender and silently dropped every
    other source, so each router needed a port of its own;
  * messages arrive newline separated and in the router's own framing, because
    the rsyslog template is %rawmsg%. Nothing is reformatted, so what is parsed
    here is exactly what IOS put on the wire.

The collector is a system service, always running, so there is nothing to start
or stop -- and no way for a suite to leave a stale listener behind swallowing
another suite's messages.
"""
import os
import re
import sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nms_lib import Nms, load_env          # noqa: E402

# <PRI>SEQ: [SEQ2: ]TIMESTAMP [TZ]: %FACILITY-SEVERITY-MNEMONIC: text
#
# Two sequence numbers appear once "service sequence-numbers" is configured (one
# from the syslog host counter, one from the message counter), and a timezone
# field once "show-timezone" is set. Both are optional so this parses messages
# from a router configured either way.
MSG_RE = re.compile(
    r"<(?P<pri>\d+)>(?P<seq>\d+): (?:(?P<seq2>\d+): )?"
    r"(?P<ts>[A-Z][a-z]{2} +\d+ +[\d:.]+)(?: [A-Z]{2,4})?: "
    r"%(?P<facility>[A-Z0-9_]+)-(?P<sev>\d)-(?P<mnemonic>[A-Z0-9_]+): (?P<text>.*)")


class syslog_keywords:
    ROBOT_LIBRARY_SCOPE = "GLOBAL"

    def __init__(self):
        self.env = load_env()
        self._nms = None

    # ---- session ---------------------------------------------------------
    def open_collector(self):
        if self._nms is None:
            self._nms = Nms(self.env).connect()
        return self._nms

    def close_collector(self):
        if self._nms is not None:
            self._nms.close()
            self._nms = None

    def collector_file_for(self, router):
        """rsyslog names each file for the sender's address. The routers log from
        their out-of-band interface inside the management VRF, so it is the OOB
        address that identifies the router here, not the LAN one."""
        return f"{self.env['SYSLOG_DIR']}/{self.env[f'{router}_OOB_IP']}.log"

    def collector_is_running(self):
        return self.open_collector().run("systemctl is-active rsyslog").strip()

    def collector_listening_on(self):
        return self.open_collector().run(
            f"sudo ss -lunp | grep ':{self.env['SYSLOG_PORT']} ' || echo NONE")

    def collector_files(self):
        return self.open_collector().run(f"sudo ls -l {self.env['SYSLOG_DIR']}")

    # ---- reading what arrived --------------------------------------------
    def collector_text_for(self, router):
        return self.open_collector().run(
            f"sudo cat {self.collector_file_for(router)} 2>/dev/null || true")

    def syslog_messages_for(self, router):
        return self.syslog_messages(self.collector_text_for(router))

    def syslog_messages(self, text):
        return [m.groupdict() for m in MSG_RE.finditer(text)]

    def count_occurrences_for(self, router, needle):
        out = self.open_collector().run(
            f"sudo grep -c -- {needle!r} {self.collector_file_for(router)} 2>/dev/null || echo 0")
        digits = re.findall(r"\d+", out)
        return int(digits[-1]) if digits else 0

    def find_marked_for(self, router, marker):
        return [m for m in self.syslog_messages_for(router) if marker in m["text"]]

    def messages_from_facility(self, messages, facility):
        return [m for m in messages if m["facility"] == facility]

    def syslog_timestamp_skew(self, message_ts, reference_iso):
        """Seconds between a syslog timestamp and a reference time.

        Syslog carries no year, so the reference supplies it -- fine here, and
        misleading only across a New Year boundary.
        """
        ref = datetime.fromisoformat(reference_iso)
        stamp = datetime.strptime(f"{ref.year} {message_ts}", "%Y %b %d %H:%M:%S.%f")
        return abs((stamp - ref).total_seconds())
