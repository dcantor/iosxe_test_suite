*** Settings ***
Documentation     Path MTU across the IPsec tunnels.
...
...               Encryption costs header room: ESP-AES-256 with SHA256 leaves 1438
...               bytes of a 1500-byte path. That boundary is where real IPsec
...               deployments fail, and they fail quietly -- small packets work, so
...               ping and SSH look fine while anything bulk stalls.
...
...               So this asserts the boundary from both sides (a packet exactly at
...               the limit crosses, one byte more does not), that oversize traffic
...               still gets through when fragmentation is allowed -- proving it is
...               an MTU limit and not a blackhole -- and that the limit propagates
...               all the way to an end host, which is what stops a real client
...               retransmitting into a black hole forever.
Resource          ../resources/c8000v.resource
Library           String
Suite Setup       Run Keywords    Open All Routers    AND    Open All Hosts
Suite Teardown    Close All Connections

*** Variables ***
${PHYSICAL_MTU}    1500
${TUNNEL_MTU}      1438
# a router "size" is the whole IP packet; a Linux -s is payload, so 28 bytes less
${HOST_PAYLOAD}    1410
${HOST_OVERSIZE}   1472

*** Test Cases ***
Every Tunnel Reports The Expected Transport MTU
    [Documentation]    The tunnel MTU must be below the physical one by the ESP
    ...                overhead. Equal would mean encryption costs nothing, which
    ...                would mean it is not happening.
    FOR    ${r}    IN    @{ROUTERS}
        @{tunnels}=    Tunnels On    ${r}
        FOR    ${t}    IN    @{tunnels}
            ${out}=    Run On    ${r}    show interfaces ${t} | include Tunnel transport MTU
            Should Contain    ${out}    ${TUNNEL_MTU} bytes
            ...    ${r} ${t} does not report a transport MTU of ${TUNNEL_MTU}
            ${ip}=    Run On    ${r}    show ip interface ${t} | include MTU
            Should Contain    ${ip}    MTU is ${TUNNEL_MTU} bytes
        END
    END
    Should Be True    ${TUNNEL_MTU} < ${PHYSICAL_MTU}
    ...    the tunnel MTU is not below the physical MTU, so ESP appears to cost nothing

The Overhead Is What ESP-AES-256 With SHA256 Costs
    [Documentation]    Records the number rather than assuming it: 62 bytes of ESP
    ...                header, IV, padding and ICV. If the transform set changes,
    ...                this is the test that should fail first.
    ${overhead}=    Evaluate    ${PHYSICAL_MTU} - ${TUNNEL_MTU}
    Log    ESP overhead is ${overhead} bytes    console=${TRUE}
    Should Be Equal As Integers    ${overhead}    62

A Packet Exactly At The Tunnel MTU Crosses With DF Set
    [Documentation]    The permissive half of the boundary. Sourced from Loopback1
    ...                so the traffic is inside the protected selector.
    ${out}=    Run On    R2    ping ${R3_BGP_PREFIX} source Loopback1 size ${TUNNEL_MTU} df-bit repeat 5
    Should Contain    ${out}    Success rate is 100 percent
    ...    a packet of exactly the tunnel MTU (${TUNNEL_MTU}) did not cross

One Byte Over The Tunnel MTU Does Not Cross With DF Set
    [Documentation]    The restrictive half. Without this the test above would pass
    ...                just as well against a tunnel with no MTU limit at all.
    ${over}=    Evaluate    ${TUNNEL_MTU} + 1
    ${out}=    Run On    R2    ping ${R3_BGP_PREFIX} source Loopback1 size ${over} df-bit repeat 5
    Should Contain    ${out}    Success rate is 0 percent
    ...    a packet one byte over the tunnel MTU crossed with DF set

Oversize Traffic Still Crosses When Fragmentation Is Allowed
    [Documentation]    Distinguishes an MTU limit from a blackhole: the same sizes
    ...                that fail with DF set must succeed without it.
    FOR    ${size}    IN    ${PHYSICAL_MTU}    2000
        ${out}=    Run On    R2    ping ${R3_BGP_PREFIX} source Loopback1 size ${size} repeat 5
        Should Contain    ${out}    Success rate is 100 percent
        ...    a ${size}-byte packet failed even with fragmentation allowed
    END

Hosts Pass Sub-MTU Traffic With DF Set
    [Documentation]    End to end across two encrypt/decrypt hops, from machines
    ...                that know nothing about the tunnel.
    ${out}=    Run On Host    H2    ping -c 5 -M do -s ${HOST_PAYLOAD} ${H3_IP}
    Should Contain    ${out}    , 0% packet loss
    ...    a host could not pass ${HOST_PAYLOAD} bytes with DF set

An End Host Learns The Tunnel Path MTU
    [Documentation]    The test that matters most in practice. The host is two hops
    ...                and an encryption boundary away from the constraint, yet it
    ...                must end up knowing the real limit -- otherwise a client
    ...                retransmits into a black hole instead of backing off. The
    ...                host reporting the exact tunnel MTU is proof that path MTU
    ...                discovery survived the tunnel.
    ${out}=    Run On Host    H2    ping -c 2 -M do -s ${HOST_OVERSIZE} ${H3_IP}
    Should Contain    ${out}    mtu=${TUNNEL_MTU}
    ...    the host did not learn the ${TUNNEL_MTU}-byte path MTU: ${out}

Hosts Pass Oversize Traffic Without DF Set
    [Documentation]    The counterpart: the same payload that was refused with DF
    ...                set gets through when it may be fragmented.
    ${out}=    Run On Host    H2    ping -c 5 -s ${HOST_OVERSIZE} ${H3_IP}
    Should Contain    ${out}    , 0% packet loss
    ...    oversize host traffic failed even with fragmentation allowed

*** Keywords ***
Tunnels On
    [Documentation]    The hub holds a tunnel per spoke; a spoke holds one.
    [Arguments]    ${alias}
    ${out}=    Run On    ${alias}    show ip interface brief | include ^Tunnel
    @{tunnels}=    Get Regexp Matches    ${out}    (?m)^(Tunnel\\d+)    1
    Should Not Be Empty    ${tunnels}    ${alias} has no tunnel interfaces
    RETURN    ${tunnels}
