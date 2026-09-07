*** Settings ***
Documentation     Reusable keywords for driving the two-router C8000V testbed over SSH.
Library           SSHLibrary    timeout=90s
Library           String
Library           Collections

*** Variables ***
@{ROUTERS}        R1    R2    R3
@{SPOKES}         R2    R3
@{HOSTS}          H1    H2    H3
${HUB}            R1
${USERNAME}       lab
${PASSWORD}       Lab_123!

${R1_HOST}        127.0.0.1
${R1_PORT}        2221
${R2_PORT}        2222
${R3_PORT}        2223
${R1_NAME}        c8000v-r1
${R2_NAME}        c8000v-r2
${R3_NAME}        c8000v-r3
${R1_ASN}         65001
${R2_ASN}         65002
${R3_ASN}         65003

# inter-router links: hub side / spoke side
${R2_LINK_HUB}    10.10.10.1
${R2_LINK_LOCAL}  10.10.10.2
${R3_LINK_HUB}    10.10.20.1
${R3_LINK_LOCAL}  10.10.20.2
# the hub interface facing each spoke, and the tunnel id it terminates on
${R2_HUB_INTF}    GigabitEthernet2
${R3_HUB_INTF}    GigabitEthernet4
${R2_HUB_TUNNEL}  Tunnel0
${R3_HUB_TUNNEL}  Tunnel1

${R2_TUNNEL_HUB}    192.168.100.1
${R2_TUNNEL_LOCAL}  192.168.100.2
${R3_TUNNEL_HUB}    192.168.101.1
${R3_TUNNEL_LOCAL}  192.168.101.2

${R1_LOOPBACK}    172.16.1.1
${R2_LOOPBACK}    172.16.2.1
${R3_LOOPBACK}    172.16.3.1
${R1_BGP_PREFIX}  10.20.1.1
${R2_BGP_PREFIX}  10.20.2.1
${R3_BGP_PREFIX}  10.20.3.1

${R1_LAN_IP}      192.168.10.1
${R2_LAN_IP}      192.168.20.1
${R3_LAN_IP}      192.168.30.1
${MGMT_VRF}       MGMT
${BANNER_FILE}    config/login-banner.txt
${MGMT_NAT_HOST}  10.0.2.2
${NMS_IP}         192.168.10.20
${NMS_OOB_IP}     192.168.99.10
${OOB_NET}        192.168.99.0
${OOB_PREFIX}     24
${R1_OOB_IP}      192.168.99.1
${R2_OOB_IP}      192.168.99.2
${R3_OOB_IP}      192.168.99.3
${R1_OOB_INTF}    GigabitEthernet5
${R2_OOB_INTF}    GigabitEthernet4
${R3_OOB_INTF}    GigabitEthernet4
${R1_LAN_NET}     192.168.10.0
${R2_LAN_NET}     192.168.20.0
${R3_LAN_NET}     192.168.30.0

${H1_PORT}        2231
${H2_PORT}        2232
${H3_PORT}        2233
# address blocks per host: .10-.19 static 1:1, .64-.93 from the pool
${STATIC_OCTET_FIRST}    10
${STATIC_OCTET_LAST}     19
${DYN_OCTET_FIRST}       64
${DYN_OCTET_LAST}        93
${POOL_OCTET_FIRST}      100
${POOL_OCTET_LAST}       129
&{LAN24}          H1=192.168.10    H2=192.168.20    H3=192.168.30
&{NAT24}          R1=10.30.1       R2=10.30.2       R3=10.30.3
${H1_NAT_IP}      10.30.1.10
${H2_NAT_IP}      10.30.2.10
${H3_NAT_IP}      10.30.3.10
${R1_NAT_NET}     10.30.1.0
${R2_NAT_NET}     10.30.2.0
${R3_NAT_NET}     10.30.3.0
${NAT_DOMAIN}     10.30.0.0
${H1_IP}          192.168.10.10
${H2_IP}          192.168.20.10
${H3_IP}          192.168.30.10
${HOST_USER}      cirros
${HOST_PASSWORD}  gocubsgo

# IOS-XE prompt. Anchored to a line start and the true end of buffer: a looser
# pattern matches the "->" in "show monitor capture" output as a prompt.
${PROMPT}         REGEXP:(?:^|[\\r\\n])[\\w][\\w.-]*(?:\\([\\w-]+\\))?[#>][ \\t]*\\Z
# busybox shell prompt on the cirros hosts
${HOST_PROMPT}    REGEXP:[$] $

*** Keywords ***
Open Router
    [Documentation]    Logs into one router under a connection alias and disables paging.
    [Arguments]    ${alias}    ${host}    ${port}
    Open Connection    ${host}    port=${port}    prompt=${PROMPT}    width=200    alias=${alias}
    Login    ${USERNAME}    ${PASSWORD}    delay=1s
    Write    terminal length 0
    Read Until Prompt
    Write    terminal width 200
    Read Until Prompt

Open All Routers
    Open Router    R1    ${R1_HOST}    ${R1_PORT}
    Open Router    R2    ${R1_HOST}    ${R2_PORT}
    Open Router    R3    ${R1_HOST}    ${R3_PORT}

Open Both Routers
    [Documentation]    Kept for suites that only need the hub and its first spoke.
    Open Router    R1    ${R1_HOST}    ${R1_PORT}
    Open Router    R2    ${R1_HOST}    ${R2_PORT}

Close All Routers
    Close All Connections

Run On
    [Documentation]    Runs one exec command on the named router, returns clean output.
    [Arguments]    ${alias}    ${command}
    Switch Connection    ${alias}
    Write    ${command}
    ${output}=    Read Until Prompt    strip_prompt=${TRUE}
    ${output}=    Remove String    ${output}    ${command}
    RETURN    ${output.strip()}

Configure On
    [Documentation]    Applies config lines to the named router.
    [Arguments]    ${alias}    @{lines}
    ${out}=    Run On    ${alias}    configure terminal
    FOR    ${line}    IN    @{lines}
        ${o}=    Run On    ${alias}    ${line}
        ${out}=    Catenate    SEPARATOR=\n    ${out}    ${o}
    END
    ${o}=    Run On    ${alias}    end
    RETURN    ${out}

Command Output Should Contain
    [Arguments]    ${alias}    ${command}    ${expected}
    ${output}=    Run On    ${alias}    ${command}
    Should Contain    ${output}    ${expected}
    RETURN    ${output}

Command Output Should Not Contain Error
    [Arguments]    ${output}
    Should Not Contain    ${output}    % Invalid input
    Should Not Contain    ${output}    % Incomplete command
    Should Not Contain    ${output}    % Ambiguous command

Ping Should Fully Succeed
    [Documentation]    Asserts a 100% ping. Extra args go straight to the IOS ping command.
    [Arguments]    ${alias}    ${target}    ${extra}=${EMPTY}
    ${out}=    Run On    ${alias}    ping ${target} ${extra}
    Should Contain    ${out}    Success rate is 100 percent
    RETURN    ${out}

Get IPsec Counters
    [Documentation]    Sums #pkts encaps/decaps across every IPsec SA on the router.
    [Arguments]    ${alias}
    ${out}=    Run On    ${alias}    show crypto ipsec sa
    @{enc}=    Get Regexp Matches    ${out}    [#]pkts encaps: (\\d+)    1
    @{dec}=    Get Regexp Matches    ${out}    [#]pkts decaps: (\\d+)    1
    ${encaps}=    Evaluate    sum(int(x) for x in $enc)
    ${decaps}=    Evaluate    sum(int(x) for x in $dec)
    RETURN    ${encaps}    ${decaps}

Start Link Capture
    [Documentation]    Embedded Packet Capture on an inter-router link. The hub has
    ...                one link per spoke, so the interface is a parameter.
    [Arguments]    ${alias}    ${capture}=ROBOTCAP    ${interface}=GigabitEthernet2
    Delete Capture    ${alias}    ${capture}
    Run On    ${alias}    monitor capture ${capture} interface ${interface} both
    Run On    ${alias}    monitor capture ${capture} match ipv4 any any
    Run On    ${alias}    monitor capture ${capture} buffer size 5
    Run On    ${alias}    monitor capture ${capture} start

Stop Link Capture
    [Arguments]    ${alias}    ${capture}=ROBOTCAP
    Run On    ${alias}    monitor capture ${capture} stop
    ${buf}=    Run On    ${alias}    show monitor capture ${capture} buffer brief
    Log    ${buf}
    Delete Capture    ${alias}    ${capture}
    RETURN    ${buf}

Delete Capture
    [Arguments]    ${alias}    ${capture}=ROBOTCAP
    Run On    ${alias}    no monitor capture ${capture}

Capture Link Traffic During
    [Documentation]    Captures the link across one command and returns the buffer summary.
    [Arguments]    ${alias}    ${traffic_command}    ${capture}=ROBOTCAP    ${interface}=GigabitEthernet2
    Start Link Capture    ${alias}    ${capture}    ${interface}
    Run On    ${alias}    ${traffic_command}
    Sleep    2s
    ${buf}=    Stop Link Capture    ${alias}    ${capture}
    RETURN    ${buf}

Capture Link Traffic For
    [Documentation]    Captures the link for a fixed window, for traffic nothing triggers
    ...                on demand -- routing keepalives, for instance.
    [Arguments]    ${alias}    ${duration}    ${capture}=ROBOTCAP    ${interface}=GigabitEthernet2
    Start Link Capture    ${alias}    ${capture}    ${interface}
    Sleep    ${duration}
    ${buf}=    Stop Link Capture    ${alias}    ${capture}
    RETURN    ${buf}

BGP Session Should Be Established
    [Arguments]    ${alias}    ${peer}    ${peer_asn}
    ${out}=    Run On    ${alias}    show bgp ipv4 unicast summary
    Should Match Regexp    ${out}    ${peer}\\s+4\\s+${peer_asn}(\\s+\\d+){5}\\s+\\S+\\s+\\d+
    ...    ${alias}: no established session with ${peer} (AS ${peer_asn})

BGP Session Should Not Be Established
    [Arguments]    ${alias}    ${peer}
    ${out}=    Run On    ${alias}    show bgp ipv4 unicast summary
    Should Not Match Regexp    ${out}    ${peer}(\\s+\\d+){6}\\s+\\S+\\s+\\d+\\s*$
    ...    ${alias}: session with ${peer} came up but should not have

ESP Counters Should Have Advanced
    [Documentation]    Re-reads both peers and asserts each counter grew by at least
    ...                ${expected}. Retried by the caller while the QFP stats settle.
    [Arguments]    ${r1e0}    ${r1d0}    ${r2e0}    ${r2d0}    ${expected}
    ${r1e}    ${r1d}=    Get IPsec Counters    R1
    ${r2e}    ${r2d}=    Get IPsec Counters    R2
    ${r1_enc}=    Evaluate    ${r1e} - ${r1e0}
    ${r1_dec}=    Evaluate    ${r1d} - ${r1d0}
    ${r2_enc}=    Evaluate    ${r2e} - ${r2e0}
    ${r2_dec}=    Evaluate    ${r2d} - ${r2d0}
    Log    R1 encaps +${r1_enc} decaps +${r1_dec} / R2 encaps +${r2_enc} decaps +${r2_dec}    console=${TRUE}
    Should Be True    ${r1_enc} >= ${expected}
    ...    R1 encrypted ${r1_enc} packets, expected at least ${expected}
    Should Be True    ${r1_dec} >= ${expected}
    ...    R1 decrypted ${r1_dec} reply packets, expected at least ${expected}
    Should Be True    ${r2_enc} >= ${expected}
    ...    R2 encrypted ${r2_enc} reply packets, expected at least ${expected}
    Should Be True    ${r2_dec} >= ${expected}
    ...    R2 decrypted ${r2_dec} packets, expected at least ${expected}

Open Host
    [Documentation]    Logs into one Linux host under a connection alias.
    [Arguments]    ${alias}    ${port}
    Open Connection    127.0.0.1    port=${port}    prompt=${HOST_PROMPT}    width=200    alias=${alias}
    Login    ${HOST_USER}    ${HOST_PASSWORD}    delay=3s

Open All Hosts
    Open Host    H1    ${H1_PORT}
    Open Host    H2    ${H2_PORT}
    Open Host    H3    ${H3_PORT}

Run On Host
    [Arguments]    ${alias}    ${command}
    Switch Connection    ${alias}
    Write    ${command}
    ${output}=    Read Until Prompt    strip_prompt=${TRUE}
    ${output}=    Remove String    ${output}    ${command}
    RETURN    ${output.strip()}

Host Ping Should Fully Succeed
    [Documentation]    Asserts a lossless ping from a Linux host.
    [Arguments]    ${alias}    ${target}    ${count}=10
    ${out}=    Run On Host    ${alias}    ping -c ${count} ${target}
    Should Contain    ${out}    0% packet loss
    ...    ping from ${alias} to ${target} lost packets: ${out}
    RETURN    ${out}

ESP Counters Should Have Advanced By
    [Documentation]    Same as ESP Counters Should Have Advanced but for an arbitrary
    ...                pair of routers, since the hub has a tunnel to each spoke.
    [Arguments]    ${a}    ${b}    ${ae0}    ${ad0}    ${be0}    ${bd0}    ${expected}
    ${ae}    ${ad}=    Get IPsec Counters    ${a}
    ${be}    ${bd}=    Get IPsec Counters    ${b}
    ${a_enc}=    Evaluate    ${ae} - ${ae0}
    ${a_dec}=    Evaluate    ${ad} - ${ad0}
    ${b_enc}=    Evaluate    ${be} - ${be0}
    ${b_dec}=    Evaluate    ${bd} - ${bd0}
    Log    ${a} encaps +${a_enc} decaps +${a_dec} / ${b} encaps +${b_enc} decaps +${b_dec}    console=${TRUE}
    Should Be True    ${a_enc} >= ${expected}    ${a} encrypted ${a_enc}, expected >= ${expected}
    Should Be True    ${a_dec} >= ${expected}    ${a} decrypted ${a_dec}, expected >= ${expected}
    Should Be True    ${b_enc} >= ${expected}    ${b} encrypted ${b_enc}, expected >= ${expected}
    Should Be True    ${b_dec} >= ${expected}    ${b} decrypted ${b_dec}, expected >= ${expected}

Ping From Source
    [Documentation]    Pings with an explicit source address, so which NAT rule the
    ...                router applies is under the test's control.
    [Arguments]    ${alias}    ${source}    ${target}    ${count}=5
    ${out}=    Run On Host    ${alias}    ping -c ${count} -I ${source} ${target}
    RETURN    ${out}

Ping From Source Should Fully Succeed
    [Arguments]    ${alias}    ${source}    ${target}    ${count}=5
    ${out}=    Ping From Source    ${alias}    ${source}    ${target}    ${count}
    Should Contain    ${out}    0% packet loss
    ...    ping from ${source} on ${alias} to ${target} lost packets
    RETURN    ${out}

Get NAT Inside Global For
    [Documentation]    Returns the outside-facing address the router is using for a
    ...                given inside address, read from the live translation table.
    [Arguments]    ${alias}    ${inside}
    ${out}=    Run On    ${alias}    show ip nat translations
    @{m}=    Get Regexp Matches    ${out}
    ...    (?m)^\\S+\\s+(\\d+\\.\\d+\\.\\d+\\.\\d+)(?::\\d+)?\\s+${inside}(?::\\d+)?\\s    1
    Should Not Be Empty    ${m}    ${alias} has no translation for ${inside}
    RETURN    ${m}[0]

Address Should Be In Pool
    [Arguments]    ${addr}    ${start}    ${end}
    ${a}=    Evaluate    tuple(int(x) for x in "${addr}".split("."))
    ${s}=    Evaluate    tuple(int(x) for x in "${start}".split("."))
    ${e}=    Evaluate    tuple(int(x) for x in "${end}".split("."))
    Should Be True    $s <= $a <= $e
    ...    ${addr} is outside the pool range ${start} - ${end}

Generate Traffic From Every Source Address
    [Documentation]    Fires one ping from all 40 of a host's addresses at once.
    ...                Sequentially this would take minutes; backgrounding them in
    ...                the host's shell makes it seconds.
    [Arguments]    ${alias}    ${target}
    ${lan}=    Set Variable    ${LAN24}[${alias}]
    Run On Host    ${alias}
    ...    for i in $(seq ${STATIC_OCTET_FIRST} ${STATIC_OCTET_LAST}) $(seq ${DYN_OCTET_FIRST} ${DYN_OCTET_LAST}); do ping -c 2 -W 2 -I ${lan}.$i ${target} >/dev/null 2>&1 & done; wait; echo SENT
    Sleep    8s    reason=let the QFP push translation state up to IOSd

Send Marked Syslog Message
    [Documentation]    Emits a message with a known marker from a router.
    ...
    ...                "send log" is interactive: it asks for the body, ends on
    ...                Ctrl-Z, then asks "Send message? [confirm]". Passing the text
    ...                on the command line silently produces nothing, which is what
    ...                made the first attempt at this look like a transport failure.
    [Arguments]    ${alias}    ${marker}    ${facility}=LAB    ${severity}=5    ${mnemonic}=PROBE
    Switch Connection    ${alias}
    ${ctrl_z}=    Evaluate    chr(26)
    Write Bare    send log facility ${facility} severity ${severity} mnemonics ${mnemonic}\n
    Sleep    1s
    Read
    Write Bare    ${marker}\n
    Sleep    1s
    Write Bare    ${ctrl_z}
    Sleep    1s
    Read
    Write Bare    \n
    Sleep    1s
    Read Until Prompt
