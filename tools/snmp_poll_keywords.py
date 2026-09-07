"""Robot keywords for SNMPv3 polling from the NMS.

The three cirros hosts cannot do this: busybox has no SNMP tooling, which is why
the trap tests in 16 decode BER by hand. The NMS is a real Ubuntu VM with
net-snmp, so polling here runs the same snmpget/snmpwalk a network engineer
would run, and the router's answers are compared against its own CLI output.

MIB text files are not installed (they are non-free on Ubuntu), so every OID is
numeric. The names are spelled out in the test suite.
"""
import os
import re
import shlex
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nms_lib import Nms, load_env          # noqa: E402

# a value line looks like: .1.3.6.1.2.1.1.5.0 = STRING: "c8000v-r1"
# -On keeps the OID numeric; without MIBs net-snmp would otherwise print the
# half-translated "iso.3.6.1..." form, which is harder to assert against.
VALUE_RE = re.compile(r"^(?P<oid>\S+)\s+=\s+(?P<type>[A-Za-z0-9-]+):\s*(?P<value>.*)$")


class snmp_poll_keywords:
    ROBOT_LIBRARY_SCOPE = "GLOBAL"

    def __init__(self):
        self.env = load_env()
        self._nms = None

    # ---- session ---------------------------------------------------------
    def open_nms(self):
        if self._nms is None:
            self._nms = Nms(self.env).connect()
        return self._nms

    def close_nms(self):
        if self._nms is not None:
            self._nms.close()
            self._nms = None

    def nms_command(self, cmd):
        return self.open_nms().run(cmd)

    def nms_tool_versions(self):
        """Evidence that this really is net-snmp, not something hand rolled."""
        return self.open_nms().run(
            "snmpget --version 2>&1 | head -2; snmpwalk --version 2>&1 | head -1")

    # ---- building the snmp command --------------------------------------
    def _v3_args(self, user=None, auth_pass=None, priv_pass=None, level="authPriv",
                 auth_proto=None, priv_proto=None):
        e = self.env
        args = ["-v3", "-l", level, "-u", user or e["SNMP_USER"]]
        if level in ("authNoPriv", "authPriv"):
            args += ["-a", auth_proto or e.get("SNMP_AUTH_PROTO", "SHA"),
                     "-A", auth_pass or e["SNMP_AUTH_PASS"]]
        if level == "authPriv":
            args += ["-x", priv_proto or e.get("SNMP_PRIV_PROTO", "AES"),
                     "-X", priv_pass or e["SNMP_PRIV_PASS"]]
        return args

    def _run(self, tool, target, oid, timeout="3", retries="1", **kw):
        args = [tool, "-On"] + self._v3_args(**kw) + ["-t", timeout, "-r", retries, target, oid]
        cmd = " ".join(shlex.quote(a) for a in args)
        out, rc = self.open_nms().run(cmd, rc=True)
        return cmd, out, rc

    # ---- positive polling ------------------------------------------------
    def snmp_get(self, target, oid, **kw):
        """One SNMPv3 GET. Fails the test if the agent does not answer."""
        cmd, out, rc = self._run("snmpget", target, oid, **kw)
        if rc != 0:
            raise AssertionError(f"snmpget failed (rc={rc})\n  $ {cmd}\n  {out}")
        return out

    def snmp_get_value(self, target, oid, **kw):
        """The value half of a GET response, with the type prefix stripped."""
        out = self.snmp_get(target, oid, **kw)
        m = VALUE_RE.match(out.strip().splitlines()[0])
        if not m:
            raise AssertionError(f"unparsable snmpget response: {out!r}")
        return m.group("value").strip().strip('"')

    def snmp_walk(self, target, oid, **kw):
        cmd, out, rc = self._run("snmpwalk", target, oid, **kw)
        if rc != 0:
            raise AssertionError(f"snmpwalk failed (rc={rc})\n  $ {cmd}\n  {out}")
        return out

    def snmp_walk_values(self, target, oid, **kw):
        """Walk one subtree and return just the values, in OID order."""
        values = []
        for line in self.snmp_walk(target, oid, **kw).splitlines():
            m = VALUE_RE.match(line.strip())
            if m:
                values.append(m.group("value").strip().strip('"'))
        return values

    def snmp_walk_count(self, target, oid, **kw):
        return len(self.snmp_walk_values(target, oid, **kw))

    # ---- negative polling ------------------------------------------------
    def snmp_get_should_fail(self, target, oid, expected=None, **kw):
        """Assert the agent refuses these credentials.

        A router that rejects authentication either answers with a usmStats
        report (net-snmp prints 'Authentication failure') or stays silent
        (net-snmp times out). Both are refusals; a success is the failure case.
        """
        cmd, out, rc = self._run("snmpget", target, oid, timeout="2", retries="0", **kw)
        if rc == 0:
            raise AssertionError(
                f"agent ANSWERED credentials that should have been refused\n"
                f"  $ {cmd}\n  {out}")
        if expected and expected.lower() not in out.lower():
            raise AssertionError(
                f"refused, but not in the expected way (wanted {expected!r})\n"
                f"  $ {cmd}\n  {out}")
        return out.strip() or f"(no response, rc={rc})"

    def snmp_v2c_get_should_fail(self, target, oid, community="public"):
        """v2c must get nothing: the routers define no community at all."""
        cmd = (f"snmpget -On -v2c -c {shlex.quote(community)} -t 2 -r 0 "
               f"{shlex.quote(target)} {shlex.quote(oid)}")
        out, rc = self.open_nms().run(cmd, rc=True)
        if rc == 0:
            raise AssertionError(f"router answered SNMPv2c!\n  $ {cmd}\n  {out}")
        return out.strip() or f"(no response, rc={rc})"

    # ---- helpers ---------------------------------------------------------
    def sysuptime_ticks(self, target, **kw):
        """sysUpTime as an integer of hundredths of a second."""
        raw = self.snmp_get(target, "1.3.6.1.2.1.1.3.0", **kw)
        m = re.search(r"\((\d+)\)", raw)
        if not m:
            raise AssertionError(f"no timeticks in {raw!r}")
        return int(m.group(1))

    def wait_for_snmp_agent(self, target, timeout=120, interval=10, **kw):
        """Poll until the agent answers; the SNMP process starts after the CLI."""
        deadline = time.time() + int(timeout)
        last = ""
        while time.time() < deadline:
            cmd, out, rc = self._run("snmpget", target, "1.3.6.1.2.1.1.5.0", **kw)
            if rc == 0:
                return out
            last = out
            time.sleep(int(interval))
        raise AssertionError(f"{target} never answered SNMPv3: {last}")
