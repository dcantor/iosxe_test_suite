*** Settings ***
Documentation     Port of tests/04_ipsec.robot to pyATS: Unicon for the connection
...               layer, Genie parsers instead of hand-written regexes. The same
...               assertions, expressed against structured data.
...
...               Runs alongside the original for comparison. What deliberately does
...               NOT move: the packet-capture assertions, since Genie parses capture
...               configuration rather than buffer contents -- that is the honest
...               boundary of this approach.
Library           ${CURDIR}/../tools/genie_keywords.py
Library           Collections
Suite Setup       Establish Tunnels
Suite Teardown    Disconnect Lab Devices

*** Variables ***
${TESTBED}        ${CURDIR}/../testbed/lab.yaml
${HUB}            c8000v-r1
${SPOKE1}         c8000v-r2
${SPOKE2}         c8000v-r3
${R2_TUNNEL}      Tunnel0
${R3_TUNNEL}      Tunnel1
${PING_COUNT}     20

*** Test Cases ***
Tunnel Interfaces Are Up On Hub And Spokes
    [Documentation]    Status and protocol are fields. No regex, and nothing that
    ...                depends on the Method column, which broke the original twice
    ...                when config arrived from TFTP and then from NVRAM.
    FOR    ${t}    IN    ${R2_TUNNEL}    ${R3_TUNNEL}
        ${s}=    Tunnel State    ${HUB}    ${t}
        Should Be Equal    ${s}[status]      up
        Should Be Equal    ${s}[protocol]    up
    END
    FOR    ${d}    IN    ${SPOKE1}    ${SPOKE2}
        ${s}=    Tunnel State    ${d}    Tunnel0
        Should Be Equal    ${s}[status]      up
        Should Be Equal    ${s}[protocol]    up
    END

Hub Holds An IPsec Security Association Per Spoke
    ${tunnels}=    Ipsec Tunnels    ${HUB}
    Should Contain    ${tunnels}    ${R2_TUNNEL}
    Should Contain    ${tunnels}    ${R3_TUNNEL}
    FOR    ${d}    IN    ${SPOKE1}    ${SPOKE2}
        ${t}=    Ipsec Tunnels    ${d}
        Length Should Be    ${t}    1    ${d} should hold exactly one tunnel
    END

Negotiated Transform Matches The Configured Policy
    [Documentation]    Guards against silently falling back to a weaker cipher.
    FOR    ${d}    IN    ${HUB}    ${SPOKE1}    ${SPOKE2}
        ${transforms}=    Outbound Transforms    ${d}
        Should Not Be Empty    ${transforms}    ${d} reports no outbound ESP transform
        FOR    ${t}    IN    @{transforms}
            Should Contain    ${t}    esp-256-aes
            Should Contain    ${t}    esp-sha256-hmac
        END
    END

Peer Loopbacks Are Routed Through The Tunnels
    ${r2}=    Route Interfaces    ${HUB}    172.16.2.1/32
    ${r3}=    Route Interfaces    ${HUB}    172.16.3.1/32
    Should Contain    ${r2}    ${R2_TUNNEL}
    Should Contain    ${r3}    ${R3_TUNNEL}
    FOR    ${d}    IN    ${SPOKE1}    ${SPOKE2}
        ${back}=    Route Interfaces    ${d}    172.16.1.1/32
        Should Contain    ${back}    Tunnel0
    END

Loopback Traffic To Each Spoke Is Encrypted And Decrypted
    [Documentation]    The core assertion. Counters arrive as integers under
    ...                ident.<n>.pkts_encaps rather than being summed out of text,
    ...                which is where the original suite had two separate bugs.
    ${h0}    ${d0}=    Esp Totals    ${HUB}
    ${s0}    ${sd0}=    Esp Totals    ${SPOKE1}
    Device Execute    ${HUB}    ping 172.16.2.1 source Loopback0 repeat ${PING_COUNT}
    Wait Until Keyword Succeeds    12x    5s    Esp Counters Should Have Advanced
    ...    ${HUB}    ${SPOKE1}    ${h0}    ${sd0}    ${PING_COUNT}

*** Keywords ***
Establish Tunnels
    Use Lab Testbed    ${TESTBED}
    Connect Lab Devices    ${HUB}    ${SPOKE1}    ${SPOKE2}
    Device Execute    ${HUB}    ping 172.16.2.1 source Loopback0 repeat 3
    Device Execute    ${HUB}    ping 172.16.3.1 source Loopback0 repeat 3

Esp Counters Should Have Advanced
    [Arguments]    ${a}    ${b}    ${a_enc0}    ${b_dec0}    ${expected}
    ${a_enc}    ${a_dec}=    Esp Totals    ${a}
    ${b_enc}    ${b_dec}=    Esp Totals    ${b}
    ${enc}=    Evaluate    ${a_enc} - ${a_enc0}
    ${dec}=    Evaluate    ${b_dec} - ${b_dec0}
    Log    ${a} encrypted +${enc}, ${b} decrypted +${dec}    console=${TRUE}
    Should Be True    ${enc} >= ${expected}    ${a} encrypted only ${enc}, expected ${expected}
    Should Be True    ${dec} >= ${expected}    ${b} decrypted only ${dec}, expected ${expected}
