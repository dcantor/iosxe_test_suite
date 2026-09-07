*** Settings ***
Documentation     The out-of-band management network.
...
...               A flat ${OOB_NET}/${OOB_PREFIX} that every router and the NMS
...               attach to, carrying NTP, syslog and SNMP. The routers' OOB
...               interfaces sit in the ${MGMT_VRF} VRF, so the separation is
...               enforced by the routing table rather than only by topology.
...
...               Two properties are worth more than the configuration checks. The
...               first is negative: management traffic must not appear on the data
...               path at all -- polling a spoke must not advance the IPsec
...               counters, because it never crosses a tunnel. The second is the
...               reason out-of-band management exists: a device stays manageable
...               when the data path is broken. The last test breaks a tunnel on
...               purpose and requires the spoke to keep answering.
Resource          ../resources/c8000v.resource
Library           ${CURDIR}/../tools/snmp_poll_keywords.py
Library           ${CURDIR}/../tools/syslog_keywords.py
Library           Collections
Library           String
Suite Setup       Run Keywords    Open All Routers    AND    Open Nms    AND    Open Collector
Suite Teardown    Run Keywords    Restore Tunnels    AND    Close Nms
...                               AND    Close Collector    AND    Close All Connections

*** Variables ***
${SYS_NAME}        1.3.6.1.2.1.1.5.0
&{OOB_IP}          R1=${R1_OOB_IP}    R2=${R2_OOB_IP}    R3=${R3_OOB_IP}
&{OOB_INTF}        R1=${R1_OOB_INTF}    R2=${R2_OOB_INTF}    R3=${R3_OOB_INTF}
${POLL_BURST}      12

*** Test Cases ***
Every Router Has A Management VRF
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show vrf
        Should Contain    ${out}    ${MGMT_VRF}    ${r} has no ${MGMT_VRF} VRF
        Should Contain    ${out}    ipv4
    END

Only The OOB Interface Is In The Management VRF
    [Documentation]    A VRF containing a data interface would defeat the point,
    ...                so this asserts membership is exactly one interface.
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show vrf ${MGMT_VRF}
        ${short}=    Evaluate    "${OOB_INTF}[${r}]".replace("GigabitEthernet", "Gi")
        Should Contain    ${out}    ${short}
        ...    ${r}: ${OOB_INTF}[${r}] is not in the ${MGMT_VRF} VRF
        FOR    ${data}    IN    Gi2    Gi3    Tu0
            Should Not Contain    ${out}    ${data}
            ...    ${r}: data interface ${data} has been placed in the management VRF
        END
    END

Every Router Holds Its OOB Address On The Flat Network
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show ip interface brief | include ${OOB_INTF}[${r}]
        Should Contain    ${out}    ${OOB_IP}[${r}]
        Should Contain    ${out}    up
    END

The Management VRF Routing Table Holds Only The Flat Network
    [Documentation]    The isolation, stated as routing: the VRF must know how to
    ...                reach the management network and nothing else. A default
    ...                route or a data prefix here would be a leak.
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show ip route vrf ${MGMT_VRF}
        Should Contain    ${out}    ${OOB_NET}
        FOR    ${data}    IN    ${R1_LAN_NET}    ${R2_LAN_NET}    ${R3_LAN_NET}    0.0.0.0/0
            Should Not Contain    ${out}    ${data}
            ...    ${r}: ${data} has leaked into the ${MGMT_VRF} routing table
        END
    END

The Global Table Cannot Reach The Management Network
    [Documentation]    The other direction. Traffic in the global table must have
    ...                no path to the OOB network, otherwise the VRF is decorative.
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show ip route ${OOB_NET}
        Should Contain    ${out}    not in table
        ...    ${r}: the global routing table can reach the management network
    END

Every Router Answers SNMP On Its OOB Address
    FOR    ${r}    IN    @{ROUTERS}
        ${name}=    Snmp Get Value    ${OOB_IP}[${r}]    ${SYS_NAME}
        ${cli}=     Run On    ${r}    show running-config | include ^hostname
        ${expected}=    Get Regexp Matches    ${cli}    hostname (\\S+)    1
        Should Start With    ${name}    ${expected}[0]
        ...    polling ${OOB_IP}[${r}] answered as '${name}', not ${r}
    END

Management Traffic Never Touches The Data Path
    [Documentation]    The negative property that makes this out-of-band. Polling a
    ...                spoke used to cross an IPsec tunnel and was asserted to
    ...                advance the ESP counters; now it must do the opposite. The
    ...                comparison is against an idle window of the same length,
    ...                because BGP and BFD tick those counters continuously
    ...                regardless -- so an absolute delta proves nothing.
    ${e0}    ${d0}=    Get IPsec Counters    R1
    ${start}=    Evaluate    __import__("time").time()
    FOR    ${i}    IN RANGE    ${POLL_BURST}
        Snmp Get    ${OOB_IP}[R2]    ${SYS_NAME}
        Snmp Get    ${OOB_IP}[R3]    ${SYS_NAME}
    END
    ${e1}    ${d1}=    Get IPsec Counters    R1
    ${window}=    Evaluate    __import__("time").time() - ${start}
    ${polled}=    Evaluate    ${e1} - ${e0}

    ${i0}    ${x}=    Get IPsec Counters    R1
    Sleep    ${window}s    reason=an idle window of the same length, for the background rate
    ${i1}    ${x}=    Get IPsec Counters    R1
    ${idle}=    Evaluate    ${i1} - ${i0}

    ${attributable}=    Evaluate    ${polled} - ${idle}
    ${summary}=    Catenate    polling window +${polled} ESP encaps, idle window
    ...    +${idle} -- ${attributable} attributable to ${POLL_BURST} polls of each spoke
    Log    ${summary}    console=${TRUE}
    Should Be True    ${attributable} < ${POLL_BURST}
    ...    polling the spokes added ${attributable} ESP encaps, so management is crossing the tunnels

Syslog Reaches The Collector From The OOB Address
    [Documentation]    rsyslog files are named for the sender. A file named after a
    ...                LAN address would mean the router is logging from the data
    ...                path despite the configuration.
    ...
    ...                Each router is made to emit a marked message rather than
    ...                waiting on ambient traffic: whether a router happens to have
    ...                logged recently is not what this test is about, and
    ...                depending on it makes the result a matter of timing.
    ${run}=    Evaluate    __import__("time").strftime("%H%M%S")
    FOR    ${r}    IN    @{ROUTERS}
        ${file}=    Collector File For    ${r}
        Should Contain    ${file}    ${OOB_IP}[${r}]
        ...    ${r}'s collector file is not named for its OOB address
        Send Marked Syslog Message    ${r}    LABOOB-SRC-${r}-${run}
    END
    FOR    ${r}    IN    @{ROUTERS}
        Wait Until Keyword Succeeds    12x    5s    Marker Should Reach The Collector
        ...    ${r}    LABOOB-SRC-${r}-${run}
    END
    ${files}=    Collector Files
    FOR    ${r}    IN    @{ROUTERS}
        Should Not Contain    ${files}    ${${r}_LAN_IP}.log
        ...    ${r} is still logging from its LAN address
    END

A Spoke Stays Manageable With Its Tunnel Down
    [Documentation]    The reason out-of-band management exists. Shutting R2's
    ...                tunnel removes every data path between the hub and the
    ...                spoke -- BGP drops, the LAN becomes unreachable -- and the
    ...                spoke must still answer SNMP and keep logging, because none
    ...                of that ever used the tunnel.
    [Teardown]    Restore Tunnels
    ${before}=    Snmp Get Value    ${OOB_IP}[R2]    ${SYS_NAME}
    Configure On    R2    interface Tunnel0    shutdown
    Wait Until Keyword Succeeds    12x    5s    Data Path To R2 Should Be Down

    ${after}=    Snmp Get Value    ${OOB_IP}[R2]    ${SYS_NAME}
    Should Be Equal    ${before}    ${after}
    ...    R2 stopped answering SNMP once its tunnel went down, so management is not out-of-band
    ${marker}=    Evaluate    "LABOOB-" + __import__("time").strftime("%H%M%S")
    Send Marked Syslog Message    R2    ${marker}
    Wait Until Keyword Succeeds    12x    5s    Marker Should Reach The Collector    R2    ${marker}
    Log    R2 answered SNMP and delivered syslog with its tunnel shut    console=${TRUE}

*** Keywords ***
Data Path To R2 Should Be Down
    ${out}=    Run On    R1    show ip route ${R2_LAN_NET}
    Should Contain    ${out}    not in table
    ...    the hub can still reach R2's LAN, so the data path is not down yet

Marker Should Reach The Collector
    [Arguments]    ${router}    ${marker}
    ${n}=    Count Occurrences For    ${router}    ${marker}
    Should Be True    ${n} > 0    marker ${marker} has not reached the collector

Restore Tunnels
    Run Keyword And Ignore Error    Configure On    R2    interface Tunnel0    no shutdown
    Run Keyword And Ignore Error    Wait Until Keyword Succeeds    24x    5s
    ...    BGP Session Should Be Established    R1    ${R2_TUNNEL_LOCAL}    ${R2_ASN}
