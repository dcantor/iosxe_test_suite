*** Settings ***
Documentation     Negative and lifecycle checks. Suite 04 proves the tunnel works;
...               these prove it fails when it should, and survives a rekey.
...               Every test restores baseline state, and so does the suite teardown.
Resource          ../resources/c8000v.resource
Suite Setup       Open All Routers
Suite Teardown    Run Keywords    Restore Baseline Crypto    AND    Close All Routers

*** Variables ***
${GOOD_PSK}       LabPreSharedKey123
${BAD_PSK}        WrongKeyOnPurpose999
${SHORT_LIFETIME}    120

*** Test Cases ***
IKEv2 Refuses To Establish With A Mismatched Pre-Shared Key
    [Documentation]    Proves authentication is actually enforced. Without this, a
    ...                tunnel that accepted any peer would still pass suite 04.
    Set Pre Shared Key On    R2    ${BAD_PSK}
    Reset Crypto On Both
    ${out}=    Run On    R1    ping ${R2_LOOPBACK} source Loopback0 repeat 5
    Should Not Contain    ${out}    Success rate is 100 percent
    # Assert on the spoke whose key we broke: the hub legitimately keeps a READY
    # SA with the *other* spoke, so its output is not a valid signal here.
    ${sa}=    Run On    R2    show crypto ikev2 sa
    Should Not Contain    ${sa}    READY

Tunnel Recovers Once The Correct Key Is Restored
    [Documentation]    Also guarantees the previous test cannot leave the lab broken.
    Set Pre Shared Key On    R2    ${GOOD_PSK}
    Reset Crypto On Both
    Wait Until Keyword Succeeds    12x    5s    Protected Traffic Should Flow

IPsec Rekeys And Traffic Still Flows Afterwards
    [Documentation]    Drops the SA lifetime to the 120s platform minimum, waits for
    ...                the outbound SPI to rotate, then re-checks connectivity. Rekey
    ...                is where real tunnels break.
    [Timeout]    8 minutes
    Set SA Lifetime    ${SHORT_LIFETIME}
    Reset Crypto On Both
    Wait Until Keyword Succeeds    12x    5s    Protected Traffic Should Flow
    ${spi}=    Get Outbound SPI    R1
    Log    outbound SPI before rekey: ${spi}    console=${TRUE}
    Wait Until Keyword Succeeds    30x    10s    Outbound SPI Should Have Rotated    R1    ${spi}
    # Retried, like the check before the rekey. The property is that traffic
    # flows again afterwards, not that the very first packet through a
    # just-installed SA survives -- those are routinely lost while the new SA
    # settles, and a single unretried ping here was passing on timing alone.
    Wait Until Keyword Succeeds    12x    5s    Protected Traffic Should Flow
    [Teardown]    Restore Default SA Lifetime

*** Keywords ***
Set Pre Shared Key On
    [Documentation]    The provisioner names each keyring peer after the router it
    ...                faces, so a spoke's peer entry is called after the hub.
    [Arguments]    ${alias}    ${key}
    Configure On    ${alias}    crypto ikev2 keyring LAB-KR    peer ${HUB}    pre-shared-key ${key}

Reset Crypto On Both
    FOR    ${alias}    IN    @{ROUTERS}
        Run On    ${alias}    clear crypto sa
        Run On    ${alias}    clear crypto ikev2 sa
    END
    Sleep    3s

Protected Traffic Should Flow
    Ping Should Fully Succeed    R1    ${R2_LOOPBACK}    source Loopback0 repeat 5

Get Outbound SPI
    [Arguments]    ${alias}
    ${out}=    Run On    ${alias}    show crypto ipsec sa
    @{m}=    Get Regexp Matches    ${out}    current outbound spi: (0x[0-9A-Fa-f]+)    1
    Should Not Be Empty    ${m}    no outbound SPI found - is the tunnel up?
    RETURN    ${m}[0]

Outbound SPI Should Have Rotated
    [Arguments]    ${alias}    ${old}
    ${new}=    Get Outbound SPI    ${alias}
    Should Not Be Equal    ${new}    ${old}    SPI ${new} has not rotated yet

Set SA Lifetime
    [Arguments]    ${seconds}
    FOR    ${alias}    IN    @{ROUTERS}
        Configure On    ${alias}    crypto ipsec security-association lifetime seconds ${seconds}
    END

Restore Default SA Lifetime
    FOR    ${alias}    IN    @{ROUTERS}
        Configure On    ${alias}    no crypto ipsec security-association lifetime seconds ${SHORT_LIFETIME}
    END

Restore Baseline Crypto
    [Documentation]    Belt and braces: never leave the lab with a wrong key or a
    ...                120-second lifetime, whatever failed above.
    Run Keyword And Ignore Error    Set Pre Shared Key On    R2    ${GOOD_PSK}
    Run Keyword And Ignore Error    Restore Default SA Lifetime
    Run Keyword And Ignore Error    Reset Crypto On Both
    Run Keyword And Ignore Error    Wait Until Keyword Succeeds    12x    5s    Protected Traffic Should Flow
