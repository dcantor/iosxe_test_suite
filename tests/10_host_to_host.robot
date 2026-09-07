*** Settings ***
Documentation     Three Linux hosts, one behind each router, reaching each other over
...               the hub-and-spoke IPsec fabric. Spoke-to-spoke traffic (h2 <-> h3)
...               is decrypted and re-encrypted at the hub, so it is protected on both
...               legs. None of the hosts runs any crypto.
Resource          ../resources/c8000v.resource
Suite Setup       Run Keywords    Open All Routers    AND    Open All Hosts
...                               AND    Wait For LAN Routes    AND    Warm Up Host Paths
Suite Teardown    Run Keywords    Run Keyword And Ignore Error    Delete Capture    R1    HOSTCAP
...                               AND    Close All Connections

*** Variables ***
${PING_COUNT}     20
&{HOST_IP}        H1=${H1_IP}    H2=${H2_IP}    H3=${H3_IP}
&{HOST_GW}        H1=${R1_LAN_IP}    H2=${R2_LAN_IP}    H3=${R3_LAN_IP}

*** Test Cases ***
Every Host Holds Its LAN Address
    FOR    ${h}    IN    @{HOSTS}
        ${out}=    Run On Host    ${h}    ip addr show eth1
        Should Contain    ${out}    ${HOST_IP}[${h}]
    END

Every Host Routes The Other Two LANs Via Its Own Router
    FOR    ${h}    IN    @{HOSTS}
        ${out}=    Run On Host    ${h}    ip route
        FOR    ${o}    IN    @{HOSTS}
            IF    '${o}' != '${h}'
                ${net}=    Evaluate    "${HOST_IP}[${o}]".rsplit(".",1)[0] + ".0"
                Should Match Regexp    ${out}    ${net}/24 via ${HOST_GW}[${h}]
            END
        END
    END

Every Host Can Reach Its Default Gateway
    [Documentation]    Isolates the host-to-router leg so a failure further along is
    ...                not misread as a broken LAN.
    FOR    ${h}    IN    @{HOSTS}
        Host Ping Should Fully Succeed    ${h}    ${HOST_GW}[${h}]    5
    END

Every Host Can Reach Every Other Host
    [Documentation]    The full mesh, including h2 <-> h3 which never touches a direct
    ...                link and can only work if the hub re-advertises between spokes.
    FOR    ${src}    IN    @{HOSTS}
        FOR    ${dst}    IN    @{HOSTS}
            IF    '${src}' != '${dst}'
                Host Ping Should Fully Succeed    ${src}    ${HOST_IP}[${dst}]    5
            END
        END
    END

Spoke To Spoke Traffic Is Routed Through The Hub
    [Documentation]    R2 must reach R3's LAN via the hub's tunnel address, not by any
    ...                direct path -- there is no spoke-to-spoke link.
    ${out}=    Run On    R2    show ip route ${R3_LAN_NET}
    Should Contain    ${out}    Known via "bgp ${R2_ASN}"
    Should Contain    ${out}    ${R2_TUNNEL_HUB}
    ${out}=    Run On    R2    show ip cef ${H3_IP}
    Should Contain    ${out}    Tunnel0
    ${out}=    Run On    R3    show ip cef ${H2_IP}
    Should Contain    ${out}    Tunnel0

Hub Reaches Both Spoke LANs On Separate Tunnels
    ${out}=    Run On    R1    show ip cef ${H2_IP}
    Should Contain    ${out}    ${R2_HUB_TUNNEL}
    ${out}=    Run On    R1    show ip cef ${H3_IP}
    Should Contain    ${out}    ${R3_HUB_TUNNEL}

Host Traffic Is Encrypted In Transit
    [Documentation]    No host runs crypto: the routers encrypt for them, so the ESP
    ...                counters must move by the traffic the hosts generated.
    ${r1e}    ${r1d}=    Get IPsec Counters    R1
    ${r2e}    ${r2d}=    Get IPsec Counters    R2
    Host Ping Should Fully Succeed    H1    ${H2_IP}    ${PING_COUNT}
    Wait Until Keyword Succeeds    12x    5s    ESP Counters Should Have Advanced
    ...    ${r1e}    ${r1d}    ${r2e}    ${r2d}    ${PING_COUNT}

Host Addresses Never Appear In Cleartext On The Spoke Link
    [Documentation]    Capture the R1<->R2 link while the hosts talk: only ESP between
    ...                the link addresses should be visible.
    Start Link Capture    R1    HOSTCAP    ${R2_HUB_INTF}
    Host Ping Should Fully Succeed    H1    ${H2_IP}    10
    ${buf}=    Stop Link Capture    R1    HOSTCAP
    Should Contain    ${buf}    ESP
    Should Not Contain    ${buf}    ${H1_IP}
    Should Not Contain    ${buf}    ${H2_IP}
    Should Not Contain    ${buf}    ICMP

Spoke To Spoke Traffic Is Encrypted On Both Legs
    [Documentation]    h2 -> h3 crosses two tunnels. Capture the second leg (the hub's
    ...                link to R3) and show the spoke hosts are invisible there too.
    Start Link Capture    R1    HOSTCAP    ${R3_HUB_INTF}
    Host Ping Should Fully Succeed    H2    ${H3_IP}    10
    ${buf}=    Stop Link Capture    R1    HOSTCAP
    Should Contain    ${buf}    ESP
    Should Not Contain    ${buf}    ${H2_IP}
    Should Not Contain    ${buf}    ${H3_IP}
    Should Not Contain    ${buf}    ICMP

*** Keywords ***
Wait For LAN Routes
    [Documentation]    Earlier suites tear down tunnels and churn BGP, withdrawing
    ...                these prefixes. Wait for reconvergence rather than assume it.
    FOR    ${r}    IN    @{ROUTERS}
        Wait Until Keyword Succeeds    24x    5s    Routing Table Should Hold All LANs    ${r}
    END

Routing Table Should Hold All LANs
    [Arguments]    ${alias}
    ${rt}=    Run On    ${alias}    show ip route
    Should Contain    ${rt}    ${R1_LAN_NET}
    Should Contain    ${rt}    ${R2_LAN_NET}
    Should Contain    ${rt}    ${R3_LAN_NET}

Warm Up Host Paths
    [Documentation]    The first packet across a freshly resolved path is routinely
    ...                dropped while ARP and the tunnel adjacency settle.
    FOR    ${src}    IN    @{HOSTS}
        FOR    ${dst}    IN    @{HOSTS}
            IF    '${src}' != '${dst}'
                Run On Host    ${src}    ping -c 3 ${HOST_IP}[${dst}]
            END
        END
    END
