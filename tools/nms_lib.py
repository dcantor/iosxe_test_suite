"""Shared SSH session for the NMS (a real Ubuntu VM, unlike the cirros hosts).

Everything here uses SSHLibrary.execute_command rather than the write/
read_until_prompt dance the router driver needs: the NMS runs a normal OpenSSH
server, so a plain exec channel gives clean stdout with no prompt matching and
no chance of output being mistaken for a prompt.
"""
import os
import socket
import time

from SSHLibrary import SSHLibrary

try:
    from robot.api import logger as _robot_logger
except ImportError:                     # running outside Robot
    _robot_logger = None

LAB_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NMS_MARKER = "nms $ "


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
    """QEMU's forwarded port accepts before sshd listens, so wait for the banner."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", int(port)), timeout=5) as s:
                s.settimeout(5)
                if s.recv(4).startswith(b"SSH-"):
                    return True
        except OSError:
            pass
        time.sleep(5)
    return False


class Nms:
    def __init__(self, env=None, timeout="120s"):
        self.env = env or load_env()
        self.port = int(self.env["NMS_SSH"])
        self.ip = self.env["NMS_IP"]
        self._s = SSHLibrary(timeout=timeout)
        self._open = False

    def connect(self):
        if self._open:
            return self
        if not wait_for_ssh(self.port):
            raise RuntimeError(f"NMS: no SSH banner on port {self.port}")
        self._s.open_connection("127.0.0.1", port=self.port, width=250)
        self._s.login(self.env["NMS_USER"], self.env["NMS_PASS"], delay="1s")
        self._open = True
        return self

    def close(self):
        if self._open:
            self._s.close_connection()
            self._open = False

    def run(self, cmd, rc=False):
        """Run one command; returns stdout+stderr, or (output, rc) when rc=True.

        stderr is merged in deliberately: net-snmp reports refusals there
        ("Authentication failure...", "Timeout: No Response from..."), and those
        messages are the evidence the negative tests are asserting on.
        """
        self.connect()
        out, err, code = self._s.execute_command(cmd, return_rc=True,
                                                 return_stderr=True, return_stdout=True)
        combined = "\n".join(x for x in (out.strip(), err.strip()) if x)
        # Logged with a stable marker so tools/make_report.py can lift the exact
        # command into the evidence PDF, the same way router commands appear.
        if _robot_logger is not None:
            _robot_logger.info(f"{NMS_MARKER}{cmd}\n{combined}")
        return (combined, code) if rc else combined.strip()
