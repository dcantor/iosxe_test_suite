#!/usr/bin/env python3
"""Provision the hub-and-spoke lab.

Phases, in order:
  license  -- set the boot level, save, reload, wait (the crypto CLI does not
              exist until this is active, and it only takes effect on reload)
  ipsec    -- IKEv2 + static VTI: one tunnel per spoke, all terminating on the hub
  bgp      -- eBGP hub<->spoke, advertising each router's Loopback1 and LAN

A licence reload wipes crypto config that was rejected at boot, so the licence
phase re-applies the later phases when it actually reloads.
"""
import argparse
import os
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from devcli import Device  # noqa: E402

LAB_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_env(path=None):
    env = {}
    with open(path or os.path.join(LAB_DIR, "lab.env")) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, val = line.split("=", 1)
                env[key.strip()] = val.strip().strip('"')
    return env


def routers(env):
    return env["ROUTERS"].split()


def spokes(env):
    return env["SPOKES"].split()


def device(env, router):
    return Device(
        name=env[f"{router}_NAME"],
        port=int(env[f"{router}_SSH"]),
        user=env["VM_USER"],
        password=env["VM_PASS"],
    )


def ipsec_config(env, router):
    """One VTI per spoke. The hub carries one tunnel per spoke; a spoke carries one."""
    role = env[f"{router}_ROLE"]
    hub = env["HUB"]
    peers = ([(s, env[f"{s}_LINK_LOCAL"]) for s in spokes(env)] if role == "hub"
             else [(hub, env[f"{router}_LINK_HUB"])])

    lines = [
        "crypto ikev2 proposal LAB-PROP",
        " encryption aes-cbc-256",
        " integrity sha256",
        " group 14",
        "exit",
        "crypto ikev2 policy LAB-POL",
        " proposal LAB-PROP",
        "exit",
        "crypto ikev2 keyring LAB-KR",
    ]
    for name, addr in peers:
        lines += [f" peer {name}", f"  address {addr}",
                  f"  pre-shared-key {env['IPSEC_PSK']}", " exit"]
    lines += ["exit", "crypto ikev2 profile LAB-PROF"]
    for _, addr in peers:
        lines.append(f" match identity remote address {addr} 255.255.255.255")
    lines += [
        " authentication local pre-share",
        " authentication remote pre-share",
        " keyring local LAB-KR",
        "exit",
        "crypto ipsec transform-set LAB-TS esp-aes 256 esp-sha256-hmac",
        " mode tunnel",
        "exit",
        "crypto ipsec profile LAB-IPSEC",
        " set transform-set LAB-TS",
        " set ikev2-profile LAB-PROF",
        "exit",
    ]

    if role == "hub":
        for s in spokes(env):
            tid = env[f"{s}_HUB_TUNNEL_ID"]
            lines += [
                f"interface Tunnel{tid}",
                f" description to {env[f'{s}_NAME']}",
                f" ip address {env[f'{s}_TUNNEL_HUB']} {env['TUNNEL_MASK']}",
                f" tunnel source {env[f'{s}_HUB_INTF']}",
                " tunnel mode ipsec ipv4",
                f" tunnel destination {env[f'{s}_LINK_LOCAL']}",
                " tunnel protection ipsec profile LAB-IPSEC",
                " no shutdown",
                "exit",
                f"ip route {env[f'{s}_LOOPBACK']} 255.255.255.255 Tunnel{tid}",
            ]
    else:
        lines += [
            "interface Tunnel0",
            f" description to the hub ({env[f'{hub}_NAME']})",
            f" ip address {env[f'{router}_TUNNEL_LOCAL']} {env['TUNNEL_MASK']}",
            " tunnel source GigabitEthernet2",
            " tunnel mode ipsec ipv4",
            f" tunnel destination {env[f'{router}_LINK_HUB']}",
            " tunnel protection ipsec profile LAB-IPSEC",
            " no shutdown",
            "exit",
            f"ip route {env[f'{hub}_LOOPBACK']} 255.255.255.255 Tunnel0",
        ]
    return lines


PREFIX_CLASSES = (("BGP_PREFIX", "255.255.255.255", 32, "COMMUNITY_LOOPBACK_ID", "LO"),
                  ("NAT_NET", "255.255.255.0", 24, "COMMUNITY_NAT_ID", "NAT"),
                  ("LAN_NET", None, 24, "COMMUNITY_LAN_ID", "LAN"))


def originated_prefixes(env, router):
    """Every prefix a router originates: (network, length, community, class tag).

    Three, not two: the /32 BGP loopback and the LAN come from the BGP phase, but
    the NAT domain is advertised by the NAT phase (a Null0 route plus a network
    statement). A whitelist built from the BGP phase alone would silently drop
    the NAT prefix and break every host-to-host test through NAT.

    Each carries a community of <origin ASN>:<class>, which names both where the
    prefix came from and what kind of prefix it is.
    """
    out = []
    for key, _mask, length, cls_key, tag in PREFIX_CLASSES:
        out.append((env[f"{router}_{key}"], length,
                    f"{env[f'{router}_ASN']}:{env[cls_key]}", tag))
    return out


def valid_communities(env):
    """Every community that legitimately exists in this topology."""
    return [c for r in env["ROUTERS"].split()
            for _net, _len, c, _tag in originated_prefixes(env, r)]


def valid_as_paths(env, router, peer):
    """Regexes for the AS paths that may legitimately arrive from one peer.

    Anchored deliberately. A spoke may only ever originate its own prefixes, so
    exactly one AS appears; from the hub, a prefix is either the hub's own or the
    far spoke's re-advertised through it, so at most two. Anything longer means
    a path this topology cannot produce -- a spoke transiting, or a loop.
    """
    hub = env["HUB"]
    if router == hub:
        return [f"^{env[f'{peer}_ASN']}$"]
    paths = [f"^{env[f'{hub}_ASN']}$"]
    for other in spokes(env):
        if other != router:
            paths.append(f"^{env[f'{hub}_ASN']}_{env[f'{other}_ASN']}$")
    return paths


def bgp_policy_config(env, router, peers):
    """Per-peer inbound and outbound policy.

    Outbound: one route-map clause per prefix class, each matching a prefix-list
    and setting that class's community. The clauses are the whitelist -- the
    route-map's implicit deny is what stops anything unnamed being advertised.
    The hub gets a further clause re-advertising the far spoke's prefixes with no
    "set", so their origin communities survive the hop.

    Inbound: a single permit clause matching both a community-list of the nine
    communities this topology can produce and an AS-path list of the paths this
    peer can legitimately send. Both must match, so a prefix with an unknown
    community *or* an unexpected AS path falls through to the implicit deny.

    "send-community" matters more than it looks: without it IOS strips
    communities on eBGP, every prefix would arrive untagged, and the inbound
    community match would drop the entire table.
    """
    asn = env[f"{router}_ASN"]
    lines = ["ip bgp-community new-format"]

    # community-list of everything valid anywhere in the topology. Separate
    # permit lines, because multiple communities on one line mean AND, not OR.
    for community in valid_communities(env):
        lines.append(f"ip community-list standard CL-VALID permit {community}")

    own = originated_prefixes(env, router)
    for net, length, _community, tag in own:
        lines.append(f"ip prefix-list PL-OWN-{tag} seq 5 permit {net}/{length}")

    for index, (peer, addr) in enumerate(peers):
        # AS-path list numbers must not collide between a hub's two peers
        acl = 10 + index * 10
        for path in valid_as_paths(env, router, peer):
            lines.append(f"ip as-path access-list {acl} permit {path}")

        seq = 10
        for net, length, community, tag in own:
            lines += [
                f"route-map RM-OUT-{peer} permit {seq}",
                f" description {router}'s own {tag}, tagged {community}",
                f" match ip address prefix-list PL-OWN-{tag}",
                f" set community {community}",
                "exit",
            ]
            seq += 10
        if env[f"{router}_ROLE"] == "hub":
            for far in spokes(env):
                if far == peer:
                    continue
                for net, length, _c, tag in originated_prefixes(env, far):
                    lines.append(f"ip prefix-list PL-FAR-{far} seq {seq} permit {net}/{length}")
                    seq += 5
                lines += [
                    f"route-map RM-OUT-{peer} permit {seq}",
                    f" description re-advertise {far}, preserving its communities",
                    f" match ip address prefix-list PL-FAR-{far}",
                    "exit",
                ]
                seq += 10

        lines += [
            f"route-map RM-IN-{peer} permit 10",
            f" description accept only known communities on an AS path {peer} can produce",
            f" match community CL-VALID",
            f" match as-path {acl}",
            "exit",
        ]
    return lines


def bgp_policy_teardown(env, router, peers):
    """Community-lists, prefix-lists, as-path lists and route-maps all append
    rather than replace, so re-provisioning without this widens the policy a
    little more each time -- silently, and always in the permissive direction."""
    lines = ["no ip community-list standard CL-VALID"]
    for _key, _mask, _len, _cls, tag in PREFIX_CLASSES:
        lines.append(f"no ip prefix-list PL-OWN-{tag}")
    for sp in spokes(env):
        lines.append(f"no ip prefix-list PL-FAR-{sp}")
    for index, (peer, _addr) in enumerate(peers):
        lines.append(f"no ip as-path access-list {10 + index * 10}")
        lines.append(f"no route-map RM-OUT-{peer}")
        lines.append(f"no route-map RM-IN-{peer}")
    return lines


def advertised_to(env, router, peer):
    """What `router` is allowed to advertise to `peer`, as (network, length)."""
    allowed = [(n, l) for n, l, _c, _t in originated_prefixes(env, router)]
    if env[f"{router}_ROLE"] == "hub":
        for other in spokes(env):
            if other != peer:
                allowed += [(n, l) for n, l, _c, _t in originated_prefixes(env, other)]
    return allowed


def _peer_list(env, router):
    """The (name, address) peers this router faces, as the policy builders see them."""
    hub = env["HUB"]
    if env[f"{router}_ROLE"] == "hub":
        return [(sp, env[f"{sp}_TUNNEL_LOCAL"] if f"{sp}_TUNNEL_LOCAL" in env
                 else env[f"{sp}_DMVPN_IP"]) for sp in spokes(env)]
    return [(hub, env[f"{router}_TUNNEL_HUB"] if f"{router}_TUNNEL_HUB" in env
             else env[f"{hub}_DMVPN_IP"])]


def bgp_config(env, router, skip_teardown=False):
    """eBGP over the tunnels. Spokes peer only with the hub; the hub re-advertises
    between them, which is what gives spoke-to-spoke reachability."""
    role = env[f"{router}_ROLE"]
    hub = env["HUB"]
    neighbors = ([(env[f"{s}_TUNNEL_LOCAL"], env[f"{s}_ASN"], s) for s in spokes(env)]
                 if role == "hub"
                 else [(env[f"{router}_TUNNEL_HUB"], env[f"{hub}_ASN"], hub)])
    peers = [(name, addr) for addr, _, name in neighbors]
    # BFD runs on the tunnels, because that is where the peer addresses live
    tunnels = ([f"Tunnel{env[f'{sp}_HUB_TUNNEL_ID']}" for sp in spokes(env)]
               if role == "hub" else ["Tunnel0"])

    lines = [] if skip_teardown else bgp_policy_teardown(env, router, peers)
    lines += bgp_policy_config(env, router, peers)
    lines += [
        "interface Loopback1",
        " description BGP-advertised prefix",
        f" ip address {env[f'{router}_BGP_PREFIX']} 255.255.255.255",
        "exit",
    ]
    for t in tunnels:
        lines += [
            f"interface {t}",
            # No echo knob here: echo mode loops packets back through the peer's
            # data plane and does not apply to a tunnel, so IOS-XE does not offer
            # "bfd echo" on one at all. These sessions are async by construction.
            f" bfd interval {env['BFD_INTERVAL']} min_rx {env['BFD_MIN_RX']}"
            f" multiplier {env['BFD_MULTIPLIER']}",
            "exit",
        ]
    lines += [
        f"router bgp {env[f'{router}_ASN']}",
        f" bgp router-id {env[f'{router}_LOOPBACK']}",
        " bgp log-neighbor-changes",
    ]
    for addr, peer_asn, _peer in neighbors:
        lines += [
            f" neighbor {addr} remote-as {peer_asn}",
            f" neighbor {addr} password {env['BGP_PASSWORD']}",
            f" neighbor {addr} timers {env['BGP_KEEPALIVE']} {env['BGP_HOLDTIME']}",
            # tear the session down on BFD loss instead of waiting out the hold time
            f" neighbor {addr} fall-over bfd",
            # without this IOS strips communities on eBGP and the inbound
            # community match would reject every prefix
            f" neighbor {addr} send-community both",
            # a peer that floods us should take itself out rather than be absorbed;
            # no "restart", so recovery is deliberate and the event stays visible
            f" neighbor {addr} maximum-prefix {env['BGP_MAX_PREFIX']}"
            f" {env['BGP_MAX_PREFIX_WARN']}",
        ]
    lines += [
        " address-family ipv4 unicast",
        f"  network {env[f'{router}_BGP_PREFIX']} mask 255.255.255.255",
        f"  network {env[f'{router}_LAN_NET']} mask {env['LAN_MASK']}",
    ]
    for addr, _asn, peer in neighbors:
        lines.append(f"  neighbor {addr} activate")
        lines.append(f"  neighbor {addr} route-map RM-OUT-{peer} out")
        lines.append(f"  neighbor {addr} route-map RM-IN-{peer} in")
    lines += [" exit-address-family", "exit"]
    return lines


def _octets(net):
    return net.rsplit(".", 1)[0]


def static_pairs(env, router):
    """[(inside, mapped), ...] for the router's statically mapped host addresses."""
    lan = _octets(env[f"{router}_LAN_NET"])
    nat = _octets(env[f"{router}_NAT_NET"])
    n = int(env["NAT_STATIC_COUNT"])
    ho = int(env["STATIC_HOST_OFFSET"])
    mo = int(env["STATIC_MAP_OFFSET"])
    return [(f"{lan}.{ho+i}", f"{nat}.{mo+i}") for i in range(n)]


def dynamic_addresses(env, router):
    lan = _octets(env[f"{router}_LAN_NET"])
    o = int(env["DYNAMIC_HOST_OFFSET"])
    return [f"{lan}.{o+i}" for i in range(int(env["NAT_DYNAMIC_COUNT"]))]


def pool_bounds(env, router):
    nat = _octets(env[f"{router}_NAT_NET"])
    o = int(env["POOL_OFFSET"])
    return f"{nat}.{o}", f"{nat}.{o + int(env['NAT_DYNAMIC_COUNT']) - 1}"


def nat_config(env, router):
    """Static one-to-one source NAT plus a dynamic pool, for the host behind
    this router.

    The route-map is what makes this coexist with the untranslated LAN path: only
    traffic aimed at the NAT domain is rewritten. Without it every router would
    rewrite its own host's source on replies too, and a ping would come back from
    an address the sender never sent to.

    The dynamic rule has no "overload", so each inside address takes its own pool
    address rather than sharing one by port.
    """
    statics = static_pairs(env, router)
    dyn = dynamic_addresses(env, router)
    pool_start, pool_end = pool_bounds(env, router)
    site = env[f"{router}_NAT_NET"]
    domain, wild = env["NAT_DOMAIN"], env["NAT_DOMAIN_WILDCARD"]
    tunnels = ([f"Tunnel{env[f'{sp}_HUB_TUNNEL_ID']}" for sp in spokes(env)]
               if env[f"{router}_ROLE"] == "hub" else ["Tunnel0"])

    lines = ["ip access-list extended NAT-DOMAIN"]
    for inside, _ in statics:
        lines.append(f" permit ip host {inside} {domain} {wild}")
    lines += [
        "exit",
        "route-map NAT-TO-DOMAIN permit 10",
        " match ip address NAT-DOMAIN",
        "exit",
    ]
    for inside, mapped in statics:
        lines.append(f"ip nat inside source static {inside} {mapped} route-map NAT-TO-DOMAIN")

    # one ACL line, not thirty: the dynamic block sits on a /27 boundary
    lines += [
        "ip access-list extended NAT-POOL-SRC",
        f" permit ip {dyn[0]} {env['DYNAMIC_HOST_WILDCARD']} {domain} {wild}",
        "exit",
        f"ip nat pool SITE-POOL {pool_start} {pool_end} prefix-length 24",
        "ip nat inside source list NAT-POOL-SRC pool SITE-POOL",
        "interface GigabitEthernet3",
        " ip nat inside",
        "exit",
    ]
    for t in tunnels:
        lines += [f"interface {t}", " ip nat outside", "exit"]
    lines += [
        f"ip route {site} 255.255.255.0 Null0",
        f"router bgp {env[f'{router}_ASN']}",
        " address-family ipv4 unicast",
        f"  network {site} mask 255.255.255.0",
        " exit-address-family",
        "exit",
    ]
    return lines


def ntp_config(env, router):
    """Synchronise from the NMS, over the out-of-band management VRF.

    The routers no longer talk to pool.ntp.org themselves: the OOB network has no
    route to the internet, so a public pool cannot be reached across it. The NMS
    synchronises upstream through its own NAT interface and serves the management
    network, which makes this a stratum hierarchy rather than a loss of the real
    source -- the public pool is still where the time comes from, one hop further
    away. No DNS is needed either, since the server is now an address.

    No "ntp update-calendar": this is a virtual platform with no hardware
    calendar to update, and the command is rejected.
    """
    intf = env[f"{router}_OOB_INTF"]
    return [
        f"ntp source {intf}",
        f"ntp server vrf {env['MGMT_VRF']} {env['NMS_OOB_IP']}",
    ]


def aaa_config(env, router):
    """AAA against the TACACS+ server on the NMS, over the management VRF.

    Every method list ends in "local". That is not politeness: the local "lab"
    account is how every tool in this repo reaches the routers, and a method list
    without a fallback locks the lab out completely the moment the server is
    unreachable -- including out of the console, which is the one way back.

    "aaa authorization exec ... if-authenticated" lets the server hand back a
    privilege level; without an exec authorization list IOS drops every remote
    user to privilege 1 no matter what TACACS returned, which looks exactly like
    a server that is not sending the attribute.
    """
    intf = env[f"{router}_OOB_INTF"]
    return [
        "aaa new-model",
        f"tacacs server {env['TACACS_SERVER_NAME']}",
        f" address ipv4 {env['NMS_OOB_IP']}",
        f" key {env['TACACS_KEY']}",
        f" port {env['TACACS_PORT']}",
        "exit",
        f"aaa group server tacacs+ {env['TACACS_GROUP']}",
        f" server name {env['TACACS_SERVER_NAME']}",
        f" ip vrf forwarding {env['MGMT_VRF']}",
        f" ip tacacs source-interface {intf}",
        "exit",
        f"aaa authentication login default group {env['TACACS_GROUP']} local",
        f"aaa authentication enable default group {env['TACACS_GROUP']} enable",
        f"aaa authorization exec default group {env['TACACS_GROUP']} local if-authenticated",
        f"aaa accounting exec default start-stop group {env['TACACS_GROUP']}",
        f"aaa accounting commands 15 default start-stop group {env['TACACS_GROUP']}",
    ]


def banner_text(env):
    """The pre-login banner, read from the file the tests also read."""
    path = os.path.join(LAB_DIR, env["BANNER_FILE"])
    with open(path) as fh:
        return fh.read().rstrip("\n")


def do_banner(env, router):
    """Install the pre-login banner.

    "banner login" is the one shown before the username and password prompt,
    which is what makes it a warning rather than a greeting -- "banner exec"
    appears only after a successful login, by which point it has told an
    unauthorised user nothing they needed to hear beforehand.
    """
    d = device(env, router).connect()
    try:
        print(f"[{router}] installing the pre-login banner")
        d.config_banner("login", banner_text(env), env["BANNER_DELIM"])
        d.save()
        print(f"[{router}] pre-login banner installed")
    finally:
        d.close()


def vty_config(env, router):
    """Restrict management logins to the out-of-band network.

    Two permits, and the second one is a compromise worth naming. Everything in
    this repo reaches the routers through a port forwarded by QEMU on Gi1, so
    those sessions arrive from the user-mode NAT gateway rather than from the
    management network. Permitting only the OOB subnet would lock the harness out
    of every router at once, recoverable solely from the serial console.

    "deny any log" is deliberate: a refused login should leave evidence, and
    since syslog already goes to the NMS the denial lands there with everything
    else -- which is also what makes the negative test assertable.
    """
    return [
        f"ip access-list standard {env['VTY_ACL']}",
        " remark out-of-band management network",
        f" permit {env['OOB_NET']} 0.0.0.255",
        " remark hypervisor user-mode NAT: how the harness reaches these devices",
        f" permit {env['MGMT_NAT_NET']} {env['MGMT_NAT_WILDCARD']}",
        " deny   any log",
        "exit",
        "line vty 0 15",
        # "vrf-also" is load-bearing, and its absence is silent. Without it
        # access-class evaluates only sessions arriving in the global routing
        # table and drops anything that came in through a VRF before the ACL is
        # consulted at all -- so every login from the out-of-band network is
        # refused while the ACL sits there looking correct, with zero matches on
        # the permit that should have allowed it.
        f" access-class {env['VTY_ACL']} in vrf-also",
        " transport input ssh",
        "exit",
    ]


def do_vty(env, router):
    """Rebuilt rather than re-applied: a standard ACL appends, so re-running
    without the teardown quietly accumulates duplicate permits."""
    d = device(env, router).connect()
    try:
        print(f"[{router}] applying VTY access control")
        d.config([f"no ip access-list standard {env['VTY_ACL']}"], ignore_errors=True)
        d.config(vty_config(env, router))
        d.save()
        print(f"[{router}] VTY access control applied")
    finally:
        d.close()


def do_aaa(env, router):
    _apply(env, router, "AAA", aaa_config(env, router))


def syslog_config(env, router):
    """Point the router at the collector on the NMS.

    Sourced from the out-of-band interface, inside the management VRF: the
    sending router is identifiable by its OOB address, and the messages never
    touch the data path, so a spoke keeps logging even with its tunnel down.
    Sequence numbers and millisecond timestamps are enabled because the tests
    assert on both.

    All three routers share one UDP port. That is only possible because the
    collector is rsyslog: the previous busybox nc collector connected to its
    first sender and silently dropped every other source, which is why each
    router used to need a port of its own.
    """
    intf = env[f"{router}_OOB_INTF"]
    return [
        "service timestamps log datetime msec show-timezone",
        "service sequence-numbers",
        f"logging source-interface {intf} vrf {env['MGMT_VRF']}",
        f"logging trap {env['SYSLOG_TRAP_LEVEL']}",
        f"logging host {env['NMS_OOB_IP']} vrf {env['MGMT_VRF']} "
        f"transport udp port {env['SYSLOG_PORT']}",
    ]


def snmp_config(env, router):
    """SNMPv3 with authPriv, sending traps to the collectors on the NMS.

    "snmp-server enable traps" with no arguments is what flips the global trap
    switch: enabling individual trap types leaves "SNMP global trap: disabled"
    and the router builds trap PDUs it never sends.

    Two notification hosts, both on the NMS: snmptrapd on the standard port,
    which authenticates and decrypts each trap, and a raw listener on a second
    port whose datagrams are decoded byte by byte to prove the payload really is
    encrypted in flight -- something snmptrapd's own log cannot show, because by
    the time it writes a line it has already decrypted.
    """
    return [
        f"snmp-server view {env['SNMP_VIEW']} iso included",
        f"snmp-server group {env['SNMP_GROUP']} v3 priv read {env['SNMP_VIEW']} notify {env['SNMP_VIEW']}",
        f"snmp-server user {env['SNMP_USER']} {env['SNMP_GROUP']} v3 "
        f"auth sha {env['SNMP_AUTH_PASS']} priv aes 128 {env['SNMP_PRIV_PASS']}",
        f"snmp-server trap-source {env[f'{router}_OOB_INTF']}",
        "snmp-server enable traps",
        f"snmp-server host {env['NMS_OOB_IP']} vrf {env['MGMT_VRF']} version 3 "
        f"priv {env['SNMP_USER']} udp-port {env['SNMP_TRAP_PORT']}",
        f"snmp-server host {env['NMS_OOB_IP']} vrf {env['MGMT_VRF']} version 3 "
        f"priv {env['SNMP_USER']} udp-port {env['SNMP_TRAP_RAW_PORT']}",
    ]


def do_snmp(env, router):
    """Remove existing notification hosts first: like logging hosts, they
    accumulate rather than replace when the port changes."""
    d = device(env, router).connect()
    try:
        existing = [l.strip() for l in
                    d.run("show running-config | include ^snmp-server host").splitlines()
                    if l.strip().startswith("snmp-server host")]
        if existing:
            print(f"[{router}] removing {len(existing)} existing SNMP host(s)")
            d.config([f"no {line}" for line in existing], ignore_errors=True)
        print(f"[{router}] applying SNMPv3 config")
        # strict: a refused snmp-server line is a fault, not noise
        d.config(snmp_config(env, router))
        d.save()
        print(f"[{router}] SNMPv3 config applied")
    finally:
        d.close()


def do_syslog(env, router):
    """Remove existing logging hosts before adding ours.

    "logging host X" and "logging host X transport udp port N" are separate
    entries, so re-provisioning with a different port leaves both in place and
    the router sends every message twice, to two different ports.
    """
    d = device(env, router).connect()
    try:
        existing = [l.strip() for l in
                    d.run("show running-config | include ^logging host").splitlines()
                    if l.strip().startswith("logging host")]
        if existing:
            print(f"[{router}] removing {len(existing)} existing logging host(s)")
            d.config([f"no {line}" for line in existing], ignore_errors=True)
        print(f"[{router}] applying syslog config")
        d.config(syslog_config(env, router))
        d.save()
        print(f"[{router}] syslog config applied")
    finally:
        d.close()


def do_ntp(env, router):
    _apply(env, router, "NTP", ntp_config(env, router))


def do_nat(env, router):
    """Tear the NAT config down before rebuilding it.

    IOS keeps an existing "ip nat pool" definition when the same name is
    redefined, and "ip access-list" appends rather than replaces -- so simply
    re-applying leaves the old pool range in force and the old ACL entries in
    place. That failed silently once: a pool meant to hold 30 addresses stayed at
    11 and a third of the hosts got no translation.
    """
    d = device(env, router).connect()
    try:
        print(f"[{router}] clearing existing NAT state")
        d.run("clear ip nat translation *")          # frees pool addresses so it can be removed
        existing = [l.strip() for l in
                    d.run("show running-config | include ^ip nat inside source").splitlines()
                    if l.strip().startswith("ip nat")]
        d.run("configure terminal")
        for line in existing:
            # removing a static entry with live children asks for confirmation
            d.run_confirm(f"no {line}")
        for line in ("no ip nat pool SITE-POOL",
                     "no ip access-list extended NAT-POOL-SRC",
                     "no ip access-list extended NAT-DOMAIN"):
            d.run(line)
        d.run("end")
        print(f"[{router}] applying NAT config")
        d.config(nat_config(env, router))
        d.save()
        print(f"[{router}] NAT config applied")
    finally:
        d.close()


def _apply(env, router, label, cfg):
    d = device(env, router).connect()
    try:
        print(f"[{router}] applying {label} config")
        d.config(cfg)
        d.save()
        print(f"[{router}] {label} config applied")
    finally:
        d.close()


def do_ipsec(env, router):
    _apply(env, router, "IPsec", ipsec_config(env, router))


def do_bgp(env, router):
    """Teardown and configuration are applied separately, and for different
    reasons: removing an object that is not there is a no-op worth tolerating,
    while a rejected configuration line is a fault worth stopping for. Applying
    both strictly breaks on a factory-fresh device, where the teardown has
    nothing to remove; applying both leniently is how a genuinely refused
    command goes unnoticed."""
    d = device(env, router).connect()
    try:
        peers = _peer_list(env, router)
        print(f"[{router}] clearing any existing routing policy")
        d.config(bgp_policy_teardown(env, router, peers), ignore_errors=True)
        print(f"[{router}] applying BGP config")
        d.config(bgp_config(env, router, skip_teardown=True))
        d.save()
        print(f"[{router}] BGP config applied")
    finally:
        d.close()


def do_license(env, router):
    """Returns True if it actually reloaded, so callers re-apply later phases."""
    d = device(env, router).connect()
    try:
        level = env["LICENSE_LEVEL"]
        addon = env.get("LICENSE_ADDON", "dna-premier")
        current = d.run("show version | include License Level")
        if level.split("-")[-1].lower() in current.lower():
            print(f"[{router}] license already active")
            return False
        print(f"[{router}] setting boot level {level} addon {addon}")
        d.config([f"license boot level {level} addon {addon}"])
        print(f"[{router}] reloading to activate (several minutes)")
        d.reload_and_wait()
        print(f"[{router}] back up: {d.run('show version | include License Level').strip()}")
        return True
    finally:
        d.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("phase", choices=["license", "ipsec", "bgp", "nat", "ntp", "syslog",
                                  "snmp", "aaa", "vty", "banner", "all"])
    ap.add_argument("--routers", default="")
    args = ap.parse_args()
    env = load_env()
    rs = args.routers.split(",") if args.routers else routers(env)
    rs = [r.strip() for r in rs if r.strip()]

    phases = (["license", "ipsec", "bgp", "nat", "ntp", "syslog", "snmp", "aaa", "vty", "banner"]
          if args.phase == "all" else [args.phase])
    fns = {"license": do_license, "ipsec": do_ipsec, "bgp": do_bgp, "nat": do_nat,
           "ntp": do_ntp, "syslog": do_syslog, "snmp": do_snmp, "aaa": do_aaa, "vty": do_vty, "banner": do_banner}
    for phase in phases:
        fn = fns[phase]
        with ThreadPoolExecutor(max_workers=len(rs)) as pool:
            results = list(pool.map(lambda r: fn(env, r), rs))
        if phase == "license" and any(results) and "ipsec" not in phases:
            print("license reload happened; re-applying ipsec, bgp and nat")
            for follow in (do_ipsec, do_bgp, do_nat, do_ntp, do_syslog, do_snmp, do_aaa, do_vty, do_banner):
                with ThreadPoolExecutor(max_workers=len(rs)) as pool:
                    list(pool.map(lambda r: follow(env, r), rs))
    print("provisioning complete")


if __name__ == "__main__":
    main()
