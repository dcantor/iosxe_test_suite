*** Settings ***
Documentation     Validates that IPsec is not merely configured but actually
...               encrypting, on both hub-to-spoke tunnels.
Resource          ../resources/c8000v.resource
Suite Setup       Establish Tunnels
Suite Teardown    Close All Connections

*** Variables ***
${PING_COUNT}     20
# The C8000V dataplane (QFP) pushes crypto counters up to IOSd every few seconds,
# so ESP counters lag the traffic that caused them. Positive assertions poll; the
# negative assertion waits out this window before claiming nothing moved.
${STATS_SETTLE}   15s
${LINK_PINGS}     10

*** Test Cases ***
Tunnel Interfaces Are Up On Hub And Spokes
    ${out}=    Run On    R1    show ip interface brief ${R2_HUB_TUNNEL}
    Should Match Regexp    ${out}    ${R2_HUB_TUNNEL}\\s+${R2_TUNNEL_HUB}\\s+YES\\s+\\S+\\s+up\\s+up
    ${out}=    Run On    R1    show ip interface brief ${R3_HUB_TUNNEL}
    Should Match Regexp    ${out}    ${R3_HUB_TUNNEL}\\s+${R3_TUNNEL_HUB}\\s+YES\\s+\\S+\\s+up\\s+up
    ${out}=    Run On    R2    show ip interface brief Tunnel0
    Should Match Regexp    ${out}    Tunnel0\\s+${R2_TUNNEL_LOCAL}\\s+YES\\s+\\S+\\s+up\\s+up
    ${out}=    Run On    R3    show ip interface brief Tunnel0
    Should Match Regexp    ${out}    Tunnel0\\s+${R3_TUNNEL_LOCAL}\\s+YES\\s+\\S+\\s+up\\s+up

Every Tunnel Is Bound To An IPsec Profile
    FOR    ${alias}    ${tun}    IN    R1    ${R2_HUB_TUNNEL}    R1    ${R3_HUB_TUNNEL}    R2    Tunnel0    R3    Tunnel0
        ${out}=    Run On    ${alias}    show running-config interface ${tun}
        Should Contain    ${out}    tunnel mode ipsec ipv4
        Should Contain    ${out}    tunnel protection ipsec profile LAB-IPSEC
    END

Hub Holds An IKEv2 Security Association With Each Spoke
    ${out}=    Run On    R1    show crypto ikev2 sa
    Should Contain    ${out}    ${R2_LINK_LOCAL}
    Should Contain    ${out}    ${R3_LINK_LOCAL}
    ${ready}=    Get Regexp Matches    ${out}    READY
    Length Should Be    ${ready}    2    hub should hold one READY SA per spoke

Each Spoke Holds An IKEv2 Security Association With The Hub
    ${out}=    Run On    R2    show crypto ikev2 sa
    Should Contain    ${out}    READY
    Should Contain    ${out}    ${R2_LINK_HUB}
    ${out}=    Run On    R3    show crypto ikev2 sa
    Should Contain    ${out}    READY
    Should Contain    ${out}    ${R3_LINK_HUB}

IPsec Security Associations Are Installed In Both Directions
    FOR    ${alias}    IN    @{ROUTERS}
        ${out}=    Run On    ${alias}    show crypto ipsec sa
        Should Contain    ${out}    inbound esp sas:
        Should Contain    ${out}    outbound esp sas:
        Should Match Regexp    ${out}    spi: 0x[0-9A-Fa-f]+
    END

Negotiated Transform Matches The Configured Policy
    [Documentation]    Guards against silently falling back to a weaker or null cipher.
    FOR    ${alias}    IN    @{ROUTERS}
        ${out}=    Run On    ${alias}    show crypto ipsec sa
        Should Contain    ${out}    esp-256-aes
        Should Contain    ${out}    esp-sha256-hmac
    END

Peer Loopbacks Are Routed Through The Tunnels
    ${out}=    Run On    R1    show ip route ${R2_LOOPBACK}
    Should Contain    ${out}    ${R2_HUB_TUNNEL}
    ${out}=    Run On    R1    show ip route ${R3_LOOPBACK}
    Should Contain    ${out}    ${R3_HUB_TUNNEL}
    ${out}=    Run On    R2    show ip route ${R1_LOOPBACK}
    Should Contain    ${out}    Tunnel0
    ${out}=    Run On    R3    show ip route ${R1_LOOPBACK}
    Should Contain    ${out}    Tunnel0

Loopback Traffic To Each Spoke Is Encrypted And Decrypted
    [Documentation]    The core assertion, run once per tunnel: send known traffic and
    ...                prove the ESP counters moved by that amount on both peers.
    ${h}    ${hd}=    Get IPsec Counters    R1
    ${s}    ${sd}=    Get IPsec Counters    R2
    Ping Should Fully Succeed    R1    ${R2_LOOPBACK}    source Loopback0 repeat ${PING_COUNT}
    Wait Until Keyword Succeeds    12x    5s    ESP Counters Should Have Advanced
    ...    ${h}    ${hd}    ${s}    ${sd}    ${PING_COUNT}

    ${h}    ${hd}=    Get IPsec Counters    R1
    ${s}    ${sd}=    Get IPsec Counters    R3
    Ping Should Fully Succeed    R1    ${R3_LOOPBACK}    source Loopback0 repeat ${PING_COUNT}
    Wait Until Keyword Succeeds    12x    5s    ESP Counters Should Have Advanced By
    ...    R1    R3    ${h}    ${hd}    ${s}    ${sd}    ${PING_COUNT}

Traffic Outside The Protected Selector Is Not Encrypted
    [Documentation]    Negative control, self-calibrating. A delta of zero is not
    ...                assertable: BGP peers across the tunnels and BFD now runs on
    ...                them at 500ms x 2 tunnels, so the counters tick continuously
    ...                whatever the data plane is doing -- that background alone is
    ...                far larger than the ping count, which is what used to be the
    ...                threshold. So measure it: time the ping window, then measure
    ...                an idle window of the same length, and require the ping to
    ...                have added no more than the control plane did by itself. If
    ...                link-local echoes were being encrypted the difference could
    ...                not stay under the number of pings sent.
    ${enc_before}    ${dec_before}=    Get IPsec Counters    R1
    ${start}=    Evaluate    __import__("time").time()
    Ping Should Fully Succeed    R1    ${R2_LINK_LOCAL}    repeat ${LINK_PINGS}
    Sleep    ${STATS_SETTLE}    reason=let the QFP counters sync before measuring
    ${enc_after}    ${dec_after}=    Get IPsec Counters    R1
    ${window}=    Evaluate    __import__("time").time() - ${start}
    ${delta}=    Evaluate    ${enc_after} - ${enc_before}

    ${idle_before}    ${d}=    Get IPsec Counters    R1
    Sleep    ${window}s    reason=an idle window of the same length, to measure the background
    ${idle_after}    ${d}=    Get IPsec Counters    R1
    ${background}=    Evaluate    ${idle_after} - ${idle_before}

    ${attributable}=    Evaluate    ${delta} - ${background}
    ${summary}=    Catenate    ping window +${delta} ESP encaps, idle window of the
    ...    same length +${background} -- ${attributable} attributable to the pings
    Log    ${summary}    console=${TRUE}
    Should Be True    ${attributable} < ${LINK_PINGS}
    ...    link-local traffic added ${attributable} ESP encaps above the control-plane background for ${LINK_PINGS} pings; the crypto selector is too broad

Anti-Replay And Lifetime Protections Are Present
    FOR    ${alias}    IN    @{ROUTERS}
        ${out}=    Run On    ${alias}    show crypto ipsec sa
        Should Match Regexp    ${out}    replay detection support:\\s*Y
        Should Match Regexp    ${out}    sa timing: remaining key lifetime
    END

*** Keywords ***
Establish Tunnels
    [Documentation]    IKEv2 negotiates on the first interesting packet, so prime both
    ...                tunnels before asserting on their state.
    Open All Routers
    Run On    R1    ping ${R2_LOOPBACK} source Loopback0 repeat 5
    Run On    R1    ping ${R3_LOOPBACK} source Loopback0 repeat 5
    Wait Until Keyword Succeeds    6x    5s    IKEv2 SA Should Be Ready    R2
    Wait Until Keyword Succeeds    6x    5s    IKEv2 SA Should Be Ready    R3

IKEv2 SA Should Be Ready
    [Arguments]    ${alias}
    ${out}=    Run On    ${alias}    show crypto ikev2 sa
    Should Contain    ${out}    READY
