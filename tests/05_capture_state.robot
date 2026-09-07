*** Settings ***
Documentation     Captures the full running configuration and routing table from every
...               device -- three routers and three Linux hosts. Numbered to run late
...               so it records the state the other suites leave behind. Each capture
...               is written beside the report so successive runs can be diffed.
Resource          ../resources/c8000v.resource
Library           OperatingSystem
Library           ${CURDIR}/../tools/snmp_poll_keywords.py
Suite Setup       Run Keywords    Open All Routers    AND    Open All Hosts    AND    Open Nms
Suite Teardown    Run Keywords    Close Nms    AND    Close All Connections

*** Variables ***
&{ROUTER_IP}          R1=${R1_LAN_IP}    R2=${R2_LAN_IP}    R3=${R3_LAN_IP}
${SNMP_POLL_USER}     labmon
${SNMP_AUTH_PASS}     LabAuthPass123
${SNMP_PRIV_PASS}     LabPrivPass123
${SYSLOG_DIR}         /var/log/lab
${SNMP_TRAPD_LOG}     /var/log/lab/snmptrapd.log

*** Test Cases ***
Capture Running Config From Every Router
    FOR    ${alias}    IN    @{ROUTERS}
        ${cfg}=    Capture From Router    ${alias}    show running-config    running-config
        Should Contain    ${cfg}    hostname
        Should Match Regexp    ${cfg}    (?m)^end\\s*$
    END

Capture Routing Table From Every Router
    FOR    ${alias}    IN    @{ROUTERS}
        ${rt}=    Capture From Router    ${alias}    show ip route    ip-route
        Should Contain    ${rt}    Gateway of last resort
        Should Contain    ${rt}    Codes:
    END

Capture BGP Table And Neighbours From Every Router
    FOR    ${alias}    IN    @{ROUTERS}
        Capture From Router    ${alias}    show bgp ipv4 unicast    bgp-table
        Capture From Router    ${alias}    show bgp ipv4 unicast summary    bgp-summary
    END

Capture Crypto State From Every Router
    FOR    ${alias}    IN    @{ROUTERS}
        Capture From Router    ${alias}    show crypto ipsec sa    crypto-ipsec-sa
        Capture From Router    ${alias}    show crypto ikev2 sa    crypto-ikev2-sa
    END

Capture NAT State From Every Router
    FOR    ${alias}    IN    @{ROUTERS}
        Capture From Router    ${alias}    show ip nat translations    nat-translations
        Capture From Router    ${alias}    show ip nat statistics      nat-statistics
    END

Capture NTP State From Every Router
    FOR    ${alias}    IN    @{ROUTERS}
        Capture From Router    ${alias}    show ntp status          ntp-status
        Capture From Router    ${alias}    show ntp associations    ntp-associations
    END

Capture Logging State From Every Router
    FOR    ${alias}    IN    @{ROUTERS}
        Capture From Router    ${alias}    show logging | include Trap logging|Logging to|Syslog logging    logging-state
    END

Capture SNMP State From Every Router
    FOR    ${alias}    IN    @{ROUTERS}
        Capture From Router    ${alias}    show snmp user      snmp-user
        Capture From Router    ${alias}    show snmp host      snmp-host
        Capture From Router    ${alias}    show snmp engineID  snmp-engineid
    END

Capture The NMS View Of Every Router
    [Documentation]    The same system group, but seen over SNMPv3 from the NMS
    ...                rather than read off the console. Captured next to the CLI
    ...                output so the two can be compared in the evidence PDF.
    Capture From Nms    ip -br addr; ip route    network
    Capture From Nms    snmpget --version 2>&1 | head -1    snmp-version
    FOR    ${alias}    IN    @{ROUTERS}
        ${ip}=    Set Variable    ${ROUTER_IP}[${alias}]
        Capture From Nms
        ...    snmpwalk -On -v3 -l authPriv -u ${SNMP_POLL_USER} -a SHA -A ${SNMP_AUTH_PASS} -x AES -X ${SNMP_PRIV_PASS} ${ip} 1.3.6.1.2.1.1
        ...    ${alias}-snmp-system
        Capture From Nms
        ...    snmpwalk -On -v3 -l authPriv -u ${SNMP_POLL_USER} -a SHA -A ${SNMP_AUTH_PASS} -x AES -X ${SNMP_PRIV_PASS} ${ip} 1.3.6.1.2.1.2.2.1.2
        ...    ${alias}-snmp-interfaces
    END

Capture Collector State From The NMS
    [Documentation]    What the collectors actually hold: the tail of each router's
    ...                syslog file and of snmptrapd's decrypted log. This is the
    ...                management-plane evidence that used to come off h1.
    Capture From Nms    systemctl is-active rsyslog snmptrapd lab-trapcap    collectors
    Capture From Nms    sudo ls -l ${SYSLOG_DIR}    collector-files
    FOR    ${alias}    IN    @{ROUTERS}
        Capture From Nms
        ...    sudo tail -40 ${SYSLOG_DIR}/${ROUTER_IP}[${alias}].log
        ...    ${alias}-syslog
    END
    Capture From Nms    sudo tail -40 ${SNMP_TRAPD_LOG}    snmptrapd

Capture Config And Routing Table From Every Host
    FOR    ${alias}    IN    @{HOSTS}
        ${addr}=    Capture From Host    ${alias}    ip addr    ip-addr
        Should Contain    ${addr}    eth1
        ${rt}=    Capture From Host    ${alias}    ip route    ip-route
        Should Contain    ${rt}    default via
    END

Every Router Routing Table Holds All Three LANs
    [Documentation]    A content check on what was just captured: in a working
    ...                hub-and-spoke every router reaches every LAN, the spokes
    ...                reaching each other's through the hub.
    FOR    ${alias}    IN    @{ROUTERS}
        ${rt}=    Run On    ${alias}    show ip route
        Should Contain    ${rt}    ${R1_LAN_NET}
        Should Contain    ${rt}    ${R2_LAN_NET}
        Should Contain    ${rt}    ${R3_LAN_NET}
    END

*** Keywords ***
Capture From Nms
    [Documentation]    Runs one command on the NMS and saves it as nms-<label>.txt.
    [Arguments]    ${command}    ${label}
    ${out}=    Nms Command    ${command}
    Log    nms $ ${command}\n${out}
    Create File    ${OUTPUT DIR}/nms-${label}.txt    ${out}
    RETURN    ${out}

Capture From Router
    [Documentation]    Runs one show command and saves it as <alias>-<label>.txt.
    [Arguments]    ${alias}    ${command}    ${label}
    ${out}=    Run On    ${alias}    ${command}
    ${lines}=    Get Line Count    ${out}
    Log    ${alias} ${command} (${lines} lines)\n${out}
    Create File    ${OUTPUT DIR}/${alias}-${label}.txt    ${out}
    RETURN    ${out}

Capture From Host
    [Arguments]    ${alias}    ${command}    ${label}
    ${out}=    Run On Host    ${alias}    ${command}
    Log    ${alias} ${command}\n${out}
    Create File    ${OUTPUT DIR}/${alias}-${label}.txt    ${out}
    RETURN    ${out}
