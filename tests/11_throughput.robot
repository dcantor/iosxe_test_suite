*** Settings ***
Documentation     Sustained bulk throughput between the Linux hosts, across the
...               encrypted fabric. Traffic is generated with busybox tools only --
...               the cirros image has no iperf and no package manager.
...
...               Note the ceiling: this C8000V is capped by its licence at
...               20000 kb/s (show platform hardware throughput level), so a 15 Mbps
...               target sits close to what the platform can give. Measured headroom
...               is roughly 2 Mbps hub-to-spoke and 1.5 Mbps spoke-to-spoke, the
...               latter being slower because the hub decrypts and re-encrypts. The
...               reported rate is conservative: the sender's 1-second nc linger is
...               inside the measured window, so true throughput is a little higher.
...               If this ever becomes marginal, raise the licensed level rather than
...               lowering the bar.
Resource          ../resources/c8000v.resource
Suite Setup       Run Keywords    Open All Routers    AND    Open All Hosts
...                               AND    Wait For Fabric
Suite Teardown    Close All Connections

*** Variables ***
# 64 MB, not because the volume is needed but because the timing is: the hosts
# only have 1-second resolution, so a 30-second transfer quantises to about
# +/-0.6 Mbps, where a 8-second one quantises to +/-2 Mbps and would make a
# 15 Mbps threshold a coin flip.
${TP_MB}          64
${TP_TARGET}      15
${TP_ENCRYPT_MB}  32
${TP_PORT}        5001

*** Test Cases ***
Hub To Spoke Hosts Sustain The Target Throughput
    [Documentation]    h1 -> h2 crosses one tunnel.
    ${mbps}=    Measure Throughput    H1    H2    ${H2_IP}
    Should Be True    ${mbps} >= ${TP_TARGET}
    ...    h1 -> h2 managed only ${mbps} Mbps, below the ${TP_TARGET} Mbps target

Spoke To Spoke Hosts Sustain The Target Throughput
    [Documentation]    h2 -> h3 crosses two tunnels, being decrypted and re-encrypted
    ...                at the hub, so it is the more demanding path.
    ${mbps}=    Measure Throughput    H2    H3    ${H3_IP}
    Should Be True    ${mbps} >= ${TP_TARGET}
    ...    h2 -> h3 managed only ${mbps} Mbps, below the ${TP_TARGET} Mbps target

Bulk Throughput Traffic Is Encrypted
    [Documentation]    Rate alone says nothing about protection. A transfer of this
    ...                size must move thousands of packets through ESP, so assert the
    ...                counters rose in proportion to the bytes actually sent.
    ${r1e}    ${r1d}=    Get IPsec Counters    R1
    ${r2e}    ${r2d}=    Get IPsec Counters    R2
    Measure Throughput    H1    H2    ${H2_IP}    ${TP_ENCRYPT_MB}
    ${expected}=    Evaluate    int(${TP_ENCRYPT_MB} * 1024 * 1024 / 1500 * 0.6)
    Wait Until Keyword Succeeds    12x    5s    Bulk ESP Counters Should Have Advanced
    ...    R1    R2    ${r1e}    ${r1d}    ${r2e}    ${r2d}    ${expected}

*** Keywords ***
Bulk ESP Counters Should Have Advanced
    [Documentation]    A one-way bulk transfer is asymmetric: the sender's router
    ...                encrypts every data packet while decrypting only the returning
    ...                ACKs, and the receiver's router does the reverse. So the volume
    ...                threshold applies to the data direction, and the ACK direction
    ...                only has to be non-zero -- requiring it to clear the same bar
    ...                would fail on healthy traffic.
    [Arguments]    ${src}    ${dst}    ${se0}    ${sd0}    ${de0}    ${dd0}    ${expected}
    ${se}    ${sd}=    Get IPsec Counters    ${src}
    ${de}    ${dd}=    Get IPsec Counters    ${dst}
    ${data_out}=    Evaluate    ${se} - ${se0}
    ${data_in}=     Evaluate    ${dd} - ${dd0}
    ${ack_in}=      Evaluate    ${sd} - ${sd0}
    ${ack_out}=     Evaluate    ${de} - ${de0}
    Log    data ${src}->${dst}: encrypted ${data_out}, decrypted ${data_in}; acks back: ${ack_in}/${ack_out}    console=${TRUE}
    Should Be True    ${data_out} >= ${expected}
    ...    ${src} encrypted only ${data_out} packets, expected >= ${expected}
    Should Be True    ${data_in} >= ${expected}
    ...    ${dst} decrypted only ${data_in} packets, expected >= ${expected}
    Should Be True    ${ack_in} > 0     no return traffic decrypted at ${src}
    Should Be True    ${ack_out} > 0    no return traffic encrypted at ${dst}

Measure Throughput
    [Documentation]    Streams ${TP_MB} MB over TCP and returns the achieved rate in
    ...                Mbps. busybox nc never half-closes on EOF, so the sender needs
    ...                -w to bound its final read; that linger is inside the measured
    ...                window, which makes the reported figure conservative.
    [Arguments]    ${src}    ${dst}    ${dst_ip}    ${megabytes}=${TP_MB}
    Run On Host    ${dst}    nc -l -p ${TP_PORT} > /dev/null 2>&1 &
    Sleep    1s
    ${blocks}=    Evaluate    ${megabytes} * 16
    ${out}=    Run On Host    ${src}
    ...    S=$(date +%s); dd if=/dev/zero bs=64k count=${blocks} 2>/dev/null | nc -w 1 ${dst_ip} ${TP_PORT}; echo SECS=$(( $(date +%s) - S ))
    @{m}=    Get Regexp Matches    ${out}    SECS=(\\d+)    1
    Should Not Be Empty    ${m}    transfer from ${src} produced no timing: ${out}
    ${secs}=    Evaluate    max(int($m[0]), 1)
    ${mbps}=    Evaluate    round(${megabytes} * 8 / ${secs}, 1)
    Log    ${src} -> ${dst}: ${megabytes} MB in ${secs}s = ${mbps} Mbps    console=${TRUE}
    RETURN    ${mbps}

Wait For Fabric
    [Documentation]    Earlier suites churn BGP and the tunnels; do not start pushing
    ...                bulk traffic until every LAN is reachable again.
    FOR    ${r}    IN    @{ROUTERS}
        Wait Until Keyword Succeeds    24x    5s    Routing Table Should Hold All LANs    ${r}
    END

Routing Table Should Hold All LANs
    [Arguments]    ${alias}
    ${rt}=    Run On    ${alias}    show ip route
    Should Contain    ${rt}    ${R1_LAN_NET}
    Should Contain    ${rt}    ${R2_LAN_NET}
    Should Contain    ${rt}    ${R3_LAN_NET}
