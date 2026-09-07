*** Settings ***
Documentation     Baseline health checks against both routers in the testbed.
Resource          ../resources/c8000v.resource
Suite Setup       Open All Routers
Suite Teardown    Close All Routers

*** Test Cases ***
Both Routers Report Catalyst 8000V Software
    FOR    ${alias}    IN    R1    R2
        ${out}=    Run On    ${alias}    show version
        Should Match Regexp    ${out}    Cisco IOS[ -]XE Software, Version \\d+\\.\\d+
        Should Contain    ${out}    C8000V
    END

Hostnames Match The Day0 Bootstrap Configs
    Command Output Should Contain    R1    show running-config | include ^hostname    ${R1_NAME}
    Command Output Should Contain    R2    show running-config | include ^hostname    ${R2_NAME}

Management Interfaces Are Up With DHCP Addresses
    FOR    ${alias}    IN    R1    R2
        ${out}=    Run On    ${alias}    show ip interface brief GigabitEthernet1
        Should Match Regexp    ${out}    GigabitEthernet1\\s+10\\.0\\.2\\.\\d+\\s+YES\\s+DHCP\\s+up\\s+up
    END

Crypto Feature License Is Active
    [Documentation]    Without a feature license the crypto CLI does not exist at all,
    ...                so every IPsec test downstream depends on this.
    FOR    ${alias}    IN    R1    R2
        ${out}=    Run On    ${alias}    show version | include License Level
        Should Match Regexp    ${out}    License Level:\\s*\\S+
    END

Management Plane Services Are Enabled
    FOR    ${alias}    IN    R1    R2
        ${cfg}=    Run On    ${alias}    show running-config | include ^netconf-yang|^restconf
        Should Contain    ${cfg}    netconf-yang
        Should Contain    ${cfg}    restconf
    END
