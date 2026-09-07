"""Install and start the lab's collectors on the NMS.

Everything the routers send now lands here rather than on h1: syslog into
rsyslog, SNMPv3 traps into snmptrapd, and the same traps a second time into a
raw capture. h1 is a plain cirros host again.

All three run as systemd services rather than being started by the tests. That
makes them always-on -- a test can look back at traps the routers sent
spontaneously -- and it means no suite can leave a stray listener behind. That
last point is not hypothetical: stale busybox listeners on the old h1 collector
once made a negative test pass while nothing was arriving at all.
"""
import base64
import os

SNMP_ENGINE_OID = "1.3.6.1.6.3.10.2.1.1.0"


def rsyslog_conf(env):
    """Write each sender's messages verbatim into its own file.

    %rawmsg% keeps the datagram exactly as IOS framed it -- sequence numbers,
    millisecond timestamp, %FACILITY-SEVERITY-MNEMONIC -- so the tests parse the
    router's own output rather than something rsyslog has reformatted. Files are
    named by source address because IOS puts no hostname in the message.
    """
    return f"""# Managed by tools/nms_collectors.py -- edits will be overwritten.
module(load="imudp")
input(type="imudp" port="{env['SYSLOG_PORT']}")

template(name="LabPath" type="string" string="{env['SYSLOG_DIR']}/%FROMHOST-IP%.log")
template(name="LabRaw"  type="string" string="%rawmsg%\\n")

if $fromhost-ip != "127.0.0.1" then {{
    action(type="omfile" dynaFile="LabPath" template="LabRaw" fileCreateMode="0644")
    stop
}}
"""


def snmptrapd_conf(env, ids):
    """Authenticate and decrypt each router's traps.

    A v3 trap is authenticated by the *sender's* engine and USM keys are
    localised to that engine, so the user must be created once per router with
    that router's engine ID. One engine-less createUser decrypts nothing.
    """
    lines = ["# Managed by tools/nms_collectors.py -- edits will be overwritten.",
             "disableAuthorization no"]
    for router, eid in sorted(ids.items()):
        lines.append(f"# {router}")
        lines.append(f'createUser -e 0x{eid} {env["SNMP_USER"]} '
                     f'SHA "{env["SNMP_AUTH_PASS"]}" AES "{env["SNMP_PRIV_PASS"]}"')
    lines.append(f'authUser log {env["SNMP_USER"]} authpriv')
    return "\n".join(lines) + "\n"


def chrony_conf(env):
    """The NMS becomes the lab's NTP server.

    The out-of-band network has no route to the internet, so the routers cannot
    reach pool.ntp.org across it. The standard answer is a stratum hierarchy: the
    NMS synchronises upstream through its own NAT interface and serves the
    management network, so the public pool is still the source of truth, one hop
    further away.

    "local stratum 10" keeps it serving if the upstream is unreachable -- without
    it a lab with no internet has no time at all, and every NTP test fails for a
    reason that has nothing to do with the lab.
    """
    pools = "\n".join(f"pool {srv} iburst maxsources 2"
                      for srv in env["NTP_SERVERS"].split())
    return f"""# Managed by tools/nms_collectors.py -- edits will be overwritten.
{pools}
allow {env['OOB_NET']}/{env['OOB_PREFIX']}
local stratum 10
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
"""


def tacacs_conf(env):
    """Shrubbery tac_plus with two remote users at different privilege levels.

    Passwords are cleartext here deliberately: this is a throwaway lab and the
    alternative (DES hashes) hides which credential a failing test is using. The
    two users exist so the tests can prove the privilege level is coming from the
    server rather than from the router's own default -- one lands in enable mode,
    the other does not.

    "default service = permit" keeps authorization permissive: this lab is
    proving authentication and privilege assignment, not building a command
    authorization policy.
    """
    return f"""# Managed by tools/nms_collectors.py -- edits will be overwritten.
key = {env['TACACS_KEY']}

accounting file = {env['TACACS_ACCT_LOG']}

user = {env['TACACS_ADMIN_USER']} {{
    default service = permit
    login = cleartext "{env['TACACS_ADMIN_PASS']}"
    service = exec {{
        priv-lvl = {env['TACACS_ADMIN_PRIV']}
    }}
}}

user = {env['TACACS_OPS_USER']} {{
    default service = permit
    login = cleartext "{env['TACACS_OPS_PASS']}"
    service = exec {{
        priv-lvl = {env['TACACS_OPS_PRIV']}
    }}
}}

# The automation account, which every tool in this repo logs in as. It has to
# exist here as well as locally on the routers, because "group ... local" only
# falls through to local when the server is UNREACHABLE -- a reachable server
# that rejects an unknown user is an authoritative no, and IOS honours it. Left
# out, the first router to get AAA becomes unmanageable by the test suite while
# the server is perfectly healthy.
user = {env['VM_USER']} {{
    default service = permit
    login = cleartext "{env['VM_PASS']}"
    service = exec {{
        priv-lvl = 15
    }}
}}
"""


def unit(description, exec_start):
    return f"""[Unit]
Description={description}
After=network-online.target

[Service]
ExecStart={exec_start}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
"""


def engine_ids(n, env):
    """Read every router's snmpEngineID over SNMPv3, as unseparated hex."""
    out = {}
    for r in env["ROUTERS"].split():
        raw = n.run(
            f"snmpget -On -v3 -l authPriv -u {env['SNMP_USER']} -a SHA "
            f"-A {env['SNMP_AUTH_PASS']} -x AES -X {env['SNMP_PRIV_PASS']} "
            f"-t 5 -r 2 {env[f'{r}_LAN_IP']} {SNMP_ENGINE_OID}")
        if "=" not in raw or ":" not in raw.split("=", 1)[1]:
            raise SystemExit(f"[nms] cannot read {r} engine ID: {raw}")
        out[r] = "".join(raw.split("=", 1)[1].split(":", 1)[1].split()).upper()
    return out


def write_file(n, path, content, mode="0644"):
    """Write a root-owned file, base64 encoded to dodge shell quoting entirely."""
    b64 = base64.b64encode(content.encode()).decode()
    out, rc = n.run(f"echo {b64} | base64 -d | sudo tee {path} >/dev/null && "
                    f"sudo chmod {mode} {path} && echo written", rc=True)
    if rc != 0 or "written" not in out:
        raise SystemExit(f"[nms] could not write {path}: {out}")


def configure(n, env, lab_dir):
    # rsyslog drops privileges to the syslog user, so a root-owned directory
    # leaves it unable to create its per-router files -- and it reports that only
    # in its own log, so the symptom looks like traffic never arriving.
    n.run(f"sudo mkdir -p {env['SYSLOG_DIR']} /opt/lab && "
          f"sudo chown syslog:adm {env['SYSLOG_DIR']} && "
          f"sudo chmod 775 {env['SYSLOG_DIR']}")

    write_file(n, "/etc/rsyslog.d/10-lab.conf", rsyslog_conf(env))
    write_file(n, "/etc/chrony/chrony.conf", chrony_conf(env))
    write_file(n, "/etc/tacacs+/tac_plus.conf", tacacs_conf(env), mode="0600")
    # -G keeps it in the foreground so systemd can supervise it directly; the
    # packaged SysV script daemonises and leaves systemd unable to track it
    write_file(n, "/etc/systemd/system/tacacs-lab.service",
               unit("TACACS+ server for the lab",
                    f"/usr/sbin/tac_plus -G -C /etc/tacacs+/tac_plus.conf "
                    f"-l {env['TACACS_LOG']} -p {env['TACACS_PORT']}"))
    with open(os.path.join(lab_dir, "tools", "trapcap.py")) as fh:
        write_file(n, "/opt/lab/trapcap.py", fh.read(), mode="0755")

    ids = engine_ids(n, env)
    print("[nms] engine IDs: " + ", ".join(f"{r}={e}" for r, e in sorted(ids.items())))
    # net-snmp copies createUser into its persistent store the first time it reads
    # the config; clearing that is what makes a changed key or engine ID take hold
    n.run("sudo rm -f /var/lib/snmp/snmptrapd.conf")
    write_file(n, "/etc/snmp/snmptrapd.conf", snmptrapd_conf(env, ids), mode="0600")

    # -Osq keeps varbinds short and unquoted; -m '' loads no MIBs, which are not
    # installed, so OIDs stay numeric and parsable
    write_file(n, "/etc/systemd/system/snmptrapd.service",
               unit("SNMP trap receiver for the lab",
                    f"/usr/sbin/snmptrapd -f -Lf {env['SNMP_TRAPD_LOG']} -Osq -m ''"))
    write_file(n, "/etc/systemd/system/lab-trapcap.service",
               unit("Raw SNMP trap capture for the lab",
                    f"/usr/bin/python3 /opt/lab/trapcap.py {env['SNMP_TRAP_RAW_PORT']} "
                    f"{env['SYSLOG_DIR']}/traps-raw.log"))

    n.run("sudo systemctl daemon-reload")
    # the packaged snmptrapd unit would fight ours for port 162
    n.run("sudo systemctl disable --now snmpd >/dev/null 2>&1 || true")
    # timesyncd would fight chrony for the NTP client role
    n.run("sudo systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true")
    # The package's postinst starts tac_plus through its SysV script, which binds
    # port 49 outside systemd's supervision -- so disabling the unit is not
    # enough and ours fails to bind. Stop it by every route, then make sure no
    # unsupervised copy is left holding the port.
    n.run("sudo systemctl disable --now tacacs_plus >/dev/null 2>&1 || true")
    n.run("sudo /etc/init.d/tacacs_plus stop >/dev/null 2>&1 || true")
    n.run("sudo systemctl stop tacacs-lab >/dev/null 2>&1 || true")
    n.run("sudo pkill -x tac_plus >/dev/null 2>&1 || true")
    for u in ("rsyslog", "snmptrapd", "lab-trapcap", "chrony", "tacacs-lab"):
        n.run(f"sudo systemctl enable {u} >/dev/null 2>&1; sudo systemctl restart {u}")
    states = n.run("systemctl is-active rsyslog snmptrapd lab-trapcap chrony tacacs-lab | tr '\\n' ' '")
    print(f"[nms] services: {states.strip()}")
    if states.split().count("active") != 5:
        detail = n.run("systemctl --no-pager -n 15 status snmptrapd lab-trapcap rsyslog chrony tacacs-lab 2>&1 | tail -60")
        raise SystemExit(f"[nms] a service did not start: {states}\n{detail}")
