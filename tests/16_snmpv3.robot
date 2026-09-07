*** Settings ***
Documentation     SNMPv3: every router runs an authPriv user and sends traps to the
...               NMS, alongside the syslog collector.
...
...               Two receivers get the same traps, because neither can do the
...               other's job. snmptrapd authenticates and decrypts them with a
...               per-router USM key, which proves the credentials and engine IDs
...               are right and shows the varbinds. A raw capture on a second port
...               keeps the datagrams byte for byte, which is the only way to show
...               the payload is encrypted in flight -- by the time snmptrapd logs a
...               trap it has already decrypted it.
...
...               Both replace the busybox nc collector on h1, which needed a port
...               per router and could leave stale listeners behind.
Resource          ../resources/c8000v.resource
Library           ${CURDIR}/../tools/snmp_keywords.py
Library           Collections
Suite Setup       Start Snmp Collectors
Suite Teardown    Run Keywords    Close Trap Collector    AND    Close All Connections

*** Variables ***
${COLLECTOR}       192.168.99.10
${SNMP_USER}       labmon
${SNMP_GROUP}      LABGRP
${TRAP_PORT}       162
${TRAP_RAW_PORT}   1162

*** Test Cases ***
Both Trap Receivers Are Services On The NMS
    [Documentation]    snmptrapd on the standard port and the raw capture on a
    ...                second one, both system services rather than listeners a
    ...                suite starts -- so no run can leave one behind, which is how
    ...                a negative test once passed while nothing was arriving.
    ${state}=    Trap Collectors Are Running
    Should Be Equal    ${state}    active active
    ${listening}=    Trap Collectors Listening On
    Should Contain    ${listening}    :${TRAP_PORT}
    Should Contain    ${listening}    :${TRAP_RAW_PORT}
    Log    ${listening}    console=${TRUE}

Every Router Has An SNMPv3 User With Authentication And Privacy
    [Documentation]    v3 without auth and priv is barely better than v2c, so the
    ...                protocols in use are asserted, not just the user's existence.
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show snmp user
        Should Contain    ${out}    User name: ${SNMP_USER}
        Should Contain    ${out}    Authentication Protocol: SHA
        Should Contain    ${out}    Privacy Protocol: AES128
        Should Contain    ${out}    Group-name: ${SNMP_GROUP}
    END

Every Router Has A v3 Group Requiring Privacy
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show snmp group
        Should Contain    ${out}    groupname: ${SNMP_GROUP}
        Should Contain    ${out}    security model:v3 priv
    END

No Router Accepts SNMPv1 Or v2c Communities
    [Documentation]    Security posture: configuring v3 is pointless if a community
    ...                string still gets you in.
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show running-config | include ^snmp-server community
        Should Be Empty    ${out}    ${r} still has an SNMP community configured: ${out}
    END

Every Router Targets The Collector With v3 Privacy
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show snmp host
        Should Contain    ${out}    ${COLLECTOR}
        Should Contain    ${out}    security model: v3 priv
        Should Contain    ${out}    user: ${SNMP_USER}
    END

Global Trap Sending Is Enabled
    [Documentation]    Enabling individual trap types leaves the global switch off:
    ...                the router builds trap PDUs and never sends them, which looks
    ...                exactly like a broken collector.
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show snmp | include global trap
        Should Contain    ${out}    SNMP global trap: enabled
    END

Traps From Every Router Reach The Collector
    FOR    ${r}    IN    @{ROUTERS}
        Trigger Trap On    ${r}
    END
    FOR    ${r}    IN    @{ROUTERS}
        Wait Until Keyword Succeeds    12x    5s    Router Should Have Sent Traps    ${r}
    END

Received Traps Are SNMP Version 3
    [Documentation]    Reads the version field out of the datagram itself rather
    ...                than trusting the configuration.
    FOR    ${r}    IN    @{ROUTERS}
        ${traps}=    Decoded Traps For    ${r}
        Should Not Be Empty    ${traps}    no traps captured for ${r}
        ${versions}=    Evaluate    sorted({t["version"] for t in $traps})
        Should Be Equal    ${versions}    ${{[3]}}
        ...    ${r} sent traps with versions ${versions}, expected only version 3
    END

Received Traps Carry The Configured User And Privacy Flags
    FOR    ${r}    IN    @{ROUTERS}
        ${traps}=    Decoded Traps For    ${r}
        ${users}=    Evaluate    sorted({t["user"] for t in $traps})
        Should Be Equal    ${users}    ${{['${SNMP_USER}']}}
        ...    ${r} traps carry users ${users}
        ${all_priv}=    Evaluate    all(t["auth"] and t["priv"] for t in $traps)
        Should Be True    ${all_priv}    ${r} sent traps without both auth and priv set
    END

Trap Payloads Are Encrypted
    [Documentation]    With privacy in force the scoped PDU arrives as an opaque
    ...                OCTET STRING. If it were a readable SEQUENCE the varbinds
    ...                would be on the wire in clear.
    FOR    ${r}    IN    @{ROUTERS}
        ${traps}=    Decoded Traps For    ${r}
        ${encrypted}=    Evaluate    all(t["encrypted"] for t in $traps)
        Should Be True    ${encrypted}    ${r} sent traps with a readable payload
    END

snmptrapd Decrypts Traps From Every Router
    [Documentation]    The strongest single statement this suite makes: a real SNMP
    ...                manager, holding only the configured user and each router's
    ...                engine ID, authenticated and decrypted the traps. That cannot
    ...                happen unless the keys, the engine IDs and the privacy
    ...                protocol all match on both sides.
    FOR    ${r}    IN    @{ROUTERS}
        ${entries}=    Snmptrapd Entries For    ${r}
        Should Not Be Empty    ${entries}
        ...    snmptrapd logged no decrypted traps from ${r}
        ${oids}=    Trap Oids In    ${entries}
        Should Not Be Empty    ${oids}
        ...    ${r}: snmptrapd decrypted traps but none carried snmpTrapOID.0
        Log    ${r}: ${entries.__len__()} decrypted traps, OIDs ${oids[-1]}    console=${TRUE}
    END

One Raw Listener Receives Every Router
    [Documentation]    The property the per-router-port workaround existed to dodge:
    ...                a single socket now serves all three senders.
    ${senders}=    Senders In Raw Capture
    Should Contain    ${senders}    ${R1_OOB_IP}
    Should Contain    ${senders}    ${R2_OOB_IP}
    Should Contain    ${senders}    ${R3_OOB_IP}
    Log    raw capture saw ${senders}    console=${TRUE}

Each Router Identifies Itself By Its Own Engine ID
    [Documentation]    The engine ID in the received trap must match the one the
    ...                router reports, and must differ between routers -- that is
    ...                what lets a collector attribute a trap to a device.
    ${seen}=    Create Dictionary
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show snmp engineID | include Local
        ${local}=    Get Regexp Matches    ${out}    Local SNMP engineID: ([0-9A-Fa-f]+)    1
        Should Not Be Empty    ${local}    ${r} reports no local engine ID
        ${traps}=    Decoded Traps For    ${r}
        ${ids}=    Evaluate    sorted({t["engine_id"].lower() for t in $traps})
        # compare case-insensitively: the CLI prints upper case, the wire is lower
        ${expected}=    Evaluate    "${local}[0]".lower()
        Length Should Be    ${ids}    1
        ...    ${r} traps carry more than one engine ID: ${ids}
        Should Be Equal    ${ids}[0]    ${expected}
        ...    ${r} traps carry engine ID ${ids}[0], expected its own ${expected}
        Set To Dictionary    ${seen}    ${r}    ${ids}[0]
    END
    ${distinct}=    Evaluate    len(set($seen.values()))
    Should Be Equal As Integers    ${distinct}    3
    ...    the three routers did not present three distinct engine IDs: ${seen}

*** Keywords ***
Start Snmp Collectors
    [Documentation]    Nothing to start: both receivers are services on the NMS.
    ...                This opens the sessions and primes each router with a trap.
    Open All Routers
    Open Trap Collector
    FOR    ${r}    IN    @{ROUTERS}
        Trigger Trap On    ${r}
    END
    Sleep    5s    reason=let the first traps land before any assertions

Trigger Trap On
    [Documentation]    A link-status flap on a throwaway loopback is a deterministic
    ...                way to make the router emit linkDown and linkUp traps.
    [Arguments]    ${alias}
    Configure On    ${alias}    interface Loopback270    ip address 10.99.97.1 255.255.255.255
    ...    snmp trap link-status
    Configure On    ${alias}    interface Loopback270    shutdown
    Sleep    2s
    Configure On    ${alias}    interface Loopback270    no shutdown
    Sleep    2s
    Configure On    ${alias}    no interface Loopback270

Router Should Have Sent Traps
    [Arguments]    ${alias}
    ${traps}=    Decoded Traps For    ${alias}
    Should Not Be Empty    ${traps}    no SNMPv3 traps captured from ${alias} yet
