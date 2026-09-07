*** Settings ***
Documentation     Management logins restricted to the out-of-band network.
...
...               An access-class on the VTY lines, enforced before
...               authentication, so a login attempt from anywhere else never
...               reaches the password prompt at all.
...
...               The ACL carries a second permit for the hypervisor's user-mode
...               NAT, and that is a documented weakening rather than an
...               oversight: every tool in this repo reaches the routers through a
...               port QEMU forwards on Gi1, so its sessions arrive from 10.0.2.2
...               and not from the management network. Permitting only the OOB
...               subnet would lock the harness out of all three routers at once,
...               recoverable solely from the serial console. A real deployment
...               would have no such path, or would come through the NMS as a jump
...               host so that sessions genuinely originate on the OOB network.
...
...               The NMS holds an address on both the management network and the
...               hub LAN, which is what makes the negative test clean: one
...               machine, two source addresses, the same target, and the only
...               difference between allowed and refused is the subnet the packet
...               came from.
Resource          ../resources/c8000v.resource
Library           ${CURDIR}/../tools/aaa_keywords.py
Library           ${CURDIR}/../tools/syslog_keywords.py
Library           String
Suite Setup       Run Keywords    Open All Routers    AND    Open Tacacs Server
...                               AND    Open Collector
Suite Teardown    Run Keywords    Close Tacacs Server    AND    Close Collector
...                               AND    Close All Connections

*** Variables ***
${VTY_ACL}         VTY-MGMT
${MGMT_NAT_NET}    10.0.2.0

*** Test Cases ***
Every Router Applies The ACL Inbound On All VTY Lines
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show running-config | section ^line vty
        Should Contain    ${out}    access-class ${VTY_ACL} in vrf-also
        ...    ${r} lacks vrf-also, so OOB sessions are dropped before the ACL is read
        ...    ${r} does not apply ${VTY_ACL} to its VTY lines
        ${lines}=    Get Regexp Matches    ${out}    line vty (\\d+) (\\d+)    1    2
        Log    ${r} vty ranges: ${lines}    console=${TRUE}
    END

Only SSH Is Accepted On The VTY Lines
    [Documentation]    An ACL restricting who may connect is worth less if telnet
    ...                is still an option for those who may.
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show running-config | section ^line vty
        Should Contain    ${out}    transport input ssh
        Should Not Contain    ${out}    transport input all
        Should Not Contain    ${out}    transport input telnet
    END

The ACL Permits The Management Network And Denies The Rest
    FOR    ${r}    IN    @{ROUTERS}
        ${acl}=    Run On    ${r}    show ip access-lists ${VTY_ACL}
        Should Contain    ${acl}    permit ${OOB_NET}, wildcard bits 0.0.0.255
        ...    ${r} does not permit the out-of-band network
        Should Contain    ${acl}    deny   any log
        ...    ${r}'s ACL does not end in a logged deny, so refusals leave no evidence
    END

The Documented Exception Is Present And Is Only The Hypervisor Path
    [Documentation]    Pinned deliberately. This permit is the one concession in
    ...                the policy, so it should be visible in a test rather than
    ...                only in a comment -- and widening it should break something.
    FOR    ${r}    IN    @{ROUTERS}
        ${acl}=    Run On    ${r}    show ip access-lists ${VTY_ACL}
        Should Contain    ${acl}    permit ${MGMT_NAT_NET}, wildcard bits 0.0.0.255
        ${permits}=    Get Regexp Matches    ${acl}    permit \\d+\\.\\d+\\.\\d+\\.\\d+
        Length Should Be    ${permits}    2
        ...    ${r} permits ${permits} -- exactly two sources are intended
    END

SSH From The Management Network Is Allowed
    ${banner}=    Ssh Should Be Permitted From    ${NMS_OOB_IP}    ${R1_OOB_IP}
    Should Start With    ${banner}    SSH-
    Log    ${NMS_OOB_IP} -> ${R1_OOB_IP}: ${banner}    console=${TRUE}

SSH From Outside The Management Network Is Refused
    [Documentation]    The same machine, a different source address, and a target
    ...                it is directly connected to -- so nothing but the ACL can
    ...                account for the difference. Before the access-class was
    ...                applied this path returned a banner just like the one above.
    ${err}=    Ssh Should Be Denied From    ${NMS_IP}    ${R1_LAN_IP}
    Log    ${NMS_IP} -> ${R1_LAN_IP}: ${err}    console=${TRUE}

Every Router Refuses A Login From Outside The Management Network
    FOR    ${r}    IN    @{ROUTERS}
        Ssh Should Be Denied From    ${NMS_IP}    ${${r}_LAN_IP}
    END

The Refusal Is Logged And Reaches The Collector
    [Documentation]    "deny any log" makes a rejected connection auditable rather
    ...                than merely blocked, and the message travels the OOB network
    ...                to the collector like every other log.
    Ssh Should Be Denied From    ${NMS_IP}    ${R1_LAN_IP}
    Wait Until Keyword Succeeds    12x    5s    Denial Should Reach The Collector    R1

The Harness Path Still Works
    [Documentation]    The reason the second permit exists. If this fails the lab
    ...                is unreachable by every other suite, so it is asserted here
    ...                rather than discovered in the next run.
    ...
    ...                Asserted from the ACL's own hit counter rather than from
    ...                "show users". That column prints a resolved name when
    ...                reverse DNS answers -- inside the packaged appliance the
    ...                same session shows as "_gateway" instead of 10.0.2.2 --
    ...                so matching on the rendered address made this depend on
    ...                name resolution rather than on the thing being tested.
    ...                A hit on that ACE means a session was admitted by exactly
    ...                the permit under discussion.
    FOR    ${r}    IN    @{ROUTERS}
        ${acl}=    Run On    ${r}    show ip access-lists ${VTY_ACL}
        ${hits}=    Get Regexp Matches    ${acl}
        ...    permit ${MGMT_NAT_NET}, wildcard bits 0.0.0.255 \\((\\d+) match    1
        Should Not Be Empty    ${hits}
        ...    ${r}: the hypervisor-NAT permit has no hits, so this session did not match it
        Should Be True    ${hits}[0] > 0
    END

*** Keywords ***
Denial Should Reach The Collector
    [Arguments]    ${router}
    ${text}=    Collector Text For    ${router}
    Should Match Regexp    ${text}    SEC-6-IPACCESSLOG\\S*
    ...    no access-list denial logged by ${router} reached the collector
