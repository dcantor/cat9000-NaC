*** Settings ***
Documentation     CirrOS end hosts on switch access ports in different VLANs: attachment, gateway, and
...               host-to-host reachability routed through both switches (iBGP over the trunk).
Resource          ../resources/common.resource
Suite Teardown    Suite Teardown Close Connections

*** Test Cases ***
Hosts are reachable on the OOB network and identify themselves
    FOR    ${h}    ${host}    IN    &{HOSTS}
        Host Ping    ${host}[mgmt]
        ${name}=    Host Command    ${host}[mgmt]    hostname
        Should Be Equal    ${name.strip()}    ${h}
    END

Hosts have their VLAN address on eth1 and default route via the switch SVI
    FOR    ${h}    ${host}    IN    &{HOSTS}
        ${addr}=    Host Command    ${host}[mgmt]    ip addr show eth1
        Should Match Regexp    ${addr}    inet ${host}[ip]/24
        ${route}=    Host Command    ${host}[mgmt]    ip route
        Should Match Regexp    ${route}    (?m)^default via ${host}[gateway] dev eth1
    END

Switch sees each host on the right access port and VLAN
    FOR    ${h}    ${host}    IN    &{HOSTS}
        ${st}=    Show    ${host}[switch]    show interfaces status | include ${host}[port]${SPACE}
        Should Match Regexp    ${st}    ${host}[port]\\s.*\\sconnected\\s+${host}[vlan]\\s
        Host Command    ${host}[mgmt]    ping -c 2 -W 2 ${host}[gateway]
        ${mac}=    Show    ${host}[switch]    show mac address-table interface ${host}[port]
        Should Match Regexp    ${mac}    (?m)^\\s*${host}[vlan]\\s+${host}[mac]\\s+DYNAMIC\\s+${host}[port]
        ${arp}=    Show    ${host}[switch]    show ip arp ${host}[ip]
        Should Match Regexp    ${arp}    Internet\\s+${host}[ip]\\s+\\S+\\s+${host}[mac]\\s+ARPA\\s+Vlan${host}[vlan]
    END

Hosts can ping their local gateway
    FOR    ${h}    ${host}    IN    &{HOSTS}
        ${p}=    Host Command    ${host}[mgmt]    ping -c 3 -W 2 ${host}[gateway]
        Should Match Regexp    ${p}    3 packets transmitted, [23] received
    END

Hosts can ping each other across the switches
    FOR    ${h}    ${host}    IN    &{HOSTS}
        ${peer}=    Set Variable    ${HOSTS}[${host}[peer]]
        ${p}=    Host Command    ${host}[mgmt]    ping -c 5 -W 2 -I ${host}[ip] ${peer}[ip]
        Should Match Regexp    ${p}    5 packets transmitted, [45] received
    END

Host-to-host traffic is routed switch to switch, not over the OOB network
    FOR    ${h}    ${host}    IN    &{HOSTS}
        ${peer}=    Set Variable    ${HOSTS}[${host}[peer]]
        ${tr}=    Host Command    ${host}[mgmt]    traceroute -n -w 2 -q 1 ${peer}[ip]
        ${hops}=    Set Variable    ${HOST_PATH}[${h}]
        Should Match Regexp    ${tr}    (?m)^\\s*1\\s+${hops}[0]\\s
        Should Match Regexp    ${tr}    (?m)^\\s*2\\s+${hops}[1]\\s
        Should Match Regexp    ${tr}    (?m)^\\s*3\\s+${peer}[ip]\\s
        Should Not Contain    ${tr}    10.0.0.
    END

Hosts can reach the far switch's loopback and routed VLAN gateways
    FOR    ${h}    ${host}    IN    &{HOSTS}
        ${far}=    Set Variable    ${SWITCHES}[${host}[switch]][peer]
        ${p}=    Host Command    ${host}[mgmt]    ping -c 3 -W 2 ${SWITCHES}[${far}][router_id]
        Should Match Regexp    ${p}    3 packets transmitted, [23] received
    END
    ${p}=    Host Command    ${HOSTS}[host1][mgmt]    ping -c 3 -W 2 ${L3_VLANS}[119][gateway]
    Should Match Regexp    ${p}    3 packets transmitted, [23] received
    ${p}=    Host Command    ${HOSTS}[host2][mgmt]    ping -c 3 -W 2 ${L3_VLANS}[110][gateway]
    Should Match Regexp    ${p}    3 packets transmitted, [23] received
