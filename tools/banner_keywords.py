"""Robot keywords for the pre-login banner.

The interesting assertion is not that the banner is in the configuration but
that it reaches someone who has not logged in. IOS delivers "banner login" as an
SSH userauth banner, so it arrives during authentication -- which means it can be
captured from a deliberately failed login, with no credentials involved.
"""
import os
import sys

import paramiko

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nms_lib import LAB_DIR, load_env       # noqa: E402


class banner_keywords:
    ROBOT_LIBRARY_SCOPE = "GLOBAL"

    def __init__(self):
        self.env = load_env()

    def expected_banner_text(self):
        """The banner as the provisioner installed it -- same file, no copy."""
        with open(os.path.join(LAB_DIR, self.env["BANNER_FILE"])) as fh:
            return fh.read().rstrip("\n")

    def pre_login_banner_from(self, router, timeout=20):
        """The banner presented to an unauthenticated client.

        Authentication is attempted with a password that is deliberately wrong:
        the point is to prove the banner arrives *before* anyone is let in, so a
        successful login would prove the weaker thing.
        """
        port = int(self.env[f"{router}_SSH"])
        t = paramiko.Transport(("127.0.0.1", port))
        try:
            t.start_client(timeout=int(timeout))
            try:
                t.auth_password(self.env["VM_USER"], "deliberately-wrong-password")
            except paramiko.SSHException:
                pass                            # expected; the banner is the payload
            else:
                raise AssertionError(
                    f"{router} accepted a deliberately wrong password")
            banner = t.get_banner()
            return banner.decode(errors="replace") if banner else ""
        finally:
            t.close()

    def banner_should_match_file(self, banner):
        """Full line-by-line comparison against the source file.

        Only the line endings are normalised: the device sends CRLF and the file
        holds LF. Everything else is compared exactly, so truncation, reordering
        or a stale copy on the device all fail -- which a substring check for one
        memorable phrase would not.
        """
        got = [l.rstrip("\r") for l in banner.strip().splitlines()]
        want = self.expected_banner_text().strip().splitlines()
        if got != want:
            for i, (a, b) in enumerate(zip(got, want)):
                if a != b:
                    raise AssertionError(
                        f"banner differs from {self.env['BANNER_FILE']} at line {i + 1}:\n"
                        f"  device: {a!r}\n  file  : {b!r}")
            raise AssertionError(
                f"banner has {len(got)} lines, the file has {len(want)}")
        return len(got)

    def banner_should_not_disclose(self, banner, *terms):
        """A warning banner that names the platform helps the wrong reader."""
        low = banner.lower()
        found = [t for t in terms if t and t.lower() in low]
        if found:
            raise AssertionError(
                f"the pre-login banner discloses {found}, which tells an "
                f"unauthenticated visitor what they are talking to")
        return True
