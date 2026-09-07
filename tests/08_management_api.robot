*** Settings ***
Documentation     Exercises the NETCONF and RESTCONF management planes, which the
...               day0 config enables but nothing else tests. Every API answer is
...               cross-checked against the CLI, so model/CLI drift shows up.
Library           RequestsLibrary
Library           Collections
Library           ${CURDIR}/../tools/netconf_keywords.py
Resource          ../resources/c8000v.resource
Suite Setup       Run Keywords    Open All Routers    AND    Create RESTCONF Sessions
Suite Teardown    Run Keywords    Run Keyword And Ignore Error    Delete RESTCONF Loopback
...                               AND    Close All Routers

*** Variables ***
${HOST}                127.0.0.1
${R1_RESTCONF_PORT}    8441
${R2_RESTCONF_PORT}    8442
${R1_NETCONF_PORT}     8831
${R2_NETCONF_PORT}     8832
${R3_RESTCONF_PORT}    8443
${R3_NETCONF_PORT}     8833
${RC_LOOPBACK_ID}      200
${RC_LOOPBACK_IP}      198.51.100.1
${RC_LOOPBACK_PATH}    /restconf/data/Cisco-IOS-XE-native:native/interface/Loopback=200
&{YANG_HEADERS}        Accept=application/yang-data+json    Content-Type=application/yang-data+json

*** Test Cases ***
RESTCONF Reports The Same Hostname As The CLI
    Restconf Hostname Should Match CLI    r1    R1
    Restconf Hostname Should Match CLI    r2    R2
    Restconf Hostname Should Match CLI    r3    R3

RESTCONF Interface State Agrees With The CLI
    ${resp}=    GET On Session    r1
    ...    url=/restconf/data/ietf-interfaces:interfaces-state/interface=GigabitEthernet2/oper-status
    ...    headers=&{YANG_HEADERS}
    Status Should Be    200    ${resp}
    ${status}=    Get From Dictionary    ${resp.json()}    ietf-interfaces:oper-status
    Should Be Equal    ${status}    up
    ${cli}=    Run On    R1    show ip interface brief GigabitEthernet2
    Should Match Regexp    ${cli}    GigabitEthernet2\\s+${R2_LINK_HUB}\\s+YES\\s+\\S+\\s+up\\s+up

Config Pushed Over RESTCONF Appears In The CLI
    [Documentation]    Write path plus cross-check: RESTCONF and the CLI must be two
    ...                views of one datastore, not two datastores.
    ${body}=    Evaluate
    ...    {"Cisco-IOS-XE-native:Loopback": {"name": ${RC_LOOPBACK_ID}, "ip": {"address": {"primary": {"address": "${RC_LOOPBACK_IP}", "mask": "255.255.255.0"}}}}}
    ${resp}=    PUT On Session    r1    url=${RC_LOOPBACK_PATH}    json=${body}
    ...    headers=&{YANG_HEADERS}    expected_status=any
    Should Be True    ${resp.status_code} in (201, 204)
    ...    RESTCONF PUT returned ${resp.status_code}
    ${cli}=    Run On    R1    show running-config interface Loopback${RC_LOOPBACK_ID}
    Should Contain    ${cli}    ${RC_LOOPBACK_IP}

Config Deleted Over RESTCONF Disappears From The CLI
    [Documentation]    Runs after the PUT test, which creates the interface; a 404
    ...                here would mean the create silently failed.
    ${resp}=    DELETE On Session    r1    url=${RC_LOOPBACK_PATH}
    ...    headers=&{YANG_HEADERS}    expected_status=any
    Should Be Equal As Integers    ${resp.status_code}    204
    ...    RESTCONF DELETE returned ${resp.status_code}; expected 204 for the loopback created by the previous test
    ${cli}=    Run On    R1    show ip interface brief Loopback${RC_LOOPBACK_ID}
    Should Not Contain    ${cli}    ${RC_LOOPBACK_IP}

NETCONF Reports The Same Hostname As The CLI
    ${name}=    Get NETCONF Hostname    ${HOST}    ${R1_NETCONF_PORT}    ${USERNAME}    ${PASSWORD}
    Should Be Equal    ${name}    ${R1_NAME}
    ${cli}=    Run On    R1    show running-config | include ^hostname
    Should Contain    ${cli}    ${name}

NETCONF Advertises The Expected Base Capabilities
    [Documentation]    IOS-XE does not list per-module URIs such as Cisco-IOS-XE-native
    ...                in the hello; modules are exposed via yang-library. That the
    ...                native model is usable is proven by the hostname test above,
    ...                which queries the native namespace directly.
    ${caps}=    Get NETCONF Capabilities    ${HOST}    ${R1_NETCONF_PORT}    ${USERNAME}    ${PASSWORD}
    FOR    ${expected}    IN
    ...    urn:ietf:params:netconf:base:1.0
    ...    urn:ietf:params:netconf:capability:writable-running:1.0
    ...    urn:ietf:params:netconf:capability:yang-library:1.0
        ${hit}=    Evaluate    [c for c in $caps if $expected in c]
        Should Not Be Empty    ${hit}    server did not advertise ${expected}
    END

*** Keywords ***
Create RESTCONF Sessions
    Create Session    r1    https://${HOST}:${R1_RESTCONF_PORT}
    ...    auth=${{ ($USERNAME, $PASSWORD) }}    verify=${FALSE}    disable_warnings=1
    Create Session    r2    https://${HOST}:${R2_RESTCONF_PORT}
    ...    auth=${{ ($USERNAME, $PASSWORD) }}    verify=${FALSE}    disable_warnings=1
    Create Session    r3    https://${HOST}:${R3_RESTCONF_PORT}
    ...    auth=${{ ($USERNAME, $PASSWORD) }}    verify=${FALSE}    disable_warnings=1

Restconf Hostname Should Match CLI
    [Arguments]    ${session}    ${alias}
    ${resp}=    GET On Session    ${session}
    ...    /restconf/data/Cisco-IOS-XE-native:native/hostname    headers=&{YANG_HEADERS}
    Status Should Be    200    ${resp}
    ${name}=    Get From Dictionary    ${resp.json()}    Cisco-IOS-XE-native:hostname
    ${cli}=    Run On    ${alias}    show running-config | include ^hostname
    Should Contain    ${cli}    ${name}

Delete RESTCONF Loopback
    ${resp}=    DELETE On Session    r1    url=${RC_LOOPBACK_PATH}
    ...    headers=&{YANG_HEADERS}    expected_status=any
