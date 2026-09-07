*** Settings ***
Documentation     eBGP between the two routers, peered across the IPsec tunnel rather
...               than on the link addresses -- so the routing control plane itself
...               rides inside ESP. Loopback1 carries BGP-only prefixes; Loopback0
...               already has a static route that would outrank any eBGP path.
Resource          ../resources/c8000v.resource
Suite Setup       Establish BGP
Suite Teardown    Run Keywords    Restore BGP Baseline    AND    Close All Routers

*** Variables ***
${PING_COUNT}     20
${HOLD_TIME}      30
${BFD_DETECT}     15
# what each router may advertise: its BGP /32, its NAT domain, its LAN
&{OWN_PREFIXES}   R1=10.20.1.1/32,10.30.1.0/24,192.168.10.0/24
...               R2=10.20.2.1/32,10.30.2.0/24,192.168.20.0/24
...               R3=10.20.3.1/32,10.30.3.0/24,192.168.30.0/24
${OFF_LIST_ADDR}  10.77.77.77
${BAD_COMM_ADDR}  10.88.88.88
# a community that is well formed but belongs to no router in this topology
${UNKNOWN_COMM}   65500:9
# an AS this topology can never legitimately put in a path
${BOGUS_AS}       65099
${MAX_PREFIX}     15
${FLOOD_COUNT}    20
${FLOOD_NET}      10.99
# <origin ASN>:<class>, class 1=BGP loopback, 2=NAT domain, 3=LAN
&{PREFIX_COMMUNITY}    10.20.1.1/32=65001:1    10.30.1.0/24=65001:2    192.168.10.0/24=65001:3
...                    10.20.2.1/32=65002:1    10.30.2.0/24=65002:2    192.168.20.0/24=65002:3
...                    10.20.3.1/32=65003:1    10.30.3.0/24=65003:2    192.168.30.0/24=65003:3

*** Test Cases ***
BGP Sessions Are Established With The Expected Peer AS
    [Documentation]    The hub holds one session per spoke; each spoke holds exactly one.
    BGP Session Should Be Established    R1    ${R2_TUNNEL_LOCAL}    ${R2_ASN}
    BGP Session Should Be Established    R1    ${R3_TUNNEL_LOCAL}    ${R3_ASN}
    BGP Session Should Be Established    R2    ${R2_TUNNEL_HUB}    ${R1_ASN}
    BGP Session Should Be Established    R3    ${R3_TUNNEL_HUB}    ${R1_ASN}

Each Spoke Learns The Other Spoke Prefix Through The Hub
    [Documentation]    The defining property of this topology: spokes never peer with
    ...                each other, so R3's prefix can only reach R2 via the hub, and
    ...                its AS path must show both hops.
    Wait Until Keyword Succeeds    18x    5s    Cross Spoke Prefix Should Be Learned
    ...    R2    ${R3_BGP_PREFIX}    ${R2_TUNNEL_HUB}    ${R3_ASN}
    Wait Until Keyword Succeeds    18x    5s    Cross Spoke Prefix Should Be Learned
    ...    R3    ${R2_BGP_PREFIX}    ${R3_TUNNEL_HUB}    ${R2_ASN}

Every Peer Is Configured With MD5 Authentication
    [Documentation]    The negative test below proves a wrong password is rejected;
    ...                this proves no peer was left without one in the first place.
    FOR    ${r}    IN    @{ROUTERS}
        ${cfg}=    Run On    ${r}    show running-config | include ^ neighbor .* remote-as|^ neighbor .* password
        @{remote}=    Get Regexp Matches    ${cfg}    neighbor (\\S+) remote-as    1
        @{secured}=   Get Regexp Matches    ${cfg}    neighbor (\\S+) password    1
        Should Not Be Empty    ${remote}    ${r} has no BGP neighbours at all
        Lists Should Be Equal    ${remote}    ${secured}    ignore_order=${TRUE}
        ...    msg=${r}: neighbours ${remote} but only ${secured} carry a password
    END

A BFD Session Is Up For Every BGP Peer
    [Documentation]    One BFD session per peer, on the tunnel the peer address
    ...                lives on -- the hub therefore holds two.
    ${hub}=    Run On    R1    show bfd neighbors
    Should Contain    ${hub}    ${R2_TUNNEL_LOCAL}
    Should Contain    ${hub}    ${R3_TUNNEL_LOCAL}
    Should Not Contain    ${hub}    Down
    FOR    ${r}    IN    R2    R3
        ${out}=    Run On    ${r}    show bfd neighbors
        Should Contain    ${out}    ${${r}_TUNNEL_HUB}
        Should Not Contain    ${out}    Down
    END

BGP Uses BFD For Fall-over On Every Peer
    [Documentation]    A BFD session that no protocol consumes would detect failures
    ...                and change nothing, so this checks BGP is the registered
    ...                client rather than just that BFD is running.
    FOR    ${r}    IN    @{ROUTERS}
        ${cfg}=    Run On    ${r}    show running-config | include ^ neighbor .* remote-as|fall-over bfd
        @{remote}=    Get Regexp Matches    ${cfg}    neighbor (\\S+) remote-as    1
        @{bfd}=       Get Regexp Matches    ${cfg}    neighbor (\\S+) fall-over bfd    1
        Lists Should Be Equal    ${remote}    ${bfd}    ignore_order=${TRUE}
        ...    msg=${r}: neighbours ${remote} but only ${bfd} use BFD fall-over
        ${clients}=    Run On    ${r}    show bfd neighbors client bgp
        Should Not Contain    ${clients}    Down
    END

BFD Tears The Session Down Long Before The Hold Time
    [Documentation]    The test that makes BFD more than configuration. An ACL on
    ...                the hub's tunnel drops only BFD control packets (UDP 3784 and
    ...                3785) and leaves BGP's TCP session untouched, so ordinary BGP
    ...                liveness is unaffected. Without fall-over the session would
    ...                survive until the ${HOLD_TIME}s hold time expires; with it,
    ...                BFD declares the peer down in about a second and BGP follows.
    BGP Session Should Be Established    R1    ${R2_TUNNEL_LOCAL}    ${R2_ASN}
    Configure On    R1    ip access-list extended BLOCK-BFD
    ...    deny udp any any eq 3784    deny udp any any eq 3785    permit ip any any
    ${elapsed}=    Set Variable    ${0}
    TRY
        Configure On    R1    interface Tunnel0    ip access-group BLOCK-BFD in
        ${start}=    Evaluate    __import__("time").time()
        Wait Until Keyword Succeeds    ${BFD_DETECT}x    1s    Session Should Not Be Established
        ...    R1    ${R2_TUNNEL_LOCAL}
        ${elapsed}=    Evaluate    __import__("time").time() - ${start}
    FINALLY
        Configure On    R1    interface Tunnel0    no ip access-group BLOCK-BFD in
        Configure On    R1    no ip access-list extended BLOCK-BFD
    END
    Log    BGP dropped ${elapsed}s after BFD was blocked (hold time ${HOLD_TIME}s)    console=${TRUE}
    Should Be True    ${elapsed} < ${HOLD_TIME}
    ...    BGP took ${elapsed}s to drop -- no faster than the hold time, so BFD did nothing
    Wait Until Keyword Succeeds    24x    5s    BGP Session Should Be Established
    ...    R1    ${R2_TUNNEL_LOCAL}    ${R2_ASN}
    # Established is not converged: R1 has still to receive R2's prefixes and
    # re-advertise them to R3, which the next test asserts on.
    Wait Until Keyword Succeeds    18x    5s    Prefix Should Be Present On    R1    ${R2_BGP_PREFIX}
    Wait Until Keyword Succeeds    18x    5s    Prefix Should Be Present On    R3    ${R2_BGP_PREFIX}

Every Peer Has An Outbound Route-map Over Per-class Prefix-lists
    [Documentation]    One prefix-list per prefix class, and a route-map clause per
    ...                class so each can carry its own community. The clauses are
    ...                the whitelist: the route-map's implicit deny is what stops
    ...                anything unnamed being advertised.
    FOR    ${r}    IN    @{ROUTERS}
        @{peers}=    Peers Of    ${r}
        FOR    ${peer}    IN    @{peers}
            ${rm}=    Run On    ${r}    show running-config | include route-map RM-OUT-${peer} out
            Should Contain    ${rm}    RM-OUT-${peer}
            ...    ${r} does not apply an outbound route-map towards ${peer}
        END
        FOR    ${cls}    IN    LO    NAT    LAN
            ${pl}=    Run On    ${r}    show ip prefix-list PL-OWN-${cls}
            Should Contain    ${pl}    PL-OWN-${cls}
            ...    ${r} has no prefix-list for its own ${cls} prefix
        END
    END

Every Peer Has An Inbound Policy Matching Community And AS Path
    [Documentation]    Both matches sit in one permit clause, so they are ANDed and
    ...                the clause's implicit deny is the drop: a prefix with an
    ...                unknown community *or* an unexpected AS path falls through.
    FOR    ${r}    IN    @{ROUTERS}
        @{peers}=    Peers Of    ${r}
        FOR    ${peer}    IN    @{peers}
            ${applied}=    Run On    ${r}    show running-config | include route-map RM-IN-${peer} in
            Should Contain    ${applied}    RM-IN-${peer}
            ...    ${r} applies no inbound route-map to ${peer}
            ${rm}=    Run On    ${r}    show route-map RM-IN-${peer}
            Should Contain    ${rm}    community (community-list filter): CL-VALID
            ...    ${r}'s inbound policy for ${peer} does not match on communities
            Should Match Regexp    ${rm}    as-path \\(as-path filter\\): \\d+
            ...    ${r}'s inbound policy for ${peer} does not match on AS path
        END
        ${cl}=    Run On    ${r}    show ip community-list CL-VALID
        ${entries}=    Get Regexp Matches    ${cl}    permit \\d+:\\d+
        Length Should Be    ${entries}    9
        ...    ${r} knows ${entries} valid communities, expected the topology's nine
    END

Every Received Prefix Carries The Community Of Its Origin
    [Documentation]    A prefix is tagged by the router that owns it, so the
    ...                community identifies both the origin AS and the kind of
    ...                prefix. Checked on the receiver, which is the only place it
    ...                proves the tag survived the wire.
    @{prefixes}=    Get Dictionary Keys    ${PREFIX_COMMUNITY}
    FOR    ${r}    IN    @{ROUTERS}
        FOR    ${pfx}    IN    @{prefixes}
            ${owner}=    Owner Of Prefix    ${pfx}
            Continue For Loop If    '${owner}' == '${r}'
            Wait Until Keyword Succeeds    12x    5s    Community Should Be
            ...    ${r}    ${pfx}    ${PREFIX_COMMUNITY}[${pfx}]
        END
    END

Re-advertised Prefixes Keep Their Origin Community Through The Hub
    [Documentation]    A spoke-to-spoke prefix crosses the hub, which re-advertises
    ...                it. If the hub re-tagged it the community would say 65001 and
    ...                the origin would be lost, so this asserts the far spoke's own
    ...                community survives the hop.
    Community Should Be    R2    10.20.3.1/32    65003:1
    Community Should Be    R2    192.168.30.0/24    65003:3
    Community Should Be    R3    10.20.2.1/32    65002:1
    Community Should Be    R3    192.168.20.0/24    65002:3

A Prefix With An Unknown Community Is Rejected Inbound
    [Documentation]    The prefix is explicitly permitted *outbound* by a temporary
    ...                clause, so the outbound whitelist cannot be what stops it --
    ...                only the inbound community match can. The test asserts R2
    ...                really did advertise it before asserting R1 refused it,
    ...                otherwise it would pass whenever the advertisement failed.
    [Teardown]    Remove Test Prefix From R2
    Advertise Test Prefix From R2    set community ${UNKNOWN_COMM}
    ${adv}=    Run On    R2    show bgp ipv4 unicast neighbors ${R2_TUNNEL_HUB} advertised-routes
    Should Contain    ${adv}    ${BAD_COMM_ADDR}
    ...    R2 never advertised the prefix, so this proves nothing about the inbound policy
    ${hub}=    Run On    R1    show bgp ipv4 unicast ${BAD_COMM_ADDR}
    Should Contain    ${hub}    Network not in table
    ...    the hub accepted a prefix carrying community ${UNKNOWN_COMM}

Every Peer Has A Maximum-prefix Limit With Headroom
    [Documentation]    Filtering controls what a peer may send; this controls how
    ...                much. The limit must sit above normal load or it would trip
    ...                in steady state -- a hub holds 3 prefixes per spoke, a spoke
    ...                6 -- and far below anything that could exhaust memory.
    FOR    ${r}    IN    @{ROUTERS}
        ${cfg}=    Run On    ${r}    show running-config | include ^ neighbor .* remote-as|maximum-prefix
        @{remote}=    Get Regexp Matches    ${cfg}    neighbor (\\S+) remote-as    1
        @{limited}=   Get Regexp Matches    ${cfg}    neighbor (\\S+) maximum-prefix    1
        Lists Should Be Equal    ${remote}    ${limited}    ignore_order=${TRUE}
        ...    msg=${r}: neighbours ${remote} but only ${limited} have a maximum-prefix
        ${summary}=    Run On    ${r}    show bgp ipv4 unicast summary | begin Neighbor
        @{counts}=    Get Regexp Matches    ${summary}    (?m)^\\d+\\.\\S+\\s+.*\\s+(\\d+)$    1
        FOR    ${n}    IN    @{counts}
            Should Be True    ${n} < ${MAX_PREFIX}
            ...    ${r} already holds ${n} prefixes against a limit of ${MAX_PREFIX}
        END
    END

A Peer That Floods Prefixes Is Torn Down Rather Than Absorbed
    [Documentation]    R2 originates ${FLOOD_COUNT} extra prefixes, tagged with a
    ...                valid community and carrying a valid AS path, and explicitly
    ...                permitted outbound -- so neither the whitelist, the community
    ...                match nor the AS-path filter can be what stops them. Only the
    ...                prefix count is left. The hub must drop the session instead of
    ...                accepting an unbounded table.
    [Teardown]    Stop Flooding From R2
    Start Flooding From R2
    Wait Until Keyword Succeeds    18x    5s    Session Should Not Be Established
    ...    R1    ${R2_TUNNEL_LOCAL}
    ${state}=    Run On    R1    show bgp ipv4 unicast summary | include ${R2_TUNNEL_LOCAL}
    Should Contain    ${state}    PfxCt
    ...    the session went down, but not because of the prefix count: ${state}
    ${log}=    Run On    R1    show logging | include MAXPFXEXCEED
    Should Contain    ${log}    ${R2_TUNNEL_LOCAL}
    ...    the hub logged no maximum-prefix violation for ${R2_TUNNEL_LOCAL}

The Session Recovers Once The Flood Stops
    [Documentation]    A maximum-prefix teardown is deliberately sticky -- no
    ...                "restart" is configured -- so recovery takes an operator
    ...                clearing it. This asserts the lab returns to a converged
    ...                state rather than leaving the next suite a broken topology.
    Wait Until Keyword Succeeds    24x    5s    BGP Session Should Be Established
    ...    R1    ${R2_TUNNEL_LOCAL}    ${R2_ASN}
    Wait Until Keyword Succeeds    18x    5s    Prefix Should Be Present On    R1    ${R2_BGP_PREFIX}
    Wait Until Keyword Succeeds    18x    5s    Prefix Should Be Present On    R3    ${R2_BGP_PREFIX}

A Prefix With An Invalid AS Path Is Rejected Inbound
    [Documentation]    Same prefix, this time with a valid community but an AS path
    ...                this topology cannot produce. Only the AS-path match differs,
    ...                so a rejection here isolates that filter.
    [Teardown]    Remove Test Prefix From R2
    Advertise Test Prefix From R2    set community ${R2_ASN}:1    set as-path prepend ${BOGUS_AS}
    ${adv}=    Run On    R2    show bgp ipv4 unicast neighbors ${R2_TUNNEL_HUB} advertised-routes
    Should Contain    ${adv}    ${BAD_COMM_ADDR}
    ...    R2 never advertised the prefix, so this proves nothing about the inbound policy
    ${hub}=    Run On    R1    show bgp ipv4 unicast ${BAD_COMM_ADDR}
    Should Contain    ${hub}    Network not in table
    ...    the hub accepted a prefix whose AS path contained ${BOGUS_AS}

Each Peer Is Advertised Exactly Its Whitelisted Prefixes
    [Documentation]    Not "at least" -- exactly. A whitelist that permits more than
    ...                intended still passes a containment check, so the advertised
    ...                set is compared for equality against what the peer should get:
    ...                a spoke sends only its own prefixes, the hub sends its own
    ...                plus the far spoke's.
    FOR    ${r}    IN    @{ROUTERS}
        @{peers}=    Peers Of    ${r}
        FOR    ${peer}    IN    @{peers}
            Wait Until Keyword Succeeds    18x    5s
            ...    Advertisement Should Match Whitelist    ${r}    ${peer}
        END
    END

A Prefix Outside The Whitelist Is Not Advertised
    [Documentation]    The point of a whitelist. A spoke originates a prefix nobody
    ...                authorised; it appears in that spoke's own BGP table, so the
    ...                origination worked, and must still never reach the hub.
    TRY
        Configure On    R2    interface Loopback99    ip address ${OFF_LIST_ADDR} 255.255.255.255
        Configure On    R2    router bgp ${R2_ASN}    address-family ipv4 unicast
        ...    network ${OFF_LIST_ADDR} mask 255.255.255.255
        Sleep    10s    reason=give BGP time to advertise it if the filter were absent
        ${local}=    Run On    R2    show bgp ipv4 unicast ${OFF_LIST_ADDR}
        Should Contain    ${local}    ${OFF_LIST_ADDR}
        ...    R2 never originated the prefix, so this test proves nothing
        ${adv}=    Advertised Prefixes    R2    R1
        Should Not Contain    ${adv}    ${OFF_LIST_ADDR}/32
        ...    R2 advertised an unlisted prefix to the hub
        ${hub}=    Run On    R1    show bgp ipv4 unicast ${OFF_LIST_ADDR}
        Should Contain    ${hub}    Network not in table
        ...    an unlisted prefix reached the hub
    FINALLY
        Run Keyword And Ignore Error    Configure On    R2    router bgp ${R2_ASN}
        ...    address-family ipv4 unicast    no network ${OFF_LIST_ADDR} mask 255.255.255.255
        Run Keyword And Ignore Error    Configure On    R2    no interface Loopback99
    END

Each Router Receives The Peer Prefix
    ${out}=    Run On    R1    show bgp ipv4 unicast
    Should Match Regexp    ${out}    \\*>\\s+${R2_BGP_PREFIX}/32\\s+${R2_TUNNEL_LOCAL}
    Should Contain    ${out}    ${R2_ASN}
    ${out}=    Run On    R2    show bgp ipv4 unicast
    Should Match Regexp    ${out}    \\*>\\s+${R1_BGP_PREFIX}/32\\s+${R2_TUNNEL_HUB}
    Should Contain    ${out}    ${R1_ASN}

Peer Prefix Is Learned Via BGP And Not A Static Route
    [Documentation]    Distinguishes a genuinely BGP-installed route from one that
    ...                merely happens to exist. eBGP is distance 20; a static is 1.
    ${out}=    Run On    R1    show ip route ${R2_BGP_PREFIX}
    Should Contain    ${out}    Known via "bgp ${R1_ASN}"
    Should Contain    ${out}    distance 20
    Should Contain    ${out}    type external

BGP Route Resolves Out The Encrypted Tunnel
    [Documentation]    The next hop is a tunnel address, so the forwarding path must
    ...                recurse to Tunnel0 rather than the cleartext link.
    ${out}=    Run On    R1    show ip cef ${R2_BGP_PREFIX}
    Should Contain    ${out}    ${R2_TUNNEL_LOCAL}
    Should Contain    ${out}    Tunnel0

Traffic Over The BGP-Learned Route Reaches The Peer
    [Documentation]    End to end: this only succeeds because BGP installed the route.
    Ping Should Fully Succeed    R1    ${R2_BGP_PREFIX}    source Loopback1 repeat 5

BGP-Routed Traffic Is Encrypted
    ${r1e}    ${r1d}=    Get IPsec Counters    R1
    ${r2e}    ${r2d}=    Get IPsec Counters    R2
    Ping Should Fully Succeed    R1    ${R2_BGP_PREFIX}    source Loopback1 repeat ${PING_COUNT}
    Wait Until Keyword Succeeds    12x    5s    ESP Counters Should Have Advanced
    ...    ${r1e}    ${r1d}    ${r2e}    ${r2d}    ${PING_COUNT}

BGP Control Plane Traffic Is Encrypted On The Wire
    [Documentation]    The reason for peering over the tunnel. Captures a keepalive
    ...                window and asserts the session is invisible: no TCP, no peering
    ...                addresses, no advertised prefixes -- only ESP.
    ${buf}=    Capture Link Traffic For    R1    14s    BGPCAP
    Should Contain    ${buf}    ESP
    Should Not Contain    ${buf}    TCP
    Should Not Contain    ${buf}    ${R2_TUNNEL_HUB}
    Should Not Contain    ${buf}    ${R2_TUNNEL_LOCAL}
    Should Not Contain    ${buf}    ${R1_BGP_PREFIX}
    Should Not Contain    ${buf}    ${R2_BGP_PREFIX}

Withdrawing A Prefix Removes It From The Peer
    [Documentation]    Shuts the advertised interface on R2 and requires R1 to lose
    ...                both the BGP path and the route, then restores it.
    Configure On    R2    interface Loopback1    shutdown
    Wait Until Keyword Succeeds    12x    5s    Prefix Should Be Absent From    R1    ${R2_BGP_PREFIX}
    Configure On    R2    interface Loopback1    no shutdown
    Wait Until Keyword Succeeds    12x    5s    Prefix Should Be Present On    R1    ${R2_BGP_PREFIX}
    Wait Until Keyword Succeeds    12x    5s    Prefix Should Be Present On    R2    ${R1_BGP_PREFIX}

Session Recovers After A Hard Clear
    Run On    R1    clear ip bgp *
    Wait Until Keyword Succeeds    18x    5s    BGP Session Should Be Established
    ...    R1    ${R2_TUNNEL_LOCAL}    ${R2_ASN}
    Wait Until Keyword Succeeds    12x    5s    Prefix Should Be Present On    R1    ${R2_BGP_PREFIX}

Mismatched MD5 Password Prevents The Session Coming Up
    [Documentation]    Negative control on BGP authentication, mirroring the IPsec
    ...                wrong-PSK test: without it, a session that accepted any peer
    ...                would still pass everything above.
    [Teardown]    Restore BGP Baseline
    Set BGP Password On    R2    WrongBgpSecret999
    Run On    R1    clear ip bgp *
    Run On    R2    clear ip bgp *
    Sleep    45s
    BGP Session Should Not Be Established    R1    ${R2_TUNNEL_LOCAL}

*** Keywords ***
Owner Of Prefix
    [Documentation]    Which router originates a prefix, read from its community.
    [Arguments]    ${prefix}
    ${asn}=    Evaluate    "${PREFIX_COMMUNITY}[${prefix}]".split(":")[0]
    ${owner}=    Set Variable If
    ...    '${asn}' == '${R1_ASN}'    R1
    ...    '${asn}' == '${R2_ASN}'    R2    R3
    RETURN    ${owner}

Community Should Be
    [Arguments]    ${alias}    ${prefix}    ${expected}
    ${out}=    Run On    ${alias}    show bgp ipv4 unicast ${prefix}
    Should Contain    ${out}    ${expected}
    ...    ${alias} holds ${prefix} without community ${expected}:\n${out}

Advertise Test Prefix From R2
    [Documentation]    Originates a prefix on R2 and permits it outbound explicitly,
    ...                with whatever "set" clauses the caller wants applied to it.
    [Arguments]    @{sets}
    Configure On    R2    interface Loopback98
    ...    ip address ${BAD_COMM_ADDR} 255.255.255.255
    Configure On    R2    ip prefix-list PL-TEST seq 5 permit ${BAD_COMM_ADDR}/32
    Configure On    R2    route-map RM-OUT-R1 permit 5
    ...    match ip address prefix-list PL-TEST    @{sets}
    Configure On    R2    router bgp ${R2_ASN}    address-family ipv4 unicast
    ...    network ${BAD_COMM_ADDR} mask 255.255.255.255
    Run On    R2    clear ip bgp * soft out
    # Polled, not slept: after the churn earlier in this suite the session may
    # still be re-establishing, and a fixed wait made this fail intermittently
    # in a full run while passing when the suite ran alone.
    Wait Until Keyword Succeeds    18x    5s    Test Prefix Should Be Advertised

Test Prefix Should Be Advertised
    ${adv}=    Run On    R2    show bgp ipv4 unicast neighbors ${R2_TUNNEL_HUB} advertised-routes
    Should Contain    ${adv}    ${BAD_COMM_ADDR}
    ...    R2 is not yet advertising the test prefix

Start Flooding From R2
    [Documentation]    Null0 routes plus network statements are far quicker than
    ...                creating interfaces, and reach the hub identically.
    ${cfg}=    Create List    ip prefix-list PL-FLOOD seq 5 permit ${FLOOD_NET}.0.0/16 le 32
    Configure On    R2    @{cfg}
    Configure On    R2    route-map RM-OUT-R1 permit 7
    ...    match ip address prefix-list PL-FLOOD    set community ${R2_ASN}:1
    FOR    ${i}    IN RANGE    ${FLOOD_COUNT}
        Configure On    R2    ip route ${FLOOD_NET}.${i}.0 255.255.255.0 Null0
    END
    FOR    ${i}    IN RANGE    ${FLOOD_COUNT}
        Configure On    R2    router bgp ${R2_ASN}    address-family ipv4 unicast
        ...    network ${FLOOD_NET}.${i}.0 mask 255.255.255.0
    END

Stop Flooding From R2
    FOR    ${i}    IN RANGE    ${FLOOD_COUNT}
        Run Keyword And Ignore Error    Configure On    R2    router bgp ${R2_ASN}
        ...    address-family ipv4 unicast    no network ${FLOOD_NET}.${i}.0 mask 255.255.255.0
        Run Keyword And Ignore Error    Configure On    R2
        ...    no ip route ${FLOOD_NET}.${i}.0 255.255.255.0 Null0
    END
    Run Keyword And Ignore Error    Configure On    R2    no route-map RM-OUT-R1 permit 7
    Run Keyword And Ignore Error    Configure On    R2    no ip prefix-list PL-FLOOD
    # the teardown is sticky by design, so the session needs clearing by hand
    Run Keyword And Ignore Error    Run On    R1    clear ip bgp ${R2_TUNNEL_LOCAL}

Remove Test Prefix From R2
    Run Keyword And Ignore Error    Configure On    R2    router bgp ${R2_ASN}
    ...    address-family ipv4 unicast    no network ${BAD_COMM_ADDR} mask 255.255.255.255
    Run Keyword And Ignore Error    Configure On    R2    no route-map RM-OUT-R1 permit 5
    Run Keyword And Ignore Error    Configure On    R2    no ip prefix-list PL-TEST
    Run Keyword And Ignore Error    Configure On    R2    no interface Loopback98

Advertisement Should Match Whitelist
    [Documentation]    Compared for equality, not containment: a whitelist that
    ...                permits more than intended would still pass a containment
    ...                check. Retried by the caller, because BGP churn earlier in
    ...                the suite leaves the hub briefly advertising only its own
    ...                prefixes until it has re-learned the far spoke's.
    [Arguments]    ${from}    ${to}
    ${expected}=    Expected Advertisement    ${from}    ${to}
    ${actual}=      Advertised Prefixes      ${from}    ${to}
    Lists Should Be Equal    ${actual}    ${expected}    ignore_order=${TRUE}
    ...    msg=${from} advertises ${actual} to ${to}, expected ${expected}

Cross Spoke Prefix Should Be Learned
    [Documentation]    A spoke reaches the other spoke's prefix only via the hub, so
    ...                the next hop must be the hub's tunnel address and the AS path
    ...                must show both hops. Polled: this prefix crosses two sessions
    ...                and lags the direct ones after any BGP churn.
    [Arguments]    ${alias}    ${prefix}    ${via}    ${far_asn}
    ${out}=    Run On    ${alias}    show bgp ipv4 unicast ${prefix}
    Should Contain    ${out}    ${via}
    Should Match Regexp    ${out}    ${R1_ASN}\\s+${far_asn}

Establish BGP
    [Documentation]    Suite 07 deliberately breaks and rekeys the IPsec tunnel, and
    ...                BGP peers across that tunnel -- so the session may still be
    ...                reconverging when this suite starts. Wait rather than assume.
    Open All Routers
    Wait Until Keyword Succeeds    24x    5s    BGP Session Should Be Established
    ...    R1    ${R2_TUNNEL_LOCAL}    ${R2_ASN}
    Wait Until Keyword Succeeds    24x    5s    BGP Session Should Be Established
    ...    R1    ${R3_TUNNEL_LOCAL}    ${R3_ASN}
    Wait Until Keyword Succeeds    24x    5s    BGP Session Should Be Established
    ...    R2    ${R2_TUNNEL_HUB}    ${R1_ASN}
    Wait Until Keyword Succeeds    12x    5s    Prefix Should Be Present On    R1    ${R2_BGP_PREFIX}
    Wait Until Keyword Succeeds    12x    5s    Prefix Should Be Present On    R2    ${R1_BGP_PREFIX}

Expected Advertisement
    [Documentation]    A spoke offers its own prefixes; the hub offers its own plus
    ...                the other spoke's, which is what makes spoke-to-spoke work.
    [Arguments]    ${from}    ${to}
    @{expected}=    Split String    ${OWN_PREFIXES}[${from}]    ,
    IF    '${from}' == '${HUB}'
        FOR    ${other}    IN    R2    R3
            IF    '${other}' != '${to}'
                @{more}=    Split String    ${OWN_PREFIXES}[${other}]    ,
                Append To List    ${expected}    @{more}
            END
        END
    END
    RETURN    ${expected}

Advertised Prefixes
    [Documentation]    What a router actually offers a peer, as CIDR strings. IOS
    ...                prints classful networks without a length, so a /24 shows as
    ...                "192.168.20.0"; normalise those back to CIDR.
    [Arguments]    ${alias}    ${peer}
    ${addr}=    Peer Address    ${alias}    ${peer}
    ${out}=    Run On    ${alias}    show bgp ipv4 unicast neighbors ${addr} advertised-routes
    @{raw}=    Get Regexp Matches    ${out}    (?m)^ [*>si ]+\\s*(\\d+\\.\\d+\\.\\d+\\.\\d+(?:/\\d+)?)    1
    @{out_list}=    Create List
    FOR    ${p}    IN    @{raw}
        ${p}=    Set Variable If    '/' in '${p}'    ${p}    ${p}/24
        Append To List    ${out_list}    ${p}
    END
    RETURN    ${out_list}

Peer Address
    [Arguments]    ${alias}    ${peer}
    IF    '${alias}' == '${HUB}'
        ${addr}=    Set Variable If    '${peer}' == 'R2'    ${R2_TUNNEL_LOCAL}    ${R3_TUNNEL_LOCAL}
    ELSE
        ${addr}=    Set Variable    ${${alias}_TUNNEL_HUB}
    END
    RETURN    ${addr}

Session Should Not Be Established
    [Arguments]    ${alias}    ${addr}
    ${out}=    Run On    ${alias}    show bgp ipv4 unicast summary | include ${addr}
    ${state}=    Evaluate    "${out}".split()[-1] if "${out}".split() else "gone"
    Should Not Match Regexp    ${state}    ^\\d+$
    ...    ${alias} still holds an established session with ${addr}

Set BGP Password On
    [Arguments]    ${alias}    ${password}
    ${asn}=    Set Variable If    '${alias}' == 'R1'    ${R1_ASN}    ${R2_ASN}
    ${peer}=    Set Variable If    '${alias}' == 'R1'    ${R2_TUNNEL_LOCAL}    ${R2_TUNNEL_HUB}
    Configure On    ${alias}    router bgp ${asn}    neighbor ${peer} password ${password}

Peers Of
    [Documentation]    The hub peers with both spokes; a spoke peers only with the hub.
    [Arguments]    ${alias}
    ${peers}=    Run Keyword If    '${alias}' == '${HUB}'
    ...    Create List    R2    R3
    ...    ELSE    Create List    ${HUB}
    RETURN    ${peers}

Prefix Should Be Present On
    [Arguments]    ${alias}    ${prefix}
    ${out}=    Run On    ${alias}    show ip route ${prefix}
    Should Contain    ${out}    Known via "bgp

Prefix Should Be Absent From
    [Arguments]    ${alias}    ${prefix}
    ${out}=    Run On    ${alias}    show ip route ${prefix}
    Should Contain    ${out}    % Subnet not in table

Restore BGP Baseline
    [Documentation]    Never leave the lab with a wrong BGP password or a shut interface.
    Run Keyword And Ignore Error    Set BGP Password On    R2    ${BGP_PASSWORD}
    Run Keyword And Ignore Error    Configure On    R2    interface Loopback1    no shutdown
    Run Keyword And Ignore Error    Run On    R1    clear ip bgp *
    Run Keyword And Ignore Error    Run On    R2    clear ip bgp *
    Run Keyword And Ignore Error    Wait Until Keyword Succeeds    18x    5s
    ...    BGP Session Should Be Established    R1    ${R2_TUNNEL_LOCAL}    ${R2_ASN}
