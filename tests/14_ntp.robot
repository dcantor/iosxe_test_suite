*** Settings ***
Documentation     NTP: every router synchronises from the NMS across the flat
...               out-of-band management network, inside the MGMT VRF.
...
...               The routers no longer reach pool.ntp.org themselves -- the OOB
...               network has no route to the internet, which is the point of it.
...               Instead the NMS synchronises upstream through its own NAT
...               interface and serves the management network, so the public pool
...               is still the source of truth, one stratum further away.
...
...               That makes the NMS's own upstream health a precondition rather
...               than a detail: chrony is configured with "local stratum 10", so
...               it keeps serving even with no upstream at all. Without the test
...               below, the whole lab could agree precisely on fabricated time and
...               every other assertion here would still pass.
...
...               Synchronisation is not instant -- NTP polls at 64-second intervals
...               and needs several exchanges before it will declare itself
...               synchronised -- so the assertions that depend on convergence poll
...               rather than sampling once.
Resource          ../resources/c8000v.resource
Library           ${CURDIR}/../tools/ntp_keywords.py
Suite Setup       Open All Routers
Suite Teardown    Run Keywords    Close Nms Session    AND    Close All Connections

*** Variables ***
${MAX_STRATUM}       6
${MAX_SKEW_SECONDS}  5
${MAX_OFFSET_MS}     500
&{OOB_INTF}          R1=${R1_OOB_INTF}    R2=${R2_OOB_INTF}    R3=${R3_OOB_INTF}

*** Test Cases ***
Every Router Is An NTP Client Of The NMS Over The Management VRF
    FOR    ${r}    IN    @{ROUTERS}
        ${cfg}=    Run On    ${r}    show running-config | include ^ntp
        Should Contain    ${cfg}    ntp source ${OOB_INTF}[${r}]
        Should Contain    ${cfg}    ntp server vrf ${MGMT_VRF} ${NMS_OOB_IP}
        ...    ${r} does not point at the NMS inside the ${MGMT_VRF} VRF
        Should Not Contain    ${cfg}    pool.ntp.org
        ...    ${r} still reaches a public pool server directly, bypassing the OOB design
    END

The NMS Itself Synchronises To The Public Pool
    [Documentation]    The precondition the rest of this suite rests on. chrony is
    ...                configured "local stratum 10", so it serves time whether or
    ...                not it has an upstream -- meaning the routers can agree
    ...                perfectly on time that came from nowhere. This requires a
    ...                real upstream: a reference that is not the local clock, and
    ...                a stratum that proves it came from somewhere else.
    ${tracking}=    Nms Chrony    chronyc tracking
    Log    ${tracking}    console=${TRUE}
    # 7F7F0101 is 127.127.1.1, the refid chrony reports when it is serving its
    # own clock. Written as one token: four spaces inside a Robot argument split
    # it in two, which silently turned the message into the search term.
    Should Not Contain    ${tracking}    7F7F0101
    ...    the NMS is serving its own local clock, so lab time is fabricated
    ${m}=    Get Regexp Matches    ${tracking}    Stratum\\s+:\\s+(\\d+)    1
    Should Not Be Empty    ${m}    could not read the NMS stratum
    Should Be True    0 < ${m}[0] < ${MAX_STRATUM}
    ...    the NMS is at stratum ${m}[0], which is not a real upstream
    ${sources}=    Nms Chrony    chronyc -n sources
    Should Match Regexp    ${sources}    \\^\\*\\s+\\d+\\.\\d+\\.\\d+\\.\\d+
    ...    the NMS has selected no upstream source: ${sources}

Every Router Appears As A Client Of The NMS
    [Documentation]    Seen from the server, which is where a missing client shows
    ...                up as an absence rather than as a router quietly using
    ...                something else.
    ${clients}=    Nms Chrony    sudo chronyc clients
    FOR    ${r}    IN    @{ROUTERS}
        Should Contain    ${clients}    ${${r}_OOB_IP}
        ...    ${r} is not polling the NMS from its OOB address
    END

Every Router Forms Associations With Pool Servers
    FOR    ${r}    IN    @{ROUTERS}
        Wait Until Keyword Succeeds    20x    15s    Router Should Have Associations    ${r}
    END

Associations Become Reachable
    [Documentation]    A non-zero reach register means packets are actually coming
    ...                back, which distinguishes a working client from one that has
    ...                merely been configured.
    FOR    ${r}    IN    @{ROUTERS}
        Wait Until Keyword Succeeds    20x    15s    Router Should Have Reachable Peers    ${r}
    END

Every Router Selects A System Peer
    FOR    ${r}    IN    @{ROUTERS}
        Wait Until Keyword Succeeds    24x    15s    Router Should Select A Peer    ${r}
    END

Every Router Clock Is Synchronised
    [Documentation]    The end state: IOS declares the clock synchronised.
    ...
    ...                This lags real accuracy by a long way. IOS holds the flag back
    ...                until its loopfilter leaves the 'FREQ' drift-measurement phase,
    ...                measured on this platform at about 17 minutes from a cold NTP
    ...                start -- while the offset is already within milliseconds well
    ...                before that. The wait below is bounded to cover a freshly
    ...                provisioned lab; on a lab that has been up it returns on the
    ...                first poll and costs nothing.
    FOR    ${r}    IN    @{ROUTERS}
        Wait Until Keyword Succeeds    45x    30s    Router Clock Should Be Synchronised    ${r}
    END

Stratum Is Sane On Every Router
    [Documentation]    Stratum 16 means unsynchronised. A client of a stratum 1-2
    ...                pool server should land well below the limit.
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show ntp status
        ${m}=    Get Regexp Matches    ${out}    stratum (\\d+)    1
        Should Not Be Empty    ${m}    ${r}: no stratum reported
        Should Be True    ${m}[0] < ${MAX_STRATUM}
        ...    ${r} is at stratum ${m}[0], expected below ${MAX_STRATUM}
    END

The Reference Is One Of The Peers The Router Actually Polls
    [Documentation]    Guards against a router calling itself synchronised to
    ...                something that is not in its association list.
    FOR    ${r}    IN    @{ROUTERS}
        ${status}=    Run On    ${r}    show ntp status
        ${ref}=    Get Regexp Matches    ${status}    reference is (\\d+\\.\\d+\\.\\d+\\.\\d+)    1
        Should Not Be Empty    ${ref}    ${r}: no reference clock reported
        ${assoc}=    Run On    ${r}    show ntp associations
        ${rows}=    Association Rows    ${assoc}
        ${addrs}=    Evaluate    [row["address"] for row in $rows]
        Should Contain    ${addrs}    ${ref}[0]
        ...    ${r} claims reference ${ref}[0], which is not among its associations ${addrs}
    END

Clock Offset Is Small On Every Router
    FOR    ${r}    IN    @{ROUTERS}
        ${assoc}=    Run On    ${r}    show ntp associations
        ${rows}=    Association Rows    ${assoc}
        ${peer}=    Selected Association    ${rows}
        Should Not Be Equal    ${peer}    ${None}    ${r}: no system peer selected
        ${offset}=    Evaluate    abs($peer["offset"])
        Should Be True    ${offset} < ${MAX_OFFSET_MS}
        ...    ${r} offset from its system peer is ${offset} ms
    END

All Routers Agree On The Time
    [Documentation]    The practical payoff: three independently synchronised clocks
    ...                should read the same, which is what makes logs across the
    ...                fabric correlatable.
    ${c1}=    Run On    R1    show clock
    ${c2}=    Run On    R2    show clock
    ${c3}=    Run On    R3    show clock
    ${s12}=    Clock Skew Seconds    ${c1}    ${c2}
    ${s13}=    Clock Skew Seconds    ${c1}    ${c3}
    Log    skew R1-R2 ${s12}s, R1-R3 ${s13}s    console=${TRUE}
    Should Be True    ${s12} < ${MAX_SKEW_SECONDS}    R1 and R2 differ by ${s12}s
    Should Be True    ${s13} < ${MAX_SKEW_SECONDS}    R1 and R3 differ by ${s13}s

The Clock Is No Longer At The Boot Epoch
    [Documentation]    An unsynchronised IOS device reports a 1993 or 1900 clock;
    ...                a synchronised one reports now. This is the crude check that
    ...                catches a clock that never moved at all.
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show clock
        ${t}=    Parse Ios Clock    ${out}
        ${year}=    Evaluate    $t.year
        Should Be True    ${year} >= 2026    ${r} clock reads year ${year}
        # the leading * clears at the same moment the synchronised flag is set
        Wait Until Keyword Succeeds    10x    30s    Clock Should Be Authoritative    ${r}
    END

*** Keywords ***
Router Should Have Associations
    [Arguments]    ${alias}
    ${out}=    Run On    ${alias}    show ntp associations
    ${rows}=    Association Rows    ${out}
    Should Not Be Empty    ${rows}    ${alias} has no NTP associations yet

Router Should Have Reachable Peers
    [Arguments]    ${alias}
    ${out}=    Run On    ${alias}    show ntp associations
    ${rows}=    Association Rows    ${out}
    ${up}=    Reachable Associations    ${rows}
    Should Not Be Empty    ${up}    ${alias} has associations but none are reachable

Router Clock Should Be Synchronised
    [Arguments]    ${alias}
    ${out}=    Run On    ${alias}    show ntp status
    Should Contain    ${out}    Clock is synchronized
    ...    ${alias}: ${out.splitlines()[0]}

Clock Should Be Authoritative
    [Arguments]    ${alias}
    ${out}=    Run On    ${alias}    show clock
    Should Not Contain    ${out}    *
    ...    ${alias} clock is still flagged as not authoritative: ${out.strip()}

Router Should Select A Peer
    [Arguments]    ${alias}
    ${out}=    Run On    ${alias}    show ntp associations
    ${rows}=    Association Rows    ${out}
    ${peer}=    Selected Association    ${rows}
    Should Not Be Equal    ${peer}    ${None}    ${alias} has not selected a system peer
