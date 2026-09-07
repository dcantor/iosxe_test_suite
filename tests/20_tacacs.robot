*** Settings ***
Documentation     TACACS+ authentication against the server on the NMS.
...
...               tac_plus runs on the NMS and is reached over the out-of-band
...               network inside the MGMT VRF, so AAA rides the management plane
...               like NTP, syslog and SNMP.
...
...               Two remote users exist at different privilege levels, which is
...               what makes the privilege assertions mean anything: if both landed
...               at the same level the tests would pass just as well against a
...               router ignoring the server and applying its own default.
...
...               The last two tests are the ones worth having. One removes the
...               server and requires the local account to still work -- the
...               property that stops an AAA change locking a lab out of itself.
...               The other is the trap that caught this lab out: "group ... local"
...               falls through to local only when the server is UNREACHABLE. A
...               reachable server that rejects an unknown user is an authoritative
...               no, and IOS honours it.
Resource          ../resources/c8000v.resource
Library           ${CURDIR}/../tools/aaa_keywords.py
Library           Collections
Library           String
Suite Setup       Run Keywords    Open All Routers    AND    Open Tacacs Server
Suite Teardown    Run Keywords    Restore Oob Interfaces    AND    Close Tacacs Server
...                               AND    Close All Connections

*** Variables ***
${ADMIN_USER}     netadmin
${ADMIN_PASS}     NetAdmin_123!
${ADMIN_PRIV}     15
${OPS_USER}       netops
${OPS_PASS}       NetOps_123!
${OPS_PRIV}       1
${TAC_PORT}       49
${TAC_GROUP}      LABTACGRP
&{OOB_INTF}       R1=${R1_OOB_INTF}    R2=${R2_OOB_INTF}    R3=${R3_OOB_INTF}

*** Test Cases ***
The TACACS Server Runs On The NMS
    ${state}=    Tacacs Service State
    Should Be Equal    ${state}    active    tac_plus is not running on the NMS
    ${listening}=    Tacacs Listening On
    Should Contain    ${listening}    :${TAC_PORT}
    Should Contain    ${listening}    tac_plus
    Log    ${listening}    console=${TRUE}

The Server Holds Both Remote Users And The Automation Account
    [Documentation]    The automation account has to exist on the server as well
    ...                as locally on each router. Without it the first router to
    ...                get AAA becomes unmanageable by this very test suite, while
    ...                the server sits there perfectly healthy.
    ${users}=    Tacacs Configured Users
    Should Contain    ${users}    ${ADMIN_USER}
    Should Contain    ${users}    ${OPS_USER}
    Should Contain    ${users}    ${USERNAME}
    ...    the automation account is missing from the server, which would lock the suite out

Every Router Points At The Server Through The Management VRF
    FOR    ${r}    IN    @{ROUTERS}
        ${cfg}=    Run On    ${r}    show running-config | include ^aaa |^tacacs server|^ address ipv4|^ ip vrf forwarding|^ ip tacacs source
        Should Contain    ${cfg}    aaa new-model    ${r} has no AAA model enabled
        Should Contain    ${cfg}    address ipv4 ${NMS_OOB_IP}
        Should Contain    ${cfg}    ip vrf forwarding ${MGMT_VRF}
        ...    ${r} reaches the server outside the management VRF
        Should Contain    ${cfg}    ip tacacs source-interface ${OOB_INTF}[${r}]
    END

Every Method List Falls Back To The Local Database
    [Documentation]    A method list with no local fallback locks the lab out the
    ...                moment the server is unreachable -- including from the
    ...                console, which is the one way back in.
    FOR    ${r}    IN    @{ROUTERS}
        ${cfg}=    Run On    ${r}    show running-config | include ^aaa authentication login|^aaa authorization exec
        Should Contain    ${cfg}    login default group ${TAC_GROUP} local
        ...    ${r}'s login list has no local fallback
        Should Contain    ${cfg}    exec default group ${TAC_GROUP} local
        ...    ${r}'s exec authorization has no local fallback
    END

Every Router Reports The Server Alive
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show tacacs
        Should Contain    ${out}    Server Status: Alive    ${r} cannot reach the server
        Should Contain    ${out}    ${NMS_OOB_IP}
    END

A Remote Administrator Authenticates And Is Given Privilege 15
    FOR    ${r}    IN    @{ROUTERS}
        ${priv}=    Login Privilege Level    ${r}    ${ADMIN_USER}    ${ADMIN_PASS}
        Should Be Equal As Integers    ${priv}    ${ADMIN_PRIV}
        ...    ${r} gave ${ADMIN_USER} privilege ${priv}, expected ${ADMIN_PRIV}
    END

A Remote Operator Authenticates And Is Held At Privilege 1
    [Documentation]    The pair that proves the level comes from the server. Two
    ...                users, same router, same method list, different levels --
    ...                which cannot happen if the router is applying a default.
    FOR    ${r}    IN    @{ROUTERS}
        ${priv}=    Login Privilege Level    ${r}    ${OPS_USER}    ${OPS_PASS}
        Should Be Equal As Integers    ${priv}    ${OPS_PRIV}
        ...    ${r} gave ${OPS_USER} privilege ${priv}, expected ${OPS_PRIV}
    END

A Wrong Password Is Refused
    ${err}=    Login Should Fail    R2    ${ADMIN_USER}    NotTheRightPassword
    Log    ${err}    console=${TRUE}

An Unknown User Is Refused
    [Documentation]    The server rejects the user and the router honours that
    ...                rather than quietly trying the local database.
    ${err}=    Login Should Fail    R2    nosuchuser    AnyPassword123
    Log    ${err}    console=${TRUE}

The Server Records Authentication In Its Accounting Log
    [Documentation]    Accounting is what makes remote authentication auditable;
    ...                without it the router knows who logged in and nobody else
    ...                ever finds out.
    Login Privilege Level    R3    ${ADMIN_USER}    ${ADMIN_PASS}
    Wait Until Keyword Succeeds    12x    5s    Accounting Should Show    ${ADMIN_USER}    R3

Accounting Records Carry The Privilege Level And Come From The OOB Address
    ${log}=    Tacacs Accounting Log
    ${line}=    Accounting Should Record    ${log}    ${ADMIN_USER}    R3
    Should Contain    ${line}    service=shell
    Should Contain    ${line}    ${R3_OOB_IP}
    ...    the record did not come from R3's out-of-band address
    Log    ${line}    console=${TRUE}

The Local Account Still Works When The Server Is Unreachable
    [Documentation]    The resilience property. R2's out-of-band interface is shut,
    ...                which is the only path to the server, so TACACS becomes
    ...                unreachable rather than merely unwilling. The automation
    ...                account must still get in through the local database, and a
    ...                remote-only user must not -- it exists nowhere else.
    ...
    ...                The precondition is a ping inside the VRF, not "show
    ...                tacacs". That field reports cached state -- it keeps saying
    ...                Alive until a transaction actually fails -- so waiting on it
    ...                would either hang or, worse, let this test run with the
    ...                server still reachable and prove nothing.
    [Teardown]    Restore Oob Interfaces
    Configure On    R2    interface ${OOB_INTF}[R2]    shutdown
    Wait Until Keyword Succeeds    12x    5s    Server Should Be Unreachable From    R2

    ${priv}=    Login Privilege Level    R2    ${USERNAME}    ${PASSWORD}
    Should Be Equal As Integers    ${priv}    15
    ...    the local account could not get in with the server unreachable
    ${err}=    Login Should Fail    R2    ${ADMIN_USER}    ${ADMIN_PASS}
    Log    local account in at privilege ${priv}; remote user refused: ${err}    console=${TRUE}

*** Keywords ***
Accounting Should Show
    [Arguments]    ${user}    ${router}
    ${log}=    Tacacs Accounting Log
    Accounting Should Record    ${log}    ${user}    ${router}

Server Should Be Unreachable From
    [Documentation]    A live check. "show tacacs" caches its Alive/Dead verdict
    ...                and only revises it after a transaction fails, so it is not
    ...                a usable signal for "the path is gone right now".
    ...
    ...                Two forms of unreachable count. Shutting the only interface
    ...                in the VRF takes its address with it, so IOS refuses to send
    ...                at all -- "does not have a usable source address" -- rather
    ...                than sending and losing the packets. That is the stronger
    ...                result, but it is not a 0 percent success rate, and matching
    ...                only on the latter waits out the retries for nothing.
    [Arguments]    ${alias}
    ${out}=    Run On    ${alias}    ping vrf ${MGMT_VRF} ${NMS_OOB_IP} repeat 2
    Should Match Regexp    ${out}    Success rate is 0 percent|does not have a usable source address
    ...    ${alias} can still reach the server, so this would not test the fallback

Restore Oob Interfaces
    FOR    ${r}    IN    @{ROUTERS}
        Run Keyword And Ignore Error    Configure On    ${r}
        ...    interface ${OOB_INTF}[${r}]    no shutdown
    END
    Run Keyword And Ignore Error    Wait Until Keyword Succeeds    18x    5s
    ...    Router Should Report Server Alive    R2

Router Should Report Server Alive
    [Arguments]    ${alias}
    ${out}=    Run On    ${alias}    ping vrf ${MGMT_VRF} ${NMS_OOB_IP} repeat 5
    Should Contain    ${out}    Success rate is 100 percent
    ...    ${alias} has not recovered its path to the server
