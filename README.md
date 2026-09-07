# Two-router Catalyst 8000V IPsec testbed

Boots two C8000V routers under QEMU/KVM, links them over a virtual ethernet,
builds an IKEv2 + IPsec (static VTI) tunnel between them, and validates with
Robot Framework that traffic is genuinely being encrypted.

```
   +----------------+                                   +----------------+
   |   c8000v-r1    | Gi2 10.10.10.1 --- 10.10.10.2 Gi2  |   c8000v-r2    |
   |  Lo0 172.16.1.1|      (QEMU socket netdev)          | Lo0 172.16.2.1 |
   +----------------+                                   +----------------+
            \____________  Tunnel0 192.168.100.0/30  ____________/
                          IKEv2 / ESP-AES-256 / SHA256
                    eBGP AS 65001 <-> AS 65002 peers *inside* the tunnel
   Lo1 10.20.1.1                                    Lo1 10.20.2.1  (BGP-advertised)

   h1 192.168.10.10 --[R1 Gi3 .10.1]== ESP ==[R2 Gi3 .20.1]-- h2 192.168.20.10

   Loopback-to-loopback traffic is encrypted; link-local traffic is not.
   BGP peers on the Tunnel0 addresses, so the routing control plane is encrypted too.
   The two cirros hosts run no crypto: their LAN prefixes are advertised by eBGP
   over the tunnel, so the routers encrypt on their behalf.
```

## 0. Get the image

Download **Catalyst 8000V Edge Software → IOS XE 17.x → 16G SERIAL QCOW2**
(non-EFI, serial console) from software.cisco.com into `images/`. Both routers
share it as a read-only backing file.

## 1. One-time setup

    ./setup.sh

## 2. Bring up the whole lab

    ./start-lab.sh

That does everything: builds per-router day0 ISOs, starts R1 then R2 (ordering
matters, see below), waits for both, activates the feature license, reloads both
routers, then configures IPsec. Budget ~15 minutes from cold.

## 3. Run the tests

    ./run-tests.sh                      # all 17 suites (~20 min; 07 waits on a real rekey)
    ./run-tests.sh tests/04_ipsec.robot # just the IPsec validation
    ./run-tests.sh --include smoke      # options work too; target defaults to tests/

| suite | what it covers |
|---|---|
| `01_platform.robot` | version, hostnames, mgmt IPs, license, mgmt services -- both routers |
| `02_configuration.robot` | config push / verify / ping / rollback on R1 |
| `03_link.robot` | the virtual ethernet: interfaces, reachability, ARP, loopbacks |
| `04_ipsec.robot` | tunnel state, IKEv2 SA, ESP SAs, transform, **counter-delta proof of encryption**, negative control |
| `05_running_config.robot` | dumps each router's full running-config to the report and saves `results/<R>-running-config.txt` |
| `06_wire_encryption.robot` | Embedded Packet Capture on Gi2: protected traffic is ESP, protected addresses never appear in cleartext, plus a positive control |
| `07_ipsec_negative.robot` | wrong PSK must be rejected, tunnel must recover, SA must rekey with traffic still flowing (slow: waits out a 120s lifetime) |
| `08_management_api.robot` | RESTCONF and NETCONF cross-checked against the CLI, including a PUT/DELETE round trip |
| `10_host_to_host.robot` | end-to-end host traffic: addressing, gateways, BGP-learned LAN routes, bidirectional ping, ESP counters, and host addresses never on the wire |
| `09_bgp.robot` | eBGP over the tunnel: session, prefix exchange, BGP-learned route, end-to-end reachability, **encrypted control plane**, withdrawal, reconvergence, MD5-mismatch negative |

## 4. Shut down

    ./stop-lab.sh            # stop both routers
    ./stop-lab.sh --clean    # also delete overlay disks -> factory-fresh next start

## How it works, and the gotchas that shaped it

**The license is not optional.** At the default (unset) license level the crypto
CLI does not exist -- `crypto ikev2 ...` returns `% Invalid input`. The lab sets
`license boot level network-premier addon dna-premier`, which only takes effect
across a reload. That is why `start-lab.sh` has a reload phase, and why IPsec
config cannot live in the day0 ISO: at day0 time the commands would be rejected.
`tests/01_platform.robot` asserts the license is active precisely because every
IPsec test depends on it.

**R1 must start before R2.** The link is a QEMU socket netdev: R1 listens on
127.0.0.1:10001, R2 connects to it. `start-lab.sh` enforces the order. If you
start them by hand with `./start-vm.sh R2` first, R2's Gi2 will never come up.

**Two independent proofs of encryption.** `04_ipsec.robot` counts ESP packets;
`06_wire_encryption.robot` captures the wire and asserts the protected addresses
never appear on it. The second is stronger, and it carries a positive control
(unprotected traffic *is* visible as cleartext ICMP) so that an absence caused by a
broken capture cannot masquerade as proof of encryption.

**Why BGP peers over the tunnel, not the link.** Peering on the link addresses
would be plain BGP over cleartext ethernet and would test nothing the other suites
do not. Peering on the Tunnel0 addresses puts the routing control plane inside ESP,
which is both how you would really build it and what makes the strongest test in
suite 09 possible: capture the link across a keepalive window and assert no TCP, no
peering addresses and no advertised prefixes are visible -- only ESP.

BGP advertises `Loopback1` prefixes rather than `Loopback0`, because `Loopback0`
already has a static route (AD 1) that would always beat an eBGP path (AD 20). The
separate prefixes also keep suites 04 and 06 independent of BGP being up.

**Every session is authenticated, BFD-tracked and filtered outbound.**

* *MD5* on every neighbour (`neighbor <addr> password`). Suite 09 asserts both
  directions of this: that no neighbour was left without a password, and that a
  wrong one prevents the session coming up.
* *BFD* on every neighbour (`neighbor <addr> fall-over bfd`), with the session
  running on the tunnel the peer address lives on. Timers are 500ms x 3 -- these
  are virtual routers sharing a host CPU, and sub-second detection on a contended
  hypervisor produces false positives. Note there is no `bfd echo` knob on a
  tunnel interface: echo mode loops packets back through the peer's data plane
  and does not apply, so these sessions are async by construction.
* *Outbound whitelists and community tagging*: a route-map per peer with one
  clause per prefix class, each matching a class prefix-list and setting that
  class's community. The clauses *are* the whitelist -- the route-map's implicit
  deny is what stops anything unnamed being advertised, including prefixes some
  later phase might add.
* *Inbound validation*: a route-map per peer with a single permit clause matching
  both a community-list of the nine communities this topology can produce and a
  per-peer AS-path list. Two matches in one clause are ANDed, so a prefix with an
  unknown community *or* an unexpected AS path falls through to the implicit deny
  and is dropped.

Communities are `<origin ASN>:<class>`, where class 1 is the BGP loopback, 2 the
NAT domain and 3 the LAN -- so a community names both where a prefix came from
and what kind of prefix it is. The hub re-advertises a far spoke's prefixes
through a clause with no `set`, so the origin's community survives the hop rather
than being re-stamped as the hub's.

AS-path lists are anchored to what each peer can legitimately send: `^65002$` from
R2 at the hub, and at a spoke either `^65001$` (the hub's own) or `^65001_65003$`
(the far spoke re-advertised through it). Anything longer is a path this topology
cannot produce -- a spoke transiting, or a loop.

Two traps worth knowing:

* **`send-community` is load-bearing.** IOS strips communities on eBGP by
  default. Without `neighbor <addr> send-community both` every prefix arrives
  untagged and the inbound community match drops the *entire* table. The failure
  is total, not partial, which at least makes it obvious.
* **`set community 65999:9` is rejected by IOS**, because 65999 is outside the
  16-bit AS range and so is not a well-formed `AA:NN` community. The negative
  test uses `65500:9`: well formed, but belonging to no router here.

The two inbound negative tests are built so they cannot pass for the wrong
reason. The test prefix is explicitly permitted *outbound* by a temporary
route-map clause, so the whitelist cannot be what stops it, and each test asserts
R2 really did advertise the prefix before asserting the hub refused it --
otherwise a failed advertisement would look exactly like a working filter.

Each router originates **three** prefixes, not two: the BGP `/32` and the LAN come
from the BGP phase, but the NAT domain `10.30.x.0/24` is advertised by the *NAT*
phase (a `Null0` route plus a `network` statement). A whitelist built from the BGP
phase alone silently drops it and breaks every host-to-host test through NAT, so
`originated_prefixes()` lists all three regardless of which phase advertises them.

A spoke may advertise only its own three; the hub may advertise its own plus the
*other* spoke's, since that re-advertisement is what makes spoke-to-spoke work.
Suite 09 compares the advertised set for **equality**, not containment -- a
whitelist that permits more than intended still passes a containment check.

**The suites interact, deliberately.** Two failures only ever appear in a full run:
suite 04's negative control cannot assert a delta of exactly zero once BGP keepalives
are ticking the ESP counters, and suite 09 must wait for convergence because suite 07
tears the tunnel down right before it. Both are handled; if you add a suite that
disturbs the tunnel, expect to do the same.

**Failing correctly matters as much as working.** `07_ipsec_negative.robot` sets a
wrong pre-shared key and asserts the tunnel does *not* come up. Without it, a
tunnel that authenticated any peer would still pass every other suite. It restores
the correct key in both the test and the suite teardown, so a failure mid-run
cannot leave the lab broken.

**Proving encryption, not just configuration.** A tunnel that is `up/up` with a
READY IKEv2 SA can still be passing traffic you did not intend to protect, or
protecting nothing at all. `04_ipsec.robot` reads the `#pkts encaps/decaps`
counters on both peers, sends a known number of pings between the loopbacks, and
asserts the counters moved by at least that much on both sides. It then pings the
link addresses and asserts the ESP counters did *not* move -- if they did, the
crypto selector would be too broad and the main test would be passing for the
wrong reason.

## Files

| | |
|---|---|
| `lab.env` | every address, port, and credential -- single source of truth |
| `lib.sh` | resolves `R1_*`/`R2_*` settings into flat names for the scripts |
| `make-day0.sh R1\|R2` | builds the bootstrap ISO (base config + license line) |
| `start-vm.sh R1\|R2` | boots one router |
| `tools/devcli.py` | reload-safe SSH driver (SSHLibrary's `write` hangs across a reload; this uses `write_bare`) |
| `tools/provision.py` | `license` and `ipsec` provisioning phases |
| `tools/netconf_keywords.py` | Robot keyword library wrapping ncclient for the NETCONF tests |
| `start-host.sh H1\|H2` | boots one cirros host onto its router's Gi3 LAN |
| `tools/host_provision.py` | sets each host's eth1 address and far-LAN route over SSH |
| `start-nms.sh` | boots the NMS onto the hub LAN segment |
| `make-nms-seed.sh` | builds the NMS cloud-init seed (address, routes, net-snmp) |
| `tools/nms_lib.py` | SSH session for the NMS; merges stderr, where net-snmp reports refusals |
| `tools/nms_provision.py` | verifies and repairs the NMS, then proves it reaches every router |
| `tools/snmp_poll_keywords.py` | Robot keywords wrapping snmpget/snmpwalk for the polling suite |
| `tools/nms_collectors.py` | installs rsyslog, snmptrapd and the raw trap capture as services |
| `tools/trapcap.py` | the raw trap capture itself; runs on the NMS as `lab-trapcap` |
| `tools/syslog_keywords.py` | reads the rsyslog per-router files and parses IOS message framing |
| `tools/snmp_keywords.py` | reads snmptrapd's decrypted log and BER-decodes the raw capture |

## The Linux hosts

`Gi3` on each router is the LAN gateway. Each LAN is a QEMU **multicast** netdev
rather than a point-to-point socket, so a segment can hold any number of machines
and they may join in any order -- unlike the inter-router links, which are socket
netdevs with one end listening and therefore do impose a start order. `localaddr`
pins each group to `lo`, so no lab traffic reaches the physical network.

This is what makes room for a second machine on the hub LAN; see *The NMS* below.

**Cirros ignores the cloud-init seed on this image.** The seed disk is present and
correctly labelled `cidata` -- verified with `blkid` inside the guest -- and it was
tried both as a virtio disk and as a CD-ROM, but `cirros-init` never consumes it.
Rather than keep guessing at its datasource internals, `tools/host_provision.py`
configures the hosts over SSH. It is idempotent and verifies what it set. The
tradeoff: host addressing does not survive a host reboot, and is re-applied by
`start-lab.sh`.

## pyATS / Genie

`tests_pyats/04_ipsec_genie.robot` is a working port of one suite onto pyATS,
kept as a reference rather than a migration. `testbed/lab.yaml` (generated from
`lab.env` by `tools/make_testbed.py`) is used by it and is worth keeping either
way: it replaces the long `--variable` list in `run-tests.sh`.

The evaluation, with evidence and costs, is in `docs/pyats-evaluation.md`. Short
version: Unicon fixes the connection bugs that cost the most time here, Genie's
parsers remove the regex-escaping bug class, and neither is worth rewriting 101
passing tests for. Reach for it when writing something new.

## Notes

- Consoles: `telnet 127.0.0.1 5001` (R1), `5002` (R2).
- SSH: `ssh -p 2221 lab@127.0.0.1` (R1), `-p 2222` (R2).
- `lab.env` holds the router password, the IPsec pre-shared key, the BGP MD5
  password and the SNMPv3 auth/priv passwords in cleartext. Fine for a local
  throwaway lab; move them to environment variables before this goes anywhere
  shared or into CI.
- **`05_running_config.robot` captures secrets.** IOS-XE prints the IPsec
  pre-shared key in cleartext in `show running-config`, so it ends up in
  `results/*-running-config.txt` and inside `log.html`/`report.html`. Do not
  publish those artifacts as-is. Either add `service password-encryption` to the
  day0 config, or filter the capture, before using this outside a throwaway lab.
- **The SNMPv3 polling suite exposes credentials the same way.** net-snmp takes
  the auth and privacy passwords as command-line arguments, and the evidence PDF
  records every command verbatim, so `-A`/`-X` values appear in
  `test-evidence.pdf` and `log.html`. Outside a throwaway lab, create the user
  with `snmpusm` or pass credentials through `~/.snmp/snmp.conf` on the NMS so
  they never reach a command line.
- Re-provision without a full rebuild: `./.venv/bin/python -u tools/provision.py ipsec`.
- The SSH prompt regex deliberately anchors to a line start and the end of buffer.
  A looser pattern matches the `->` in `show monitor capture` output as a prompt,
  which silently desynchronises every subsequent read. See `${PROMPT}` in
  `resources/c8000v.resource` and `PROMPT` in `tools/devcli.py` -- keep them in step.


## The NMS

`nms` is an Ubuntu 24.04 minimal cloud image at `192.168.10.20`, sharing the hub
LAN with `h1`. It exists because the cirros hosts cannot speak SNMP at all: they
have no package manager and busybox ships no SNMP tooling, which is why the trap
tests in `16_snmpv3.robot` capture datagrams raw and decode the BER by hand.

Unlike cirros, this image's cloud-init works, so the seed does the whole job --
address, routes, and `apt install snmp snmptrapd iputils-ping`. Package installs
need the internet, which it reaches through the QEMU user-mode NAT on its first
NIC; the second NIC is the lab-facing one.

The whole management plane now terminates here rather than on h1 -- syslog and
SNMPv3 traps as well as polling. That is not just tidiness. h1 is cirros, so the
only collector it could run was busybox `nc`, which attaches to its first sender
and silently drops every other source; each router therefore needed a UDP port of
its own for each service (514/5142/5143, 162/1622/1623). rsyslog and snmptrapd
each serve all three routers on one standard port, and both run as system
services, so they are always receiving and no test run can leave a stale listener
behind swallowing another run's messages -- which is exactly how a negative test
once passed while nothing was arriving at all.

**Traps are received twice, on purpose.** `snmptrapd` on port 162 authenticates
and decrypts each trap with a USM key created per router engine ID -- proof that
credentials, engine IDs and the privacy protocol all agree, and the only way to
read the varbinds. But it cannot show a trap was encrypted *in flight*: by the
time it writes a log line it has already decrypted. So the routers also send to
`tools/trapcap.py` on port 1162, which keeps the datagrams byte for byte, and the
tests BER-decode those to assert the scoped PDU is an opaque OCTET STRING rather
than a readable SEQUENCE.

One thing to know if you change the syslog setup: rsyslog drops privileges to the
`syslog` user, so its output directory must be writable by that user. A
root-owned directory leaves it unable to create the files, and it reports that
only in its own log -- the symptom looks exactly like the datagrams never
arriving.

`17_snmp_polling.robot` then polls all three routers with the same `snmpget` and
`snmpwalk` an engineer would type:

* answers are **cross-checked against each router's own CLI** -- polled `sysName`
  against the configured hostname, the `ifDescr` walk against
  `show ip interface brief`, `ifNumber` against the row count -- so a plausible
  reply from the wrong device cannot pass;
* only the hub is on the NMS's LAN, so **R2 and R3 are polled across the IPsec
  tunnels**, and the test asserts the ESP counters advance at both ends while it
  polls: the management traffic is itself encrypted;
* the negative cases assert the *specific* refusal, not merely a failure -- a
  wrong auth password gives `Authentication failure`, a wrong privacy password
  gives a timeout (authentication passed, the payload would not decrypt, so the
  router drops it silently), `noAuthNoPriv` and `authNoPriv` give
  `authorizationError` because the group is configured `v3 priv`, an unknown user
  gives `Unknown user name`, and v2c gets nothing at all. Each negative is
  bracketed by a successful poll so it cannot pass against a dead agent.

No MIB text files are installed -- they are non-free on Ubuntu -- so every OID in
the suite is numeric, with the name in a comment, and every command passes `-On`
to keep the responses numeric too.


## Path MTU across the tunnels

Encryption costs header room: ESP-AES-256 with SHA256 leaves **1438 bytes** of a
1500-byte path, an overhead of 62. That boundary is where real IPsec deployments
fail, and they fail quietly -- small packets work, so ping and SSH look healthy
while anything bulk stalls.

`18_mtu.robot` asserts the boundary from both sides, because the permissive half
alone would pass equally well against a tunnel with no limit at all: a DF packet
of exactly 1438 crosses, 1439 does not. It then requires the same oversize
traffic to succeed *without* DF, which distinguishes an MTU limit from a
blackhole.

The test that matters most in practice is the last one: an end host two hops and
an encryption boundary away reports `mtu=1438` when it tries to send oversize
traffic with DF set. Path MTU discovery survived the tunnel and reached the
client -- which is the difference between a client backing off and one
retransmitting into a black hole forever.

## Limits, not just filters

Outbound whitelists and inbound validation control *what* a peer may send.
`maximum-prefix 15 80` controls *how much*: normal load is 3 prefixes at the hub
and 6 at a spoke, so the limit has headroom but still trips long before a peer
could exhaust memory. No `restart` is configured, so a teardown is sticky and
recovery is a deliberate operator action rather than a flap that hides itself.

The flood test originates 20 extra prefixes on R2, tagged with a valid community
and carrying a valid AS path, and explicitly permitted outbound -- so neither the
whitelist, the community match nor the AS-path filter can be what stops them.
Only the count is left. The hub must reach state `(PfxCt)` and log
`%BGP-3-MAXPFXEXCEED`.

## The pool boundary

The dynamic pool holds exactly as many addresses as there are clients, so the
exhaustion path is never touched by a normal run -- and an off-by-one in the pool
bounds would look identical to a correct configuration. The pool ACL covers
`.64-.95` while only `.64-.93` are configured, so `.94` is a pool-eligible client
with nothing left for it. It must get no translation, must not borrow another
client's address (there is no `overload`, so sharing would be a correctness bug
rather than graceful degradation), and the miss must be counted.

Two things this suite learned the hard way:

* **The NAT counters lag the dataplane**, the same way the QFP IPsec counters do.
  Reading the miss counter immediately after the traffic returns the pre-sync
  value; it has to be polled.
* **A test that provokes a counter must own that counter's baseline, at suite
  scope.** The exhaustion test deliberately causes misses, and the counters are
  cumulative -- so clearing them locally left the misses behind for the *next*
  run's "pool is exactly consumed with no misses" assertion to trip over, in a
  different test, with a message that pointed nowhere near the cause. The baseline
  now lives in the suite setup beside the translation clear.


## Out-of-band management

Every router and the NMS attach to a flat `192.168.99.0/24`, and the routers hold
that interface in a **`MGMT` VRF** -- the hub on `GigabitEthernet5`, the spokes on
`GigabitEthernet4`, since the OOB NIC is added last and the hub has one more to
begin with. NTP, syslog and SNMP all run on it and nothing else does.

The VRF is what makes the separation structural rather than topological: the
management routing table knows how to reach `192.168.99.0/24` and nothing else,
and the global table has no route to it at all. `19_oob.robot` asserts both
directions, and that no data interface has been placed in the VRF.

Two properties are worth more than the configuration checks:

* **Management never touches the data path.** Polling both spokes must not
  advance the hub's ESP counters. Measured against an idle window of the same
  length, because BGP and BFD tick those counters continuously -- an absolute
  delta would prove nothing. This test is the exact inverse of the one it
  replaced: polling a spoke used to cross a tunnel and was asserted to *advance*
  those counters.
* **A device stays manageable when the data path is broken.** The last test shuts
  R2's tunnel, waits until the hub has genuinely lost its route to R2's LAN, and
  requires the spoke to keep answering SNMP and delivering syslog. That is the
  entire reason out-of-band management exists, demonstrated rather than asserted.

### Time became a hierarchy

The OOB network has no route to the internet, so the routers cannot reach
`pool.ntp.org` across it. The NMS runs chrony, synchronises upstream through its
own NAT interface, and serves the management network: the public pool is still
the source, one stratum further away.

That makes the server's own health load-bearing. chrony is configured
`local stratum 10`, so it keeps serving time whether or not it has an upstream --
meaning the entire lab could agree precisely on time that came from nowhere, with
every router-side NTP assertion still passing. `14_ntp.robot` therefore checks
that the NMS's reference is not its own clock, that its stratum is real, and that
it has an upstream source selected.

### Notes for anyone changing this

* **day0 only applies to a router with empty NVRAM.** Adding the VRF and the OOB
  interface to `make-day0.sh` does nothing to a router booting an existing
  overlay -- it loads its saved configuration and ignores the ISO entirely. This
  change needed `./stop-lab.sh --clean` and a rebuild from factory-fresh.
* **`vrf forwarding` must precede `ip address`.** Applying it afterwards silently
  clears the address.
* **Four spaces inside a Robot argument split it in two.** `Should Not Contain
  ${x}    Reference ID    : 7F7F0101` searches for `Reference ID` and uses
  `: 7F7F0101` as the failure message -- so the test checks something else
  entirely and still looks reasonable in the source.


## TACACS+ authentication

Shrubbery `tac_plus` runs on the NMS and is reached over the out-of-band network
inside the `MGMT` VRF, so AAA rides the management plane like NTP, syslog and
SNMP. Two remote users exist at different privilege levels -- `netadmin` at 15
and `netops` at 1 -- which is what makes the privilege assertions mean anything:
if both landed at the same level, the tests would pass just as well against a
router ignoring the server and applying its own default.

**Packaging.** `tacacs+` was dropped from Ubuntu after jammy, but the `.deb` is
still in the universe pool and the daemon is C. Its only unmet dependency is
`python` -- meaning Python 2, which noble does not ship and which the daemon does
not use; it is there for an auxiliary script. `tools/nms_provision.py` installs
it with that one dependency ignored. The package's postinst then starts
`tac_plus` through its SysV script, which binds port 49 outside systemd's
supervision, so the provisioner stops it by every route and reaps any leftover
before starting the supervised unit.

### Three things this cost, one of which nearly broke the lab

**`local` does not mean what it looks like it means.** With
`aaa authentication login default group LABTACGRP local`, the fallback to `local`
applies only when the server is **unreachable**. A reachable server that rejects
an unknown user is an authoritative no, and IOS honours it. The `lab` account --
which every tool in this repo authenticates as -- did not exist on the server, so
the first router to get AAA became unmanageable by the test suite while the
server sat there perfectly healthy. The automation account now exists on the
server as well as locally on each router. This was caught only because AAA was
applied to one router first; applying to all three at once would have locked the
suite out of the whole lab.

**`aaa new-model` on its own drops every remote user to privilege 1.** Without an
`aaa authorization exec` list, IOS ignores whatever level TACACS returned. It
looks exactly like a server that is not sending the attribute.

**`show tacacs` caches its verdict.** It keeps reporting `Server Status: Alive`
until a transaction actually fails, so it cannot answer "is the path gone right
now". The local-fallback test uses a live `ping vrf MGMT` instead. This mattered:
had that precondition been written the other way round, the test could have run
with the server still reachable, authenticated `lab` through TACACS, and passed
while proving nothing about local fallback.

A related detail: shutting the only interface in a VRF takes its address with it,
so IOS refuses to send at all -- `% VRF MGMT does not have a usable source
address` -- rather than sending and losing the packets. That is a stronger result
than a 0 percent success rate, but it is a different string, and matching only on
the latter waits out the retries for nothing.

**A Robot trap worth knowing:** a `...` continuation line placed after
`[Teardown]` becomes an *argument* to the teardown keyword rather than more
documentation. `tests/` is now checked for that pattern.


## VTY access control

Management logins are restricted with an `access-class` on the VTY lines,
enforced before authentication, so an attempt from anywhere else never reaches
the password prompt.

```
ip access-list standard VTY-MGMT
 permit 192.168.99.0 0.0.0.255      ! the out-of-band management network
 permit 10.0.2.0 0.0.0.255          ! the hypervisor's user-mode NAT
 deny   any log
line vty 0 15
 access-class VTY-MGMT in vrf-also
 transport input ssh
```

**The second permit is a deliberate, documented weakening.** Every tool in this
repo reaches the routers through a port QEMU forwards on `Gi1`, so its sessions
arrive from `10.0.2.2` rather than from the management network -- confirmed on
`show users`. Permitting only the OOB subnet locks the harness out of all three
routers at once, recoverable solely from the serial console. It is this lab's
equivalent of console access. A real deployment would have no such path, or would
reach the devices through the NMS as a jump host so that sessions genuinely
originate on the management network. `21_vty_acl.robot` pins the exception by
asserting the ACL has exactly two permits, so widening the policy breaks a test
rather than passing quietly.

### `vrf-also` is load-bearing, and its absence is silent

Without it, `access-class ... in` evaluates only sessions arriving in the global
routing table and drops anything that came in through a VRF **before consulting
the ACL at all**. Applied without `vrf-also`, SSH from the out-of-band network
was refused while the ACL sat there reading exactly right -- permitting the very
subnet being connected from.

The counters are what diagnosed it: `permit 192.168.99.0/24` showed **zero**
matches while `deny any log` showed one. That distinguishes "the ACL denied this"
from "the ACL never saw this", which a test asserting only *connection refused*
cannot tell apart. The suite now asserts `vrf-also` explicitly.

### Testing it

The NMS holds an address on both the management network and the hub LAN, so the
negative test is one machine, two source addresses, directly connected targets,
and nothing but the source subnet differing. The probe reads the SSH banner
rather than completing a login, because `access-class` is enforced before
authentication -- the banner is exactly where permitted and denied diverge, and
the test needs no credentials.

A baseline was taken before applying the ACL: both sources returned
`SSH-2.0-Cisco-1.25`. Without that, a denial test could have been passing against
a path that never worked.


## Pre-login banner

`config/login-banner.txt` is the single source: the provisioner installs it and
the tests compare against the same file, so a copy cannot drift.

`banner login` is deliberate. It is shown before the username and password
prompt, which is what makes it a warning; `banner exec` appears only after a
successful login, by which point it has told an unauthorised visitor nothing they
needed to hear beforehand.

### Testing that it is actually pre-login

Asserting the text is in `show running-config` proves only that someone typed it.
IOS delivers `banner login` as an SSH userauth banner, so `22_banner.robot`
captures it from a **deliberately failed** authentication -- wrong password, no
credentials needed -- which demonstrates it reaches a client that has not been let
in. Capturing it after a successful login would prove the weaker thing.

Four assertions beyond "it exists":

* **Line-for-line comparison with the source file**, not a substring match, so a
  truncated or stale copy on a device fails instead of passing because one
  memorable phrase survived. Only line endings are normalised -- the device sends
  CRLF, the file holds LF, and that was the only difference.
* **It states the warning it exists to give**: restricted access, monitoring,
  consent following from use. A banner that does not warn is decoration.
* **It discloses nothing about the platform** -- no vendor, model, software
  version, hostname or address. An unauthenticated visitor should learn that they
  are unwelcome and nothing else. The first draft of the banner named the
  platform; the test was written first and the text was fixed to satisfy it.
* **It is in the startup configuration**, not only the running one -- otherwise it
  is present until the next reload and absent exactly when it matters.

### Applying a banner through the CLI driver

Banner entry is a mode of its own: after `banner login ^` the device echoes
nothing and returns no prompt until the closing delimiter, so the usual
line-at-a-time config loop waits for a prompt that will not come. `Device.config_banner`
sends the whole block with `write_bare` and reads the prompt once at the end --
the same shape as the fix for the interactive `send log` command.


## Packaging the whole lab as one portable VM

`./package-lab.sh` builds the entire testbed into a single qcow2:
`dist/c8000v-lab.qcow2`, about 5 GB compressed against a 70 GB sparse disk. It
holds Ubuntu, the QEMU toolchain, headless Chrome, this repository, the Robot
virtualenv and every base image -- the Cisco one included. `./run-lab-vm.sh`
boots it; inside, `./start-lab.sh` brings up all seven inner VMs exactly as it
does on a bare host.

**Why this packages cleanly.** Nothing in the lab touches the host network. Every
link is a QEMU netdev on loopback -- `socket` for the router links, multicast
pinned to `lo` for the LANs and the out-of-band segment, user-mode NAT for
management. There is no bridge, tap, or host-side configuration to recreate, so
the lab is indifferent to the machine underneath it.

### What the destination host needs

* **Nested virtualisation** (`kvm_intel.nested=1` or `kvm_amd.nested=1`) and
  `-cpu host`. This is not a preference: without it the guest sees no `vmx`/`svm`
  and nothing inside can start. `run-lab-vm.sh` checks and refuses with the fix
  rather than letting it surface as inner VMs mysteriously failing to boot.
* **About 30 GB of RAM.** The inner lab commits 26.4 GB -- three routers at 8 GB
  each plus the hosts and the NMS -- and the appliance is sized for that, not for
  the outer OS.
* **Internet on first run**, for chrony's upstream only. `tac_plus` is already
  installed in the image. Air-gapped, the lab still runs and keeps coherent time
  through chrony's `local stratum 10`, but the NTP test asserting a real upstream
  will correctly fail.

### Verified, not assumed

The appliance was booted and the full suite run inside it: all seven VMs came up
from cold under nested KVM -- licence activation and reload included -- and the
suite passed **204/204** in 20.3 minutes, against 18.8 on bare metal. Throughput
held at the 15 Mbps target despite the nesting, which was the main doubt.

One test failed on the first run inside, and it was worth having. `21_vty_acl.robot`
asserted `show users` contained `10.0.2.2`; inside the appliance reverse DNS
resolves that address and IOS prints `_gateway` instead. The assertion was
reading a *rendered hostname* rather than the property under test. It now reads
the hit counter on the hypervisor-NAT permit, which proves a session was admitted
by exactly that ACE and does not care what DNS answers. A test that passes on one
host and fails on another for cosmetic reasons is precisely what moving an
environment should shake out.

### Notes

* Chrome comes from Google's upstream `.deb` rather than `chromium`, which on
  noble is a snap stub -- pulling in snapd would cost more than the browser. It is
  only ever run headless, by `tools/make_topology_pdf.sh`.
* The shipped image is pristine: the inner lab is stopped, `run/` and `results/`
  are empty and the filesystem has been trimmed, so the first `start-lab.sh` on a
  new host takes the factory-fresh path rather than finding existing overlays.
