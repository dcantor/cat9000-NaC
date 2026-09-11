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

Peer prefixes are learned via iBGP and installed as B [200/0] routes
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${peer}=    Set Variable    ${SWITCHES}[${sw}][peer]
        ${routes}=    Show    ${sw}    show ip route bgp
        FOR    ${net}    IN    @{BGP_NETWORKS}[${peer}]
            Should Match Regexp    ${routes}    (?m)^B\\s+${net} \\[200/0\\] via ${SWITCHES}[${peer}][transit_ip]
        END
        ${ospf}=    Show    ${sw}    show ip route ospf | include ^O
        Should Be Empty    ${ospf.strip()}
    END

Inter-VLAN and loopback reachability across the trunk
    ${p}=    Show    sw1    ping 10.20.0.1 source 10.10.0.1 repeat 5
    Should Match Regexp    ${p}    Success rate is (100|80) percent
    ${p}=    Show    sw2    ping 10.10.0.1 source 10.20.0.1 repeat 5
    Should Match Regexp    ${p}    Success rate is (100|80) percent
    ${p}=    Show    sw1    ping 10.255.0.2 source Loopback0 repeat 5
    Should Match Regexp    ${p}    Success rate is (100|80) percent
