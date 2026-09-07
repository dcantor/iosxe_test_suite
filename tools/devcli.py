"""Minimal, reload-safe SSH driver for the C8000V lab.

SSHLibrary's Write waits for the command echo, which never arrives once the
device tears the session down -- so reloads must use write_bare.
"""
import re
import socket
import time

from SSHLibrary import SSHLibrary

# The config-mode label can contain characters beyond word and dash --
# "(config-sg-tacacs+)" is the one that caught this out -- so the class has
# to admit them or the driver hangs waiting for a prompt that already arrived.
PROMPT_RE = r"(?:^|[\r\n])[\w][\w.-]*(?:\([\w.+-]+\))?[#>][ \t]*\Z"
PROMPT = "REGEXP:" + PROMPT_RE
# IOS asks for confirmation on some destructive commands ("delete child
# entries? [no]:"). Without answering, the read blocks until timeout.
CONFIRM_RE = r"\[(?:yes/no|confirm|no|yes)\][:\s]*$"


def port_open(host, port, timeout=5):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def wait_for_port(host, port, timeout=900, settle=25):
    """Block until the port accepts, then let sshd finish coming up."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if port_open(host, port):
            time.sleep(settle)
            return True
        time.sleep(5)
    return False


class Device:
    def __init__(self, name, host="127.0.0.1", port=22, user="lab", password=""):
        self.name, self.host, self.port = name, host, port
        self.user, self.password = user, password
        self.s = None

    def connect(self, timeout="90s", retries=3):
        last = None
        for _ in range(retries):
            try:
                self.s = SSHLibrary(timeout=timeout)
                self.s.open_connection(self.host, port=self.port, width=200, prompt=PROMPT)
                self.s.login(self.user, self.password, delay="2s")
                self.run("terminal length 0")
                self.run("terminal width 200")
                return self
            except Exception as exc:            # noqa: BLE001 - retry any login failure
                last = exc
                self.close()
                time.sleep(15)
        raise RuntimeError(f"{self.name}: could not log in: {last}")

    def run(self, command):
        self.s.write(command)
        out = self.s.read_until_prompt(strip_prompt=True)
        return out.replace(command, "", 1).strip()

    def run_confirm(self, command, answer="yes", rounds=4):
        """Run a command that may ask for confirmation, answering it.

        write_bare is used rather than write because SSHLibrary's write waits for
        the command echo, which never completes while the device is sitting on a
        question.
        """
        self.s.write_bare(command + "\r")
        out = ""
        for _ in range(rounds):
            chunk = self.s.read_until_regexp(f"(?:{CONFIRM_RE})|(?:{PROMPT_RE})")
            out += chunk
            if re.search(CONFIRM_RE, chunk):
                self.s.write_bare(answer + "\r")
                continue
            break
        return out.replace(command, "", 1).strip()

    def config(self, lines, ignore_errors=False):
        """Apply config lines; raises on rejection unless ignore_errors."""
        results = []
        self.run("configure terminal")
        for line in lines:
            out = self.run(line)
            results.append((line, out))
            if not ignore_errors and "%" in out and "Invalid input" in out:
                self.run("end")
                raise RuntimeError(f"{self.name}: rejected {line!r}: {out.strip()}")
        self.run("end")
        return results

    def config_banner(self, kind, text, delim="^"):
        """Install a multi-line banner.

        Banner entry is a mode of its own: after "banner login ^" the device
        echoes nothing and shows no prompt until the closing delimiter arrives,
        so the usual line-at-a-time config loop waits for a prompt that will not
        come until the whole block is sent. Everything goes out with write_bare
        and the prompt is read once at the end.
        """
        if delim in text:
            raise ValueError(f"banner text contains the delimiter {delim!r}")
        self.run("configure terminal")
        self.s.write_bare(f"banner {kind} {delim}\r")
        for line in text.rstrip("\n").split("\n"):
            self.s.write_bare(line + "\r")
        self.s.write_bare(delim + "\r")
        self.s.read_until_prompt()
        self.run("end")

    def save(self):
        return self.run("write memory")

    def reload_and_wait(self, timeout=900):
        """Reload and block until SSH is usable again. Saves first."""
        self.save()
        self.s.write_bare("reload\r")
        time.sleep(3)
        try:
            out = self.s.read(delay="2s")
        except Exception:                        # noqa: BLE001
            out = ""
        # "System configuration has been modified. Save? [yes/no]" if save raced
        if "yes/no" in out:
            self.s.write_bare("no\r")
            time.sleep(2)
        self.s.write_bare("\r")                  # "Proceed with reload? [confirm]"
        time.sleep(5)
        self.close()
        # Let the guest actually go down before we start polling for it.
        time.sleep(45)
        if not wait_for_port(self.host, self.port, timeout=timeout):
            raise RuntimeError(f"{self.name}: did not come back after reload")
        return self.connect()

    def close(self):
        try:
            if self.s:
                self.s.close_all_connections()
        except Exception:                        # noqa: BLE001
            pass
        self.s = None
