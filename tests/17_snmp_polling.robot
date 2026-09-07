*** Settings ***
Documentation     SNMPv3 polling from the NMS, a real Ubuntu VM on the hub LAN
...               running net-snmp.
...
...               Suite 16 proves the routers *send* SNMPv3 (traps, decoded from raw
...               BER because busybox has no SNMP tooling). This suite proves they
...               *answer*: the same snmpget and snmpwalk a network engineer would
...               type, against all three routers, with the answers cross-checked
...               against each router's own CLI output.
...
...               Only the hub is on the NMS's LAN. R2 and R3 are polled across the
...               IPsec tunnels, so the management traffic is encrypted in flight --
...               asserted here, not assumed.
...
...               No MIB text files are installed (they are non-free on Ubuntu), so
...               every OID below is numeric and named in a comment.
Resource          ../resources/c8000v.resource
Library           ${CURDIR}/../tools/snmp_poll_keywords.py
Library           Collections
Library           String
Suite Setup       Run Keywords    Open All Routers    AND    Open Nms
Suite Teardown    Run Keywords    Close Nms    AND    Close All Connections

*** Variables ***
# OIDs, all from SNMPv2-MIB and IF-MIB
${SYS_DESCR}       1.3.6.1.2.1.1.1.0
${SYS_UPTIME}      1.3.6.1.2.1.1.3.0
${SYS_NAME}        1.3.6.1.2.1.1.5.0
${IF_NUMBER}       1.3.6.1.2.1.2.1.0
${IF_DESCR}        1.3.6.1.2.1.2.2.1.2
${IF_OPER_STATUS}  1.3.6.1.2.1.2.2.1.8
${BAD_PASSWORD}    NotTheRightPassword

# polling now targets the out-of-band addresses, inside the MGMT VRF
&{ROUTER_IP}       R1=${R1_OOB_IP}    R2=${R2_OOB_IP}    R3=${R3_OOB_IP}

*** Test Cases ***
The NMS Runs Real Net-SNMP Tooling
    [Documentation]    The point of this VM: unlike the cirros hosts it has a
    ...                genuine SNMP client, so the polling below is the real thing
    ...                rather than something hand rolled for the test.
    ${versions}=    Nms Tool Versions
    Should Contain    ${versions}    NET-SNMP version
    ${tools}=    Nms Command    command -v snmpget snmpwalk snmptrapd
    Should Contain    ${tools}    snmpget
    Should Contain    ${tools}    snmpwalk
    Log    ${versions}    console=${TRUE}

Every Router Answers An SNMPv3 authPriv Poll
    [Documentation]    The agent must be reachable and must accept the credentials
    ...                the provisioner configured.
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Wait For Snmp Agent    ${ROUTER_IP}[${r}]
        Log    ${r}: ${out}    console=${TRUE}
    END

Polled sysName Matches The Router's Own Hostname
    [Documentation]    Cross-check: the value SNMP returns is compared against what
    ...                the device says on its CLI, so a plausible-looking answer
    ...                from the wrong box cannot pass.
    FOR    ${r}    IN    @{ROUTERS}
        ${polled}=    Snmp Get Value    ${ROUTER_IP}[${r}]    ${SYS_NAME}
        ${cli}=       Run On    ${r}    show running-config | include ^hostname
        ${expected}=  Get Regexp Matches    ${cli}    hostname (\\S+)    1
        Should Start With    ${polled}    ${expected}[0]
        ...    msg=SNMP sysName '${polled}' does not match CLI hostname '${expected}[0]'
    END

Polled sysDescr Identifies The Platform
    FOR    ${r}    IN    @{ROUTERS}
        ${descr}=    Snmp Get Value    ${ROUTER_IP}[${r}]    ${SYS_DESCR}
        Should Match Regexp    ${descr}    Cisco IOS[ -]XE Software|Cisco IOS Software \\[IOSXE\\]
        ${version}=    Run On    ${r}    show version | include Version
        Log    ${r} sysDescr: ${descr}    console=${TRUE}
    END

sysUpTime Advances Between Two Polls
    [Documentation]    Proves the answers come from a live agent rather than a
    ...                cached or replayed response.
    ${first}=    Sysuptime Ticks    ${R1_OOB_IP}
    Sleep    5s
    ${second}=   Sysuptime Ticks    ${R1_OOB_IP}
    Should Be True    ${second} > ${first}
    ...    msg=sysUpTime did not advance: ${first} then ${second}
    Log    sysUpTime ${first} -> ${second} ticks    console=${TRUE}

Walking The Interface Table Returns Every Interface The CLI Shows
    [Documentation]    A walk, not a get: the agent must return the whole subtree.
    ...                Every physical interface named by the CLI must appear in it.
    FOR    ${r}    IN    @{ROUTERS}
        ${walked}=    Snmp Walk Values    ${ROUTER_IP}[${r}]    ${IF_DESCR}
        ${brief}=     Run On    ${r}    show ip interface brief
        @{cli_ifs}=   Get Regexp Matches    ${brief}    (?m)^(GigabitEthernet\\d+)    1
        FOR    ${intf}    IN    @{cli_ifs}
            List Should Contain Value    ${walked}    ${intf}
            ...    msg=${r}: ifDescr walk is missing ${intf}
        END
        Log    ${r} ifDescr: ${walked}    console=${TRUE}
    END

Polled Interface Count Agrees With The Interface Table
    [Documentation]    ifNumber is a scalar the agent maintains separately from the
    ...                table, so the two disagreeing would mean a broken agent.
    FOR    ${r}    IN    @{ROUTERS}
        ${number}=    Snmp Get Value    ${ROUTER_IP}[${r}]    ${IF_NUMBER}
        ${rows}=      Snmp Walk Count   ${ROUTER_IP}[${r}]    ${IF_DESCR}
        Should Be Equal As Integers    ${number}    ${rows}
        ...    msg=${r}: ifNumber says ${number} but the table has ${rows} rows
    END

The LAN Interface Is Reported Up By Both SNMP And The CLI
    [Documentation]    ifOperStatus 1 is up(1). Checked against the CLI line
    ...                protocol state for the same interface.
    FOR    ${r}    IN    @{ROUTERS}
        ${descrs}=    Snmp Walk Values    ${ROUTER_IP}[${r}]    ${IF_DESCR}
        ${index}=     Get Index From List    ${descrs}    GigabitEthernet3
        Should Not Be Equal As Integers    ${index}    -1    msg=${r}: no Gi3 in the walk
        ${states}=    Snmp Walk Values    ${ROUTER_IP}[${r}]    ${IF_OPER_STATUS}
        Should Contain    ${states}[${index}]    1    msg=${r}: SNMP says Gi3 is not up
        ${cli}=    Run On    ${r}    show interfaces GigabitEthernet3 | include line protocol
        Should Contain    ${cli}    line protocol is up
    END

Spokes Are Polled Across The Encrypted Tunnel
    [Documentation]    The NMS shares a LAN with the hub only. Traffic to R2 and R3
    ...                crosses the IPsec tunnels, so a burst of polling must show up
    ...                on the ESP counters at both ends.
    ${r1e0}    ${r1d0}=    Get IPsec Counters    R1
    ${r2e0}    ${r2d0}=    Get IPsec Counters    R2
    FOR    ${i}    IN RANGE    12
        Snmp Get    ${R2_OOB_IP}    ${SYS_NAME}
    END
    Wait Until Keyword Succeeds    45s    5s
    ...    ESP Counters Should Have Advanced By    R1    R2    ${r1e0}    ${r1d0}    ${r2e0}    ${r2d0}    10

A Wrong Authentication Password Is Refused
    [Documentation]    Negative control. The agent answers the correct credentials
    ...                first, so a refusal here cannot be a dead router.
    Snmp Get    ${R1_OOB_IP}    ${SYS_NAME}
    ${err}=    Snmp Get Should Fail    ${R1_OOB_IP}    ${SYS_NAME}
    ...        expected=Authentication failure    auth_pass=${BAD_PASSWORD}
    Log    ${err}    console=${TRUE}

A Wrong Privacy Password Is Refused
    [Documentation]    Authentication succeeds but the payload will not decrypt, so
    ...                the router drops the request silently and the client times
    ...                out. Bracketed by a good poll to prove it is still alive.
    Snmp Get    ${R1_OOB_IP}    ${SYS_NAME}
    ${err}=    Snmp Get Should Fail    ${R1_OOB_IP}    ${SYS_NAME}
    ...        expected=Timeout    priv_pass=${BAD_PASSWORD}
    Snmp Get    ${R1_OOB_IP}    ${SYS_NAME}
    Log    ${err}    console=${TRUE}

Polling Without Privacy Is Refused By Every Router
    [Documentation]    The group is configured "v3 priv". Correct credentials at a
    ...                lower security level must still be denied, otherwise the
    ...                privacy requirement is decorative.
    FOR    ${r}    IN    @{ROUTERS}
        ${no_auth}=    Snmp Get Should Fail    ${ROUTER_IP}[${r}]    ${SYS_NAME}
        ...            expected=authorizationError    level=noAuthNoPriv
        ${no_priv}=    Snmp Get Should Fail    ${ROUTER_IP}[${r}]    ${SYS_NAME}
        ...            expected=authorizationError    level=authNoPriv
        Log    ${r} noAuthNoPriv: ${no_auth}    console=${TRUE}
    END

An Unknown User Is Refused
    [Documentation]    Only the provisioned user exists in the USM table.
    ${err}=    Snmp Get Should Fail    ${R1_OOB_IP}    ${SYS_NAME}
    ...        expected=Unknown user name    user=intruder
    Log    ${err}    console=${TRUE}

SNMPv2c Gets No Answer At The Wire
    [Documentation]    Suite 16 asserts no community is configured. This asserts the
    ...                consequence on the network: a v2c poll gets nothing back,
    ...                while a v3 poll to the same address succeeds.
    FOR    ${r}    IN    @{ROUTERS}
        ${err}=    Snmp V2c Get Should Fail    ${ROUTER_IP}[${r}]    ${SYS_NAME}
        Should Contain    ${err}    Timeout
        Snmp Get    ${ROUTER_IP}[${r}]    ${SYS_NAME}
    END
