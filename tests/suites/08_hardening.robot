*** Settings ***
Documentation     Management-plane and L2 hardening: AAA parity, SSH/VTY settings with a management ACL,
...               deterministic STP root and portfast/bpduguard defaults, service/logging hygiene.
Resource          ../resources/common.resource
Suite Teardown    Suite Teardown Close Connections

*** Test Cases ***
AAA is identical on both switches: local login and exec authorization
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${aaa}=    Show    ${sw}    show run | include ^aaa
        Should Match Regexp    ${aaa}    (?m)^aaa new-model$
        Should Match Regexp    ${aaa}    (?m)^aaa authentication login default local$
        Should Match Regexp    ${aaa}    (?m)^aaa authorization exec default local\\s*$
        Should Not Contain    ${aaa}    no aaa new-model
    END

SSH server is hardened
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${ssh}=    Show    ${sw}    show ip ssh
        Should Contain    ${ssh}    SSH Enabled - version 2.0
        Should Contain    ${ssh}    Authentication timeout: 60 secs; Authentication retries: 3
        ${cfg}=    Show    ${sw}    show run | include ^ip ssh
        Should Contain    ${cfg}    ip ssh time-out 60
    END

VTY lines accept SSH only, authenticate via AAA and carry the management ACL
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        FOR    ${block}    IN    line vty 0 4    line vty 5 15
            ${vty}=    Show    ${sw}    show run | section ^${block}
            Should Contain    ${vty}    transport input ssh
            Should Contain    ${vty}    access-class ${MGMT_ACL} in vrf-also
            Should Contain    ${vty}    logging synchronous
            Should Not Contain    ${vty}    login local
            Should Not Contain    ${vty}    exec-timeout 0 0
        END
        ${acl}=    Show    ${sw}    show ip access-lists ${MGMT_ACL}
        Should Match Regexp    ${acl}    20 permit 10\\.0\\.0\\.0, wildcard bits 0\\.0\\.0\\.255
        Should Match Regexp    ${acl}    30 deny\\s+any log
    END

Management ACL admits SSH from the OOB network
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${host}=    Switch Host    ${sw}
        Tcp Port Should Be Open    ${host}    22
        ${out}=    Nms Command    sshpass -p ${PASSWORD} ssh -o ConnectTimeout=10 ${sw} "show users | include vty"
        Should Contain    ${out}    admin
    END

Management ACL blocks SSH from a user VLAN
    [Documentation]    host1 (VLAN 10) tries the switch's own SVI address: TCP/22 must not open, and
    ...                the ACL's deny counter must increase (the "deny any log" line).
    ${before}=    Show    sw1    show ip access-lists ${MGMT_ACL} | include deny
    ${matches_before}=    Deny Match Count    ${before}
    ${rc}=    Host Command Rc    ${HOSTS}[host1][mgmt]    nc -w 5 -z ${HOSTS}[host1][gateway] 22
    Should Not Be Equal As Integers    ${rc}    0    msg=SSH from ${HOSTS}[host1][ip] to the switch was NOT blocked
    Sleep    2s
    ${after}=    Show    sw1    show ip access-lists ${MGMT_ACL} | include deny
    ${matches_after}=    Deny Match Count    ${after}
    Should Be True    ${matches_after} > ${matches_before}    msg=deny counter did not increase (${matches_before} -> ${matches_after})

Spanning tree: sw1 is root for every VLAN, sw2 is backup root, edge defaults on
    # only VLANs carried on the trunk share one STP topology; VLAN 1 (not allowed on the trunk)
    # is an isolated instance per switch and the native VLAN 99 has no ports at all
    ${vlans}=    Get Dictionary Keys    ${VLANS}
    Remove Values From List    ${vlans}    ${TRUNK_NATIVE_VLAN}
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${sum}=    Show    ${sw}    show spanning-tree summary
        Should Contain    ${sum}    Switch is in rapid-pvst mode
        Should Match Regexp    ${sum}    Portfast Default\\s+is enabled
        Should Match Regexp    ${sum}    (?i)portfast (edge )?bpdu guard default\\s+is enabled
        ${root}=    Show    ${sw}    show spanning-tree root
        FOR    ${id}    IN    @{vlans}
            ${prio}=    Evaluate    4096 + ${id}
            Should Match Regexp    ${root}    (?m)^VLAN0*${id}\\s+${prio}\\s+${STP_ROOT_MAC}\\s
        END
        ${bridge}=    Show    ${sw}    show spanning-tree bridge priority
        FOR    ${id}    IN    1    10    110    210
            ${own}=    Evaluate    ${STP_PRIORITY}[${sw}] + ${id}
            Should Match Regexp    ${bridge}    (?m)^VLAN0*${id}\\s+${own}\\s*$
        END
    END

Errdisable recovery for bpduguard is enabled
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${rec}=    Show    ${sw}    show errdisable recovery
        Should Match Regexp    ${rec}    (?m)^bpduguard\\s+Enabled
        Should Match Regexp    ${rec}    Timer interval: 300 seconds
    END

Service hygiene: timestamps, password encryption, login auditing
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${svc}=    Show    ${sw}    show run | include ^service|^login on
        Should Contain    ${svc}    service timestamps log datetime msec localtime show-timezone
        Should Contain    ${svc}    service password-encryption
        Should Contain    ${svc}    service tcp-keepalives-in
        Should Contain    ${svc}    login on-success log
        Should Contain    ${svc}    login on-failure log
        # a fresh SSH login must be audited in the syslog stream received by the NMS
        Nms Command    sshpass -p ${PASSWORD} ssh -o ConnectTimeout=10 ${sw} "show clock"
        Wait Until Keyword Succeeds    20s    2s    Nms Command    grep -q 'LOGIN_SUCCESS.*Source: ${NMS}[host]' /var/log/lab/${sw}.log
    END

*** Keywords ***
Deny Match Count
    [Documentation]    Sum of "(N matches)" on the deny lines of an ACL listing (0 when no counters yet).
    [Arguments]    ${acl_lines}
    ${nums}=    Get Regexp Matches    ${acl_lines}    \\((\\d+) match(?:es)?\\)    1
    ${total}=    Evaluate    sum(int(n) for n in ${nums})
    RETURN    ${total}
