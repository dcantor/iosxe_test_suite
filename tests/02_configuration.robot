*** Settings ***
Documentation     Exercises the config plane: push, verify, roll back.
Resource          ../resources/c8000v.resource
Library           String
Suite Setup       Open All Routers
Suite Teardown    Run Keywords    Run Keyword And Ignore Error    Remove Test Loopback
...                                  AND    Close All Routers
Test Teardown     Run Keyword If Test Failed    Log    ${TEST_NAME} failed -- see the console on port 5001

*** Variables ***
${LOOPBACK}       Loopback100
${LOOPBACK_IP}    192.0.2.1
${LOOPBACK_MASK}  255.255.255.0

*** Test Cases ***
Create A Loopback Interface
    ${out}=    Configure On    R1
    ...    interface ${LOOPBACK}
    ...    description ROBOT-MANAGED
    ...    ip address ${LOOPBACK_IP} ${LOOPBACK_MASK}
    ...    no shutdown
    Command Output Should Not Contain Error    ${out}

Loopback Appears In The Interface Table
    ${out}=    Run On    R1    show ip interface brief ${LOOPBACK}
    Should Match Regexp    ${out}    ${LOOPBACK}\\s+${LOOPBACK_IP}\\s+YES\\s+manual\\s+up\\s+up

Loopback Is Reachable From The Device Itself
    # The first echo to a freshly created interface is routinely dropped while the
    # route and adjacency install, so prime the path before asserting on it.
    Run On    R1    ping ${LOOPBACK_IP} repeat 2
    Wait Until Keyword Succeeds    3x    2s    Ping Should Fully Succeed    R1    ${LOOPBACK_IP}    repeat 5

Loopback Is Present In The Running Config
    ${out}=    Run On    R1    show running-config interface ${LOOPBACK}
    Should Contain    ${out}    description ROBOT-MANAGED
    Should Contain    ${out}    ip address ${LOOPBACK_IP} ${LOOPBACK_MASK}

Removing The Loopback Cleans It Up
    Remove Test Loopback
    ${out}=    Run On    R1    show ip interface brief ${LOOPBACK}
    Should Not Contain    ${out}    ${LOOPBACK_IP}

*** Keywords ***
Remove Test Loopback
    Configure On    R1    no interface ${LOOPBACK}
