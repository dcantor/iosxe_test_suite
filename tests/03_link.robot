*** Settings ***
Documentation     The two virtual ethernet links from the hub to each spoke. These are
...               the unencrypted transport the IPsec tunnels ride on.
Resource          ../resources/c8000v.resource
Suite Setup       Open All Routers
Suite Teardown    Close All Connections

*** Test Cases ***
Hub Link Interfaces Are Up Toward Both Spokes
    ${out}=    Run On    R1    show ip interface brief ${R2_HUB_INTF}
    Should Match Regexp    ${out}    ${R2_HUB_INTF}\\s+${R2_LINK_HUB}\\s+YES\\s+\\S+\\s+up\\s+up
    ${out}=    Run On    R1    show ip interface brief ${R3_HUB_INTF}
    Should Match Regexp    ${out}    ${R3_HUB_INTF}\\s+${R3_LINK_HUB}\\s+YES\\s+\\S+\\s+up\\s+up

Spoke Link Interfaces Are Up Toward The Hub
    ${out}=    Run On    R2    show ip interface brief GigabitEthernet2
    Should Match Regexp    ${out}    GigabitEthernet2\\s+${R2_LINK_LOCAL}\\s+YES\\s+\\S+\\s+up\\s+up
    ${out}=    Run On    R3    show ip interface brief GigabitEthernet2
    Should Match Regexp    ${out}    GigabitEthernet2\\s+${R3_LINK_LOCAL}\\s+YES\\s+\\S+\\s+up\\s+up

Hub And Spokes Can Reach Each Other Across The Links
    Ping Should Fully Succeed    R1    ${R2_LINK_LOCAL}    repeat 5
    Ping Should Fully Succeed    R1    ${R3_LINK_LOCAL}    repeat 5
    Ping Should Fully Succeed    R2    ${R2_LINK_HUB}      repeat 5
    Ping Should Fully Succeed    R3    ${R3_LINK_HUB}      repeat 5

Spokes Have No Direct Link To Each Other
    [Documentation]    Confirms this really is hub-and-spoke: neither spoke has any
    ...                route to the other's transport subnet, so all spoke-to-spoke
    ...                traffic must traverse the hub.
    ${out}=    Run On    R2    show ip route ${R3_LINK_HUB}
    Should Contain    ${out}    % Subnet not in table
    ${out}=    Run On    R3    show ip route ${R2_LINK_HUB}
    Should Contain    ${out}    % Subnet not in table

Each Router Learns Its Peer ARP Entry On The Link
    ${out}=    Run On    R1    show ip arp ${R2_LINK_LOCAL}
    Should Contain    ${out}    ${R2_HUB_INTF}
    ${out}=    Run On    R1    show ip arp ${R3_LINK_LOCAL}
    Should Contain    ${out}    ${R3_HUB_INTF}

Protected Endpoints Exist On Every Router
    FOR    ${alias}    ${lo}    IN    R1    ${R1_LOOPBACK}    R2    ${R2_LOOPBACK}    R3    ${R3_LOOPBACK}
        ${out}=    Run On    ${alias}    show ip interface brief Loopback0
        Should Match Regexp    ${out}    Loopback0\\s+${lo}\\s+YES\\s+\\S+\\s+up\\s+up
    END
