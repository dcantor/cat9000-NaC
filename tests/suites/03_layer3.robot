*** Settings ***
Documentation     Layer 3: SVIs, loopbacks, iBGP (single AS) peering and routing, inter-VLAN reachability.
Resource          ../resources/common.resource
Suite Teardown    Suite Teardown Close Connections

*** Test Cases ***
SVIs and loopbacks are up with the modelled addresses
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${brief}=    Show    ${sw}    show ip interface brief
        Should Match Regexp    ${brief}    (?m)^Loopback0\\s+${SWITCHES}[${sw}][router_id]\\s+YES\\s+\\S+\\s+up\\s+up
        FOR    ${svi}    ${ip}    IN    &{SWITCHES}[${sw}][svis]
            Should Match Regexp    ${brief}    (?m)^${svi}\\s+${ip}\\s+YES\\s+\\S+\\s+up\\s+up
        END
    END

IP routing is enabled
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${cfg}=    Show    ${sw}    show run | include ^ip routing|^no ip routing
        Should Not Contain    ${cfg}    no ip routing
    END

BGP runs in the single modelled AS with the loopback router-id
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${cfg}=    Show    ${sw}    show run | section ^router bgp
        Should Match Regexp    ${cfg}    (?m)^router bgp ${BGP_ASN}$
        Should Contain    ${cfg}    bgp router-id ${SWITCHES}[${sw}][router_id]
        Should Contain    ${cfg}    bgp log-neighbor-changes
        ${sum}=    Show    ${sw}    show bgp ipv4 unicast summary
        Should Contain    ${sum}    local AS number ${BGP_ASN}
        Should Contain    ${sum}    BGP router identifier ${SWITCHES}[${sw}][router_id]
    END

iBGP session to the peer is Established over the transit VLAN
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${peer}=    Set Variable    ${SWITCHES}[${sw}][peer]
        ${nbr}=    Show    ${sw}    show bgp ipv4 unicast neighbors ${SWITCHES}[${peer}][transit_ip]
        Should Contain    ${nbr}    remote AS ${BGP_ASN}, internal link
        Should Contain    ${nbr}    BGP state = Established
        ${sum}=    Show    ${sw}    show bgp ipv4 unicast summary | begin Neighbor
        # State/PfxRcd column must be a prefix count (Established), not a state name
        Should Match Regexp    ${sum}    (?m)^${SWITCHES}[${peer}][transit_ip]\\s+4\\s+${BGP_ASN}\\s+.*\\s\\d+\\s*$
    END

Each switch originates its loopback and gateway VLANs into BGP
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${peer}=    Set Variable    ${SWITCHES}[${sw}][peer]
        ${adv}=    Show    ${sw}    show bgp ipv4 unicast neighbors ${SWITCHES}[${peer}][transit_ip] advertised-routes
        FOR    ${net}    IN    @{BGP_NETWORKS}[${sw}]
            Should Match Regexp    ${adv}    (?m)^\\s*\\*>\\s+${net}\\s
        END
    END

Peer loopback is learned via iBGP and installed as a B [200/0] route
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${peer}=    Set Variable    ${SWITCHES}[${sw}][peer]
        ${routes}=    Show    ${sw}    show ip route bgp
        Should Match Regexp    ${routes}    (?m)^B\\s+${SWITCHES}[${peer}][router_id]/32 \\[200/0\\] via ${SWITCHES}[${peer}][transit_ip]
        ${ospf}=    Show    ${sw}    show ip route ospf | include ^O
        Should Be Empty    ${ospf.strip()}
    END

Global iBGP export is filtered by the modelled route-map
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${peer}=    Set Variable    ${SWITCHES}[${sw}][peer]
        ${cfg}=    Show    ${sw}    show run | section ^router bgp|^route-map|^ip prefix-list
        Should Contain    ${cfg}    neighbor ${SWITCHES}[${peer}][transit_ip] route-map ${BGP_EXPORT_POLICY} out
        Should Match Regexp    ${cfg}    (?m)^route-map ${BGP_EXPORT_POLICY} permit 10\\s*$
        ${adv}=    Show    ${sw}    show bgp ipv4 unicast neighbors ${SWITCHES}[${peer}][transit_ip] advertised-routes
        ${count}=    Get Count    ${adv}    *>
        Should Be Equal As Integers    ${count}    ${{ len($BGP_NETWORKS[$sw]) }}    msg=export filter leaks prefixes
    END

Tenant VRF has its own iBGP session and routes
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${peer}=    Set Variable    ${SWITCHES}[${sw}][peer]
        ${vrf}=    Show    ${sw}    show vrf ${TENANT_VRF}
        Should Match Regexp    ${vrf}    (?m)^\\s*${TENANT_VRF}\\s+65000:1\\s+ipv4
        ${sum}=    Show    ${sw}    show bgp vpnv4 unicast vrf ${TENANT_VRF} summary | begin Neighbor
        Should Match Regexp    ${sum}    (?m)^${SWITCHES}[${peer}][tenant_transit_ip]\\s+4\\s+${BGP_ASN}\\s+.*\\s\\d+\\s*$
        ${routes}=    Show    ${sw}    show ip route vrf ${TENANT_VRF} bgp
        FOR    ${net}    IN    @{BGP_VRF_NETWORKS}[${peer}]
            Should Match Regexp    ${routes}    (?m)^B\\s+${net} \\[200/0\\] via ${SWITCHES}[${peer}][tenant_transit_ip]
        END
        ${p}=    Show    ${sw}    ping vrf ${TENANT_VRF} ${SWITCHES}[${peer}][tenant_transit_ip] source Vlan101 repeat 3
        Should Match Regexp    ${p}    Success rate is (100|66) percent
    END

HSRP provides the host VLAN gateways with the modelled active switch
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${sb}=    Show    ${sw}    show standby brief | begin Interface
        FOR    ${vid}    ${h}    IN    &{HSRP}
            ${state}=    Set Variable If    '${h}[active]' == '${sw}'    Active    Standby
            Should Match Regexp    ${sb}    (?m)^Vl${vid}\\s+${vid}\\s+\\d+\\s+P\\s+${state}\\s.*\\s${h}[vip]\\s*$
        END
    END

Inter-VLAN and loopback reachability across the trunk
    # first replies can be lost to ARP resolution across the trunk: accept >= 60 %
    ${p}=    Show    sw1    ping 10.20.0.2 source 10.10.0.2 repeat 5
    Should Match Regexp    ${p}    Success rate is (100|80|60) percent
    ${p}=    Show    sw2    ping 10.10.0.2 source 10.20.0.2 repeat 5
    Should Match Regexp    ${p}    Success rate is (100|80|60) percent
    ${p}=    Show    sw1    ping 10.255.0.2 source Loopback0 repeat 5
    Should Match Regexp    ${p}    Success rate is (100|80) percent
