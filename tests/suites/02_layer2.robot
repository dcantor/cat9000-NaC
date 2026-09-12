*** Settings ***
Documentation     Layer 2: VLAN database, inter-switch trunk, access ports, spanning tree, CDP/LLDP.
Resource          ../resources/common.resource
Suite Teardown    Suite Teardown Close Connections

*** Test Cases ***
Inter-switch links are up and bundled in the LACP port-channel
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        FOR    ${m}    IN    @{TRUNK_MEMBERS}
            ${st}=    Show    ${sw}    show interfaces status | include ${m}${SPACE}
            Should Match Regexp    ${st}    ${m}\\s.*\\sconnected\\s
        END
        ${ec}=    Show    ${sw}    show etherchannel summary | begin Group
        Should Match Regexp    ${ec}    (?m)^1\\s+${TRUNK_PORT}\\(SU\\)\\s+LACP\\s+Gi1/0/1\\(P\\)\\s+Gi1/0/5\\(P\\)
        ${st}=    Show    ${sw}    show interfaces status | include ${TRUNK_PORT}${SPACE}
        Should Match Regexp    ${st}    ${TRUNK_PORT}\\s.*\\sconnected\\s
    END

VLAN database matches the data model
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${brief}=    Show    ${sw}    show vlan brief
        FOR    ${id}    ${name}    IN    &{VLANS}
            Should Match Regexp    ${brief}    (?m)^${id}\\s+${name}\\s+active
        END
    END

Trunk port configuration
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${trunk}=    Show    ${sw}    show interfaces trunk
        Should Match Regexp    ${trunk}    (?m)^${TRUNK_PORT}\\s+on\\s+802\\.1q\\s+trunking\\s+${TRUNK_NATIVE_VLAN}\\s*$
        Should Match Regexp    ${trunk}    (?m)^${TRUNK_PORT}\\s+${TRUNK_ALLOWED_VLANS}\\s*$
        ${cfg}=    Show    ${sw}    show run interface ${TRUNK_PORT}
        Should Contain    ${cfg}    switchport nonegotiate
        FOR    ${m}    IN    @{TRUNK_MEMBERS}
            ${mcfg}=    Show    ${sw}    show run interface ${m}
            Should Contain    ${mcfg}    channel-group 1 mode active
        END
    END

Access ports are in the right VLANs with portfast and bpduguard
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        FOR    ${port}    ${vlan}    IN    &{ACCESS_PORTS}
            ${st}=    Show    ${sw}    show interfaces status | include ${port}${SPACE}
            Should Match Regexp    ${st}    ${port}\\s.*\\s(connected|notconnect)\\s+${vlan}\\s
            ${cfg}=    Show    ${sw}    show run interface ${port}
            Should Contain    ${cfg}    switchport mode access
            Should Contain    ${cfg}    switchport access vlan ${vlan}
            Should Match Regexp    ${cfg}    (?m)^ spanning-tree portfast( edge)?\\s*$
            Should Contain    ${cfg}    spanning-tree bpduguard enable
        END
    END

Spanning tree runs in rapid-pvst and the trunk is forwarding
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${sum}=    Show    ${sw}    show spanning-tree summary | include mode
        Should Contain    ${sum}    ${STP_MODE}
        ${stp}=    Show    ${sw}    show spanning-tree vlan 100 | include ${TRUNK_PORT}
        Should Match Regexp    ${stp}    ${TRUNK_PORT}\\s+(Root|Desg)\\s+FWD
    END

CDP and LLDP see the peer switch on every port-channel member
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${peer}=    Set Variable    ${SWITCHES}[${sw}][peer]
        ${cdp}=    Show    ${sw}    show cdp neighbors
        ${lldp}=    Show    ${sw}    show lldp neighbors
        FOR    ${m}    IN    @{TRUNK_MEMBERS}
            ${cdp_if}=    Replace String    ${m}    Gi    Gig${SPACE}
            Should Match Regexp    ${cdp}    ${peer}\\.${DOMAIN_NAME}\\s+${cdp_if}\\s.*${cdp_if}
            Should Match Regexp    ${lldp}    ${peer}\\.${DOMAIN_NAME}\\s+${m}\\s.*${m}
        END
    END

Unused ports are shut down and parked in the quarantine VLAN
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        FOR    ${port}    IN    @{UNUSED_PORTS}
            ${st}=    Show    ${sw}    show interfaces status | include ${port}${SPACE}
            Should Match Regexp    ${st}    ${port}\\s.*\\sdisabled\\s+${QUARANTINE_VLAN}\\s
        END
        ${trunk}=    Show    ${sw}    show interfaces trunk
        Should Not Match Regexp    ${trunk}    (?m)^${TRUNK_PORT}\\s+.*${QUARANTINE_VLAN}
    END
