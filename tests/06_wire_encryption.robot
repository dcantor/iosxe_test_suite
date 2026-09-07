*** Settings ***
Documentation     Observes the actual wire. The counter-based tests in 04 infer
...               encryption from ESP statistics; these capture packets on the link
...               and assert what is really on it.
Resource          ../resources/c8000v.resource
Suite Setup       Open All Routers
Suite Teardown    Run Keywords    Run Keyword And Ignore Error    Delete Capture    R1
...                               AND    Close All Routers

*** Variables ***
${CAPTURE}        ROBOTCAP
${CAP_PINGS}      5

*** Test Cases ***
Protected Traffic Appears On The Link As ESP
    ${buf}=    Capture Link Traffic During    R1    ping ${R2_LOOPBACK} source Loopback0 repeat ${CAP_PINGS}
    Should Contain    ${buf}    ESP
    Should Match Regexp    ${buf}    ${R2_LINK_HUB}\\s+->\\s+${R2_LINK_LOCAL}

Protected Endpoint Addresses Never Appear In Cleartext On The Link
    [Documentation]    The strongest statement this lab can make about encryption:
    ...                traffic between the loopbacks crosses the wire without either
    ...                loopback address being visible, and with no cleartext ICMP.
    ${buf}=    Capture Link Traffic During    R1    ping ${R2_LOOPBACK} source Loopback0 repeat ${CAP_PINGS}
    Should Not Contain    ${buf}    ${R1_LOOPBACK}
    Should Not Contain    ${buf}    ${R2_LOOPBACK}
    Should Not Contain    ${buf}    ICMP

Unprotected Link Traffic Is Visible As Cleartext ICMP
    [Documentation]    Positive control for the capture itself. Without this, the
    ...                absence asserted above could just mean the capture was broken.
    ${buf}=    Capture Link Traffic During    R1    ping ${R2_LINK_LOCAL} repeat ${CAP_PINGS}
    Should Contain    ${buf}    ICMP
    Should Match Regexp    ${buf}    ${R2_LINK_HUB}\\s+->\\s+${R2_LINK_LOCAL}\\s+\\S+\\s+\\S+\\s+ICMP
    # Deliberately no assertion that ESP is absent: BGP peers across the tunnel, so
    # encrypted keepalives are always on this link. The claim here is only that
    # unprotected traffic IS visible in cleartext.
