*** Settings ***
Documentation     Source NAT: each router rewrites its own host's address into a
...               per-site /24 of a shared NAT domain, so a host reaches its peers
...               at their mapped addresses and is seen by them at its own.
...
...               Translation is scoped by a route-map to traffic aimed at the NAT
...               domain. That is deliberate: without it both ends would rewrite
...               their source on replies too, and a ping would come back from an
...               address the sender never contacted. The untranslated LAN path
...               therefore still works, and a test here holds that line.
Resource          ../resources/c8000v.resource
Suite Setup       Run Keywords    Open All Routers    AND    Open All Hosts
...                               AND    Wait For NAT Routes    AND    Warm Up NAT Paths
Suite Teardown    Close All Connections

*** Variables ***
${PING_COUNT}     20
&{HOST_IP}        H1=${H1_IP}        H2=${H2_IP}        H3=${H3_IP}
&{HOST_NAT}       H1=${H1_NAT_IP}    H2=${H2_NAT_IP}    H3=${H3_NAT_IP}
&{HOST_RTR}       H1=R1              H2=R2              H3=R3

*** Test Cases ***
Every Router Has A Static Source NAT Mapping For Its Host
    FOR    ${h}    IN    @{HOSTS}
        ${r}=    Set Variable    ${HOST_RTR}[${h}]
        ${cfg}=    Run On    ${r}    show running-config | include ip nat inside source
        Should Contain    ${cfg}    ${HOST_IP}[${h}]
        Should Contain    ${cfg}    ${HOST_NAT}[${h}]
        Should Contain    ${cfg}    route-map NAT-TO-DOMAIN
    END

NAT Inside And Outside Interfaces Are Marked Correctly
    [Documentation]    The LAN faces inside, the tunnels face outside. Getting this
    ...                backwards silently disables translation rather than erroring.
    FOR    ${r}    IN    @{ROUTERS}
        ${lan}=    Run On    ${r}    show running-config interface GigabitEthernet3
        Should Contain    ${lan}    ip nat inside
        ${tun}=    Run On    ${r}    show running-config interface Tunnel0
        Should Contain    ${tun}    ip nat outside
    END
    ${tun}=    Run On    R1    show running-config interface ${R3_HUB_TUNNEL}
    Should Contain    ${tun}    ip nat outside

Mapped Prefixes Are Advertised Across The Fabric
    [Documentation]    Return traffic can only find its way home if each site's NAT
    ...                range is reachable, so the mapped prefixes ride BGP like the
    ...                real ones.
    ${out}=    Run On    R2    show ip route ${R1_NAT_NET}
    Should Contain    ${out}    Known via "bgp ${R2_ASN}"
    ${out}=    Run On    R2    show ip route ${R3_NAT_NET}
    Should Contain    ${out}    Known via "bgp ${R2_ASN}"
    ${out}=    Run On    R3    show ip route ${R1_NAT_NET}
    Should Contain    ${out}    Known via "bgp ${R3_ASN}"

Every Host Reaches Every Other Host At Its Mapped Address
    FOR    ${src}    IN    @{HOSTS}
        FOR    ${dst}    IN    @{HOSTS}
            IF    '${src}' != '${dst}'
                Host Ping Should Fully Succeed    ${src}    ${HOST_NAT}[${dst}]    5
            END
        END
    END

Translations Show The Host Rewritten To Its Mapped Address
    [Documentation]    The inside-local / inside-global pair is the direct evidence
    ...                that the source address was rewritten.
    Host Ping Should Fully Succeed    H1    ${H2_NAT_IP}    5
    ${out}=    Run On    R1    show ip nat translations
    Should Match Regexp    ${out}    icmp\\s+${H1_NAT_IP}:\\d+\\s+${H1_IP}:\\d+\\s+${H2_NAT_IP}

The Far Host Sees The Mapped Source Not The Real One
    [Documentation]    On the receiving router the peer appears as the sender's
    ...                mapped address, which is the whole point of source NAT.
    Host Ping Should Fully Succeed    H1    ${H2_NAT_IP}    5
    ${out}=    Run On    R2    show ip nat translations
    Should Contain    ${out}    ${H1_NAT_IP}
    Should Not Contain    ${out}    ${H1_IP}

Spoke To Spoke NAT Works Through The Hub
    [Documentation]    h2 -> h3 by mapped address crosses two tunnels and two
    ...                translations, with no direct spoke-to-spoke path.
    Host Ping Should Fully Succeed    H2    ${H3_NAT_IP}    5
    ${out}=    Run On    R2    show ip nat translations
    Should Contain    ${out}    ${H3_NAT_IP}
    ${out}=    Run On    R3    show ip nat translations
    Should Contain    ${out}    ${H2_NAT_IP}

NATted Traffic Is Still Encrypted
    [Documentation]    Translation happens before encryption, so NATted traffic must
    ...                still raise the ESP counters.
    ${r1e}    ${r1d}=    Get IPsec Counters    R1
    ${r2e}    ${r2d}=    Get IPsec Counters    R2
    Host Ping Should Fully Succeed    H1    ${H2_NAT_IP}    ${PING_COUNT}
    Wait Until Keyword Succeeds    12x    5s    ESP Counters Should Have Advanced
    ...    ${r1e}    ${r1d}    ${r2e}    ${r2d}    ${PING_COUNT}

Mapped Addresses Never Appear In Cleartext On The Link
    ${buf}=    Capture Link Traffic During    R1
    ...    ping ${R2_LINK_LOCAL} repeat 2    NATCAP    ${R2_HUB_INTF}
    Start Link Capture    R1    NATCAP    ${R2_HUB_INTF}
    Host Ping Should Fully Succeed    H1    ${H2_NAT_IP}    10
    ${buf}=    Stop Link Capture    R1    NATCAP
    Should Contain    ${buf}    ESP
    Should Not Contain    ${buf}    ${H1_NAT_IP}
    Should Not Contain    ${buf}    ${H2_NAT_IP}
    Should Not Contain    ${buf}    ${H1_IP}

The Untranslated LAN Path Still Works
    [Documentation]    Guards the route-map scoping. If translation ever widened to
    ...                all traffic, replies on this path would arrive from a mapped
    ...                address the sender never contacted, and this would fail.
    Host Ping Should Fully Succeed    H1    ${H2_IP}    5
    Host Ping Should Fully Succeed    H2    ${H3_IP}    5

*** Keywords ***
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

Warm Up NAT Paths
    FOR    ${src}    IN    @{HOSTS}
        FOR    ${dst}    IN    @{HOSTS}
            IF    '${src}' != '${dst}'
                Run On Host    ${src}    ping -c 3 ${HOST_NAT}[${dst}]
            END
        END
    END
