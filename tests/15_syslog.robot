*** Settings ***
Documentation     Syslog: all three routers log to rsyslog on the NMS, over the
...               flat management network. Messages are sourced from each router's
...               OOB interface inside the MGMT VRF and reach the collector on the
...               out-of-band management network -- not across the data path, so a
...               spoke keeps logging even with its IPsec tunnel down.
...
...               The collector moved off h1 with the rest of the management plane.
...               That is not cosmetic: h1 could only run busybox nc, which attached
...               to its first sender and silently dropped every other source, so
...               each router needed a UDP port of its own. rsyslog serves all three
...               on port 514 and writes each sender's datagrams verbatim, so what
...               these tests parse is exactly what IOS put on the wire.
Resource          ../resources/c8000v.resource
Library           ${CURDIR}/../tools/syslog_keywords.py
Library           ${CURDIR}/../tools/ntp_keywords.py
Library           Collections
Library           String
Suite Setup       Start Collector And Routers
Suite Teardown    Run Keywords    Close Collector    AND    Close All Connections

*** Variables ***
${SYSLOG_HOST}     192.168.99.10
${SYSLOG_PORT}     514
${MGMT_VRF}        MGMT
&{OOB_INTF}        R1=${R1_OOB_INTF}    R2=${R2_OOB_INTF}    R3=${R3_OOB_INTF}
${TRAP_LEVEL}      informational
${MAX_TS_SKEW}     120

*** Test Cases ***
The Collector Is A Service On The NMS Serving Every Router On One Port
    [Documentation]    What the move bought: one rsyslog listener for all three
    ...                routers instead of one busybox listener per router, and a
    ...                system service rather than something a suite starts -- so no
    ...                run can leave a stale listener swallowing another's messages.
    ${state}=    Collector Is Running
    Should Be Equal    ${state}    active
    ${listening}=    Collector Listening On
    Should Contain    ${listening}    :${SYSLOG_PORT}
    Should Contain    ${listening}    rsyslogd
    Log    ${listening}    console=${TRUE}

Every Router Is Configured To Log To The Collector
    FOR    ${r}    IN    @{ROUTERS}
        ${cfg}=    Run On    ${r}    show running-config | include ^logging|^service (timestamps|sequence)
        Should Contain    ${cfg}    logging host ${SYSLOG_HOST}
        Should Contain    ${cfg}    logging source-interface ${OOB_INTF}[${r}] vrf ${MGMT_VRF}
        Should Contain    ${cfg}    service sequence-numbers
    END

Every Router Reports The Collector As An Active Logging Host
    [Documentation]    The router's own view: it should name the collector and show
    ...                a non-zero count of messages sent to it.
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show logging | include Trap logging|Logging to ${SYSLOG_HOST}
        Should Contain    ${out}    ${SYSLOG_HOST}
        Should Contain    ${out}    level ${TRAP_LEVEL}
    END

The Hub Message Reaches The Collector
    [Documentation]    End to end over the LAN: emit a uniquely marked message and
    ...                find it at the collector.
    ${marker}=    Set Variable    LABSYSLOG-HUB-${SUITE_RUN_ID}
    Send Marked Syslog Message    R1    ${marker}
    Wait Until Keyword Succeeds    12x    5s    Marker Should Arrive    R1    ${marker}

Each Spoke Message Reaches The Collector Across The Tunnel
    [Documentation]    The spokes have no direct path to h1's LAN; their messages
    ...                are carried by the tunnels and the hub's routing.
    FOR    ${r}    IN    R2    R3
        ${marker}=    Set Variable    LABSYSLOG-${r}-${SUITE_RUN_ID}
        Send Marked Syslog Message    ${r}    ${marker}
        Wait Until Keyword Succeeds    12x    5s    Marker Should Arrive    ${r}    ${marker}
    END

Received Messages Carry Facility Severity And Mnemonic
    ${marker}=    Set Variable    LABSYSLOG-FIELDS-${SUITE_RUN_ID}
    Send Marked Syslog Message    R1    ${marker}    FACCHECK    5    MNEMCHECK
    Wait Until Keyword Succeeds    12x    5s    Marker Should Arrive    R1    ${marker}
    ${found}=    Find Marked For    R1    ${marker}
    ${m}=    Set Variable    ${found}[0]
    Should Be Equal    ${m}[facility]     FACCHECK
    Should Be Equal    ${m}[mnemonic]     MNEMCHECK
    Should Be Equal    ${m}[sev]          5

Received Messages Carry Sequence Numbers
    [Documentation]    'service sequence-numbers' is configured, so every message
    ...                should be numbered -- which is how a collector detects loss.
    ${msgs}=    Syslog Messages For    R1
    Should Not Be Empty    ${msgs}
    ${seqs}=    Evaluate    [int(m["seq"]) for m in $msgs]
    ${uniq}=    Evaluate    len(set($seqs))
    Should Be True    ${uniq} > 1    only one distinct sequence number seen
    Should Be True    min($seqs) >= 0

Message Timestamps Agree With The Router Clock
    [Documentation]    Ties syslog to NTP: a message's timestamp should match the
    ...                sending router's clock. Skewed timestamps make a collector's
    ...                correlation across devices worthless.
    ${marker}=    Set Variable    LABSYSLOG-TIME-${SUITE_RUN_ID}
    Send Marked Syslog Message    R1    ${marker}
    Wait Until Keyword Succeeds    12x    5s    Marker Should Arrive    R1    ${marker}
    ${clock}=    Run On    R1    show clock
    ${now}=    Parse Ios Clock    ${clock}
    ${found}=    Find Marked For    R1    ${marker}
    ${skew}=    Syslog Timestamp Skew    ${found}[0][ts]    ${now.isoformat()}
    Log    syslog timestamp is ${skew}s from the router clock    console=${TRUE}
    Should Be True    ${skew} < ${MAX_TS_SKEW}
    ...    syslog timestamp differs from the router clock by ${skew}s

Messages Below The Trap Level Are Not Forwarded
    [Documentation]    Negative control. Trap level is informational (6), so a
    ...                debug-severity (7) message must not reach the collector. If
    ...                this ever passes traffic, the level filter is not working and
    ...                the positive tests above prove much less than they appear to.
    ${marker}=    Set Variable    LABSYSLOG-DEBUG-${SUITE_RUN_ID}
    Send Marked Syslog Message    R1    ${marker}    LAB    7    DEBUGONLY
    Sleep    10s    reason=allow ample time for a message that should never arrive
    ${n}=    Count Occurrences For    R1    ${marker}
    Should Be Equal As Integers    ${n}    0
    ...    a debug-severity message reached the collector despite trap level ${TRAP_LEVEL}

All Three Routers Are Represented At The Collector
    [Documentation]    Messages from every router, distinguishable at the collector,
    ...                which is the point of a central log host.
    FOR    ${r}    IN    @{ROUTERS}
        ${marker}=    Set Variable    LABSYSLOG-ALL-${r}-${SUITE_RUN_ID}
        Send Marked Syslog Message    ${r}    ${marker}
    END
    FOR    ${r}    IN    @{ROUTERS}
        Wait Until Keyword Succeeds    12x    5s    Marker Should Arrive
        ...    ${r}    LABSYSLOG-ALL-${r}-${SUITE_RUN_ID}
    END

*** Keywords ***
Start Collector And Routers
    [Documentation]    Nothing to start: rsyslog is a service on the NMS and is
    ...                already receiving. This only opens the sessions used to read
    ...                it and to drive the routers.
    Open All Routers
    ${run_id}=    Evaluate    __import__("time").strftime("%H%M%S")
    Set Suite Variable    ${SUITE_RUN_ID}    ${run_id}
    Open Collector

Marker Should Arrive
    [Arguments]    ${router}    ${marker}
    ${n}=    Count Occurrences For    ${router}    ${marker}
    Should Be True    ${n} > 0
    ...    marker ${marker} has not reached ${router}'s collector
