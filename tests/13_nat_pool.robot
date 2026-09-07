*** Settings ***
Documentation     Source NAT at scale: 10 statically mapped addresses and 30 taken
...               from a dynamic pool, on every host.
...
...               Per host, .10-.19 each have their own one-to-one mapping to
...               10.30.<site>.10-.19, while .64-.93 are translated from a pool of
...               exactly 30 addresses, 10.30.<site>.100-.129. The pool has no
...               "overload", and is sized to match the number of clients, so a
...               correct run allocates it to 100% with no misses -- and any sharing
...               of addresses, or any client left untranslated, shows up plainly.
Resource          ../resources/c8000v.resource
Library           ${CURDIR}/../tools/nat_keywords.py
Suite Setup       Run Keywords    Open All Routers    AND    Open All Hosts
...                               AND    Wait For NAT Routes    AND    Reset Translations
Suite Teardown    Close All Connections

*** Variables ***
${PING_COUNT}     20
&{HOST_RTR}       H1=R1              H2=R2              H3=R3
&{MAPPED}         H1=${H1_NAT_IP}    H2=${H2_NAT_IP}    H3=${H3_NAT_IP}
# The pool ACL covers .64-.95 but only .64-.93 are configured on the host, so
# .94 is a pool-eligible source with no pool address left for it. On H1's LAN
# .20 belongs to the NMS, which is well clear of this.
${SPARE_OCTET}    94

*** Test Cases ***
Every Host Carries Its Full Block Of Addresses
    [Documentation]    10 statically mapped plus 30 pool-eligible, on one interface.
    FOR    ${h}    IN    @{HOSTS}
        ${out}=    Run On Host    ${h}    ip addr show eth1
        ${lan}=    Set Variable    ${LAN24}[${h}]
        FOR    ${o}    IN    ${STATIC_OCTET_FIRST}    ${STATIC_OCTET_LAST}    ${DYN_OCTET_FIRST}    ${DYN_OCTET_LAST}
            Should Contain    ${out}    ${lan}.${o}/24
        END
        # count only the lab's own addresses: cirros re-adds a 169.254 link-local
        # of its own, which is none of this test's business
        ${n}=    Run On Host    ${h}    ip addr show eth1 | grep -c 'inet ${lan}\.'
        Should Be Equal As Integers    ${n}    40
        ...    ${h} has ${n} addresses in ${lan}.0/24 on eth1, expected 40
    END

Every Router Configures Ten Static Mappings And A Thirty Address Pool
    FOR    ${h}    IN    @{HOSTS}
        ${r}=    Set Variable    ${HOST_RTR}[${h}]
        ${n}=    Run On    ${r}    show running-config | count ^ip nat inside source static
        Should Contain    ${n}    = 10
        ${stats}=    Run On    ${r}    show ip nat statistics
        Should Contain    ${stats}    total addresses 30
    END

The Pool Access List Is One Range And Excludes The Static Block
    [Documentation]    A single /27 range rather than thirty host entries, and it
    ...                must not overlap the statically mapped addresses -- otherwise
    ...                which rule wins depends on evaluation order.
    FOR    ${h}    IN    @{HOSTS}
        ${r}=    Set Variable    ${HOST_RTR}[${h}]
        ${lan}=    Set Variable    ${LAN24}[${h}]
        ${acl}=    Run On    ${r}    show ip access-lists NAT-POOL-SRC
        @{permits}=    Get Regexp Matches    ${acl}    permit
        Length Should Be    ${permits}    1
        ...    NAT-POOL-SRC should hold one range entry, found ${permits}
        Should Contain    ${acl}    ${lan}.${DYN_OCTET_FIRST} 0.0.0.31
        FOR    ${o}    IN    ${STATIC_OCTET_FIRST}    ${STATIC_OCTET_LAST}
            Should Not Contain    ${acl}    host ${lan}.${o}
        END
    END

All Ten Static Addresses Translate To Their Own Fixed Mapping
    [Documentation]    Static NAT is one-to-one and deterministic: inside .10-.19
    ...                must appear outside as .10-.19, each to its own.
    Generate Traffic From Every Source Address    H1    ${H2_NAT_IP}
    ${text}=    Run On    R1    show ip nat translations
    ${all}=     Translation Map    ${text}    ${LAN24}[H1]
    ${static}=  Subset By Octet    ${all}    ${STATIC_OCTET_FIRST}    ${STATIC_OCTET_LAST}
    Length Should Be    ${static}    10
    ...    only ${static} of the 10 static addresses were translated
    ${d}=    Distinct Values    ${static}
    Should Be Equal As Integers    ${d}    10
    ...    the 10 static addresses shared outside addresses; they must be one-to-one
    ${aligned}=    Mapping Is Octet Aligned    ${static}
    Should Be True    ${aligned}
    ...    a static mapping did not land on its configured counterpart

All Thirty Pool Addresses Translate Into The Pool And Are Distinct
    [Documentation]    Without overload each client takes its own pool address, so
    ...                30 clients must yield 30 different outside addresses.
    ${text}=    Run On    R1    show ip nat translations
    ${all}=     Translation Map    ${text}    ${LAN24}[H1]
    ${dyn}=     Subset By Octet    ${all}    ${DYN_OCTET_FIRST}    ${DYN_OCTET_LAST}
    Length Should Be    ${dyn}    30
    ...    only ${dyn} of the 30 pool clients were translated
    ${d}=    Distinct Values    ${dyn}
    Should Be Equal As Integers    ${d}    30
    ...    pool clients shared outside addresses; that is overload, not a 1:1 pool
    ${within}=    All Within Octets    ${dyn.values()}    ${POOL_OCTET_FIRST}    ${POOL_OCTET_LAST}
    Should Be True    ${within}
    ...    a translation landed outside the configured pool range

The Pool Is Exactly Consumed With No Misses
    [Documentation]    30 clients against a 30 address pool: full allocation and no
    ...                misses is the evidence that none of them shared or failed.
    ${stats}=    Run On    R1    show ip nat statistics
    Should Contain    ${stats}    allocated 30 (100%)
    Should Match Regexp    ${stats}    misses 0

A Thirty-first Client Gets No Translation Once The Pool Is Exhausted
    [Documentation]    The boundary the pool sizing never otherwise reaches. The
    ...                pool holds exactly as many addresses as there are clients,
    ...                which means the exhaustion path is never exercised by a
    ...                normal run -- and an off-by-one in pool bounds would look
    ...                identical to a correct configuration.
    ...
    ...                So bring up one more client inside the pool ACL and require
    ...                the router to refuse it: no translation, no borrowing of
    ...                another client's address, and the miss counted. Without
    ...                "overload" there is nothing to share, so silently reusing an
    ...                address would be a correctness bug, not graceful degradation.
    ...
    ...                Run against R1/H1, because it is R1's pool that the tests
    ...                above fill: the suite drives traffic from H1 first and only
    ...                reaches the other routers later. Asserting exhaustion on a
    ...                router whose pool is still empty would test nothing.
    [Teardown]    Remove The Spare Client From H1
    ${lan}=    Set Variable    ${LAN24}[H1]
    ${spare}=    Set Variable    ${lan}.${SPARE_OCTET}
    Pool Should Be Fully Allocated    R1
    # No clearing here: the suite setup established the baseline, and clearing
    # again mid-suite would mask a miss caused by anything before this point.
    ${before}=    Nat Miss Count    R1

    Run On Host    H1    sudo ip addr add ${spare}/24 dev eth1
    ${out}=    Run On Host    H1    ping -c 3 -W 2 -I ${spare} ${H2_NAT_IP}
    Should Contain    ${out}    100% packet loss
    ...    the thirty-first client was translated even though the pool was exhausted

    ${xlate}=    Run On    R1    show ip nat translations | include ${spare}
    Should Be Empty    ${xlate}
    ...    a translation exists for ${spare} despite an exhausted pool: ${xlate}
    # Polled, not read once: these counters are maintained in the dataplane and
    # lag the traffic by a few seconds, the same way the IPsec counters do.
    Wait Until Keyword Succeeds    12x    5s    Miss Counter Should Have Risen    R1    ${before}

The Pool Is Still Intact After The Exhaustion Attempt
    [Documentation]    The refusal must cost nothing: the thirty legitimate clients
    ...                keep the addresses they held, and none was evicted to make
    ...                room for the one that was turned away.
    Pool Should Be Fully Allocated    R1
    ${text}=    Run On    R1    show ip nat translations
    ${all}=     Translation Map    ${text}    ${LAN24}[H1]
    ${dyn}=     Subset By Octet    ${all}    ${DYN_OCTET_FIRST}    ${DYN_OCTET_LAST}
    Length Should Be    ${dyn}    30
    ...    only ${dyn} of the original thirty pool clients still hold a translation
    ${d}=    Distinct Values    ${dyn}
    Should Be Equal As Integers    ${d}    30
    ...    the refused client caused two survivors to share an address

Static And Pool Translations Coexist Across The Whole Block
    [Documentation]    All 40 of a host's addresses in flight, translated by two
    ...                different mechanisms, with no outside address reused.
    ${text}=    Run On    R1    show ip nat translations
    ${all}=     Translation Map    ${text}    ${LAN24}[H1]
    Length Should Be    ${all}    40
    ...    expected 40 translated addresses, found ${all}
    ${d}=    Distinct Values    ${all}
    Should Be Equal As Integers    ${d}    40
    ...    the 40 inside addresses did not receive 40 distinct outside addresses

Both Mechanisms Work On Every Router
    [Documentation]    The spokes carry the same scheme, not just the hub.
    FOR    ${h}    IN    H2    H3
        ${r}=    Set Variable    ${HOST_RTR}[${h}]
        Generate Traffic From Every Source Address    ${h}    ${H1_NAT_IP}
        ${text}=    Run On    ${r}    show ip nat translations
        ${all}=     Translation Map    ${text}    ${LAN24}[${h}]
        ${static}=  Subset By Octet    ${all}    ${STATIC_OCTET_FIRST}    ${STATIC_OCTET_LAST}
        ${dyn}=     Subset By Octet    ${all}    ${DYN_OCTET_FIRST}    ${DYN_OCTET_LAST}
        Length Should Be    ${static}    10    ${r}: ${static} static translations, expected 10
        Length Should Be    ${dyn}       30    ${r}: ${dyn} pool translations, expected 30
        ${aligned}=    Mapping Is Octet Aligned    ${static}
        Should Be True    ${aligned}
    END

Only The Static Mappings Live In The Configuration
    [Documentation]    Static mappings are configuration and survive a reload; pool
    ...                allocations are runtime state and do not. Confusing the two is
    ...                how NAT surprises people after a reboot.
    ${cfg}=    Run On    R1    show running-config | include ip nat inside source
    Should Contain    ${cfg}    static ${H1_IP} ${H1_NAT_IP}
    Should Not Contain    ${cfg}    ${NAT24}[R1].${POOL_OCTET_FIRST}
    Should Contain    ${cfg}    ip nat inside source list NAT-POOL-SRC pool SITE-POOL

Traffic From Both Mechanisms Is Encrypted
    ${r1e}    ${r1d}=    Get IPsec Counters    R1
    ${r2e}    ${r2d}=    Get IPsec Counters    R2
    Ping From Source Should Fully Succeed    H1    ${H1_IP}    ${H2_NAT_IP}    ${PING_COUNT}
    Ping From Source Should Fully Succeed    H1    ${LAN24}[H1].${DYN_OCTET_FIRST}    ${H2_NAT_IP}    ${PING_COUNT}
    Wait Until Keyword Succeeds    12x    5s    ESP Counters Should Have Advanced
    ...    ${r1e}    ${r1d}    ${r2e}    ${r2d}    ${PING_COUNT}

Neither Real Nor Translated Addresses Appear In Cleartext
    Start Link Capture    R1    POOLCAP    ${R2_HUB_INTF}
    Ping From Source Should Fully Succeed    H1    ${LAN24}[H1].${DYN_OCTET_FIRST}    ${H2_NAT_IP}    10
    ${buf}=    Stop Link Capture    R1    POOLCAP
    Should Contain    ${buf}    ESP
    Should Not Contain    ${buf}    ${LAN24}[H1].${DYN_OCTET_FIRST}
    Should Not Contain    ${buf}    ${NAT24}[R1].${POOL_OCTET_FIRST}

*** Keywords ***
Pool Should Be Fully Allocated
    [Arguments]    ${alias}
    ${out}=    Run On    ${alias}    show ip nat statistics | include allocated
    Should Contain    ${out}    allocated 30 (100%)
    ...    ${alias}'s pool is not fully allocated, so exhaustion is not being tested: ${out}

Nat Miss Count
    [Documentation]    Packets that matched the NAT rule but found no address free
    ...                -- the exhaustion signal. Read from the pool's own line:
    ...                "show ip nat statistics" also prints a global "Misses:"
    ...                counting something different, and a loose regexp picks up
    ...                whichever happens to come first.
    [Arguments]    ${alias}
    ${out}=    Run On    ${alias}    show ip nat statistics
    ${n}=    Get Regexp Matches    ${out}    allocated \\d+ \\(\\d+%\\), misses (\\d+)    1
    Should Not Be Empty    ${n}    could not read the pool miss counter from: ${out}
    RETURN    ${n}[0]

Miss Counter Should Have Risen
    [Arguments]    ${alias}    ${before}
    ${after}=    Nat Miss Count    ${alias}
    Should Be True    ${after} > ${before}
    ...    ${alias} counted no pool miss for the refused client (${before} -> ${after})
    Log    NAT pool misses ${before} -> ${after} for the thirty-first client    console=${TRUE}

Remove The Spare Client From H1
    ${lan}=    Set Variable    ${LAN24}[H1]
    Run Keyword And Ignore Error    Run On Host    H1
    ...    sudo ip addr del ${lan}.${SPARE_OCTET}/24 dev eth1

Reset Translations
    [Documentation]    Dynamic entries persist for hours, so clear them: the pool
    ...                allocation this suite asserts on must belong to this run.
    ...
    ...                The counters are cleared for the same reason. They are
    ...                cumulative, and this suite deliberately provokes misses when
    ...                it tests pool exhaustion -- so without a baseline here, one
    ...                run's exhaustion test makes the next run's "no misses"
    ...                assertion fail, in a different test, for a reason that looks
    ...                nothing like its cause.
    FOR    ${r}    IN    @{ROUTERS}
        Run On    ${r}    clear ip nat translation *
        Run On    ${r}    clear ip nat statistics
    END

Wait For NAT Routes
    FOR    ${r}    IN    @{ROUTERS}
        Wait Until Keyword Succeeds    24x    5s    NAT Prefixes Should Be Reachable    ${r}
    END

NAT Prefixes Should Be Reachable
    [Arguments]    ${alias}
    ${rt}=    Run On    ${alias}    show ip route
    Should Contain    ${rt}    ${R1_NAT_NET}
    Should Contain    ${rt}    ${R2_NAT_NET}
    Should Contain    ${rt}    ${R3_NAT_NET}
