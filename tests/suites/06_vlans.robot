*** Settings ***
Documentation     Routed (L3, /24 each) and layer-2-only VLANs added through the NAC data model.
Resource          ../resources/common.resource
Suite Teardown    Suite Teardown Close Connections

*** Test Cases ***
All routed and layer-2 VLANs exist on both switches
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${brief}=    Show    ${sw}    show vlan brief
        FOR    ${id}    ${vlan}    IN    &{L3_VLANS}
            Should Match Regexp    ${brief}    (?m)^${id}\\s+${vlan}[name]\\s+active
        END
        FOR    ${id}    ${name}    IN    &{L2_VLANS}
            Should Match Regexp    ${brief}    (?m)^${id}\\s+${name}\\s+active
        END
    END

Trunk carries every routed and layer-2 VLAN
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${trunk}=    Show    ${sw}    show interfaces trunk
        Should Match Regexp    ${trunk}    (?m)^${TRUNK_PORT}\\s+${TRUNK_ALLOWED_VLANS}\\s*$
        ${fwd}=    Get Lines Containing String    ${trunk}    ${TRUNK_PORT}
        ${last}=    Get Line    ${fwd}    -1
        Should Contain    ${last}    110-119
        Should Contain    ${last}    210-219
    END

Routed VLAN SVIs are up on their owning switch with the /24 gateway
    FOR    ${id}    ${vlan}    IN    &{L3_VLANS}
        ${brief}=    Show    ${vlan}[owner]    show ip interface brief | include Vlan${id}${SPACE}
        Should Match Regexp    ${brief}    (?m)^Vlan${id}\\s+${vlan}[gateway]\\s+YES\\s+\\S+\\s+up\\s+up
        ${ipif}=    Show    ${vlan}[owner]    show ip interface Vlan${id} | include Internet address|VPN Routing
        Should Contain    ${ipif}    Internet address is ${vlan}[gateway]/24
        Should Contain    ${ipif}    VPN Routing/Forwarding "${TENANT_VRF}"
    END

Routed VLAN subnets are originated into BGP by their owning switch
    FOR    ${id}    ${vlan}    IN    &{L3_VLANS}
        ${bgp}=    Show    ${vlan}[owner]    show bgp vpnv4 unicast vrf ${TENANT_VRF} ${vlan}[subnet]
        Should Contain    ${bgp}    BGP routing table entry for 65000:1:${vlan}[subnet]
        Should Contain    ${bgp}    Local
    END

Each switch learns the other switch's routed VLANs via iBGP
    FOR    ${id}    ${vlan}    IN    &{L3_VLANS}
        ${other}=    Set Variable    ${SWITCHES}[${vlan}[owner]][peer]
        ${via}=    Set Variable    ${SWITCHES}[${vlan}[owner]][tenant_transit_ip]
        ${route}=    Show    ${other}    show ip route vrf ${TENANT_VRF} ${vlan}[gateway]
        Should Contain    ${route}    Routing entry for ${vlan}[subnet]
        Should Contain    ${route}    Known via "bgp ${BGP_ASN}"
        Should Contain    ${route}    ${via}
    END

Every routed VLAN gateway is reachable from the other switch
    FOR    ${id}    ${vlan}    IN    &{L3_VLANS}
        ${other}=    Set Variable    ${SWITCHES}[${vlan}[owner]][peer]
        ${ping}=    Show    ${other}    ping vrf ${TENANT_VRF} ${vlan}[gateway] source Vlan101 repeat 3
        Should Match Regexp    ${ping}    Success rate is (100|66) percent
    END

Routed VLAN subnets are not leaked into the global table
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${glob}=    Show    ${sw}    show ip route | include ^[BCL].*10\\.11[0-9]\\.
        Should Be Empty    ${glob.strip()}
    END

Layer-2 VLANs have no SVI and are forwarding across the trunk
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${brief}=    Show    ${sw}    show ip interface brief | include ^Vlan
        FOR    ${id}    ${name}    IN    &{L2_VLANS}
            Should Not Match Regexp    ${brief}    (?m)^Vlan${id}\\s
            ${stp}=    Show    ${sw}    show spanning-tree vlan ${id} | include ${TRUNK_PORT}
            Should Match Regexp    ${stp}    ${TRUNK_PORT}\\s+(Root|Desg)\\s+FWD
        END
    END
