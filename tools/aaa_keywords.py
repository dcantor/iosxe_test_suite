"""Robot keywords for TACACS+ authentication against the server on the NMS.

Logging in is the whole point here, so these open their own SSH sessions rather
than reusing the shared ones: a keyword that asserts a login fails cannot be
written against a connection that is already open.
"""
import os
import re
import sys

from SSHLibrary import SSHLibrary

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nms_lib import Nms, load_env          # noqa: E402

# the config-mode label can contain '+' -- "(config-sg-tacacs+)"
PROMPT = r"REGEXP:(?:^|[\r\n])[\w][\w.-]*(?:\([\w.+-]+\))?[#>][ \t]*\Z"
PRIV_RE = re.compile(r"Current privilege level is (\d+)")


class aaa_keywords:
    ROBOT_LIBRARY_SCOPE = "GLOBAL"

    def __init__(self):
        self.env = load_env()
        self._nms = None

    # ---- the TACACS server ------------------------------------------------
    def open_tacacs_server(self):
        if self._nms is None:
            self._nms = Nms(self.env).connect()
        return self._nms

    def close_tacacs_server(self):
        if self._nms is not None:
            self._nms.close()
            self._nms = None

    def tacacs_service_state(self):
        return self.open_tacacs_server().run("systemctl is-active tacacs-lab").strip()

    def tacacs_listening_on(self):
        return self.open_tacacs_server().run(
            f"sudo ss -ltnp | grep ':{self.env['TACACS_PORT']} ' || echo NONE")

    def tacacs_accounting_log(self, lines=200):
        return self.open_tacacs_server().run(
            f"sudo tail -{int(lines)} {self.env['TACACS_ACCT_LOG']} 2>/dev/null || true")

    def tacacs_configured_users(self):
        """The users the server knows, read from its own configuration."""
        out = self.open_tacacs_server().run("sudo grep -oE '^user = [A-Za-z0-9_-]+' /etc/tacacs+/tac_plus.conf")
        return [l.split("=", 1)[1].strip() for l in out.splitlines() if "=" in l]

    # ---- logging in to a router -------------------------------------------
    def _session(self, router):
        s = SSHLibrary(timeout="45s")
        s.open_connection("127.0.0.1", port=int(self.env[f"{router}_SSH"]),
                          width=200, prompt=PROMPT)
        return s

    def login_privilege_level(self, router, user, password):
        """Log in and report the privilege level granted. Fails if login fails."""
        s = self._session(router)
        try:
            s.login(user, password, delay="2s")
            s.write("show privilege")
            out = s.read_until_prompt(strip_prompt=True)
            m = PRIV_RE.search(out)
            if not m:
                raise AssertionError(f"{router}: no privilege level in {out!r}")
            return int(m.group(1))
        finally:
            s.close_all_connections()

    def login_should_fail(self, router, user, password):
        """Assert a login is refused. Returns the refusal for the log."""
        s = self._session(router)
        try:
            s.login(user, password, delay="2s")
        except Exception as exc:                # noqa: BLE001 - any refusal will do
            return f"{type(exc).__name__}: {exc}"[:200]
        else:
            raise AssertionError(
                f"{router} accepted a login for {user!r} that should have been refused")
        finally:
            s.close_all_connections()

    # ---- VTY access control ----------------------------------------------
    def ssh_banner_from(self, source_ip, target_ip, timeout=6):
        """Open a TCP session to a router's SSH port from a chosen source address.

        Returns the SSH banner when the connection is allowed, or the error text
        when it is not. Reading the banner rather than completing a login is
        deliberate: "access-class in" is enforced before authentication, so the
        banner is exactly the point at which a permitted source and a denied one
        diverge, and nothing here depends on holding valid credentials.
        """
        script = (
            "import socket,sys\n"
            "s=socket.socket()\n"
            f"s.settimeout({int(timeout)})\n"
            f"s.bind(('{source_ip}',0))\n"
            "try:\n"
            f"    s.connect(('{target_ip}',22))\n"
            "    print(s.recv(64).decode(errors='replace').strip() or 'EMPTY')\n"
            "except Exception as e:\n"
            "    print(f'REFUSED {type(e).__name__}: {e}')\n")
        return self.open_tacacs_server().run(
            f"python3 -c {script!r}".replace("\\n", "\n"))

    def ssh_should_be_permitted_from(self, source_ip, target_ip):
        out = self.ssh_banner_from(source_ip, target_ip)
        if not out.startswith("SSH-"):
            raise AssertionError(
                f"{source_ip} -> {target_ip}:22 did not get an SSH banner: {out}")
        return out

    def ssh_should_be_denied_from(self, source_ip, target_ip):
        out = self.ssh_banner_from(source_ip, target_ip)
        if out.startswith("SSH-"):
            raise AssertionError(
                f"{source_ip} -> {target_ip}:22 was allowed and answered {out!r}")
        return out

    def accounting_should_record(self, text, user, router):
        """A start or stop record for this user from this router's OOB address."""
        addr = self.env[f"{router}_OOB_IP"]
        for line in text.splitlines():
            if addr in line and f"\t{user}\t" in line:
                return line
        raise AssertionError(
            f"no accounting record for {user} from {router} ({addr})")
