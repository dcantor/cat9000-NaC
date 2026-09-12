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
        Should Match Regexp    ${tr}    (?m)^\\s*2\\s+${peer}[ip]\\s
        Should Not Contain    ${tr}    10.0.0.
    END

Hosts can reach both switch loopbacks but not the tenant VRF
    FOR    ${h}    ${host}    IN    &{HOSTS}
        FOR    ${sw}    IN    @{SWITCH_NAMES}
            ${p}=    Host Command    ${host}[mgmt]    ping -c 3 -W 2 ${SWITCHES}[${sw}][router_id]
            Should Match Regexp    ${p}    3 packets transmitted, [23] received
        END
        # the routed VLANs live in TENANT-A: unreachable from the global table by design
        ${rc}=    Host Command Rc    ${host}[mgmt]    ping -c 2 -W 2 ${L3_VLANS}[110][gateway]
        Should Not Be Equal As Integers    ${rc}    0    msg=tenant VRF leaked into the global table
    END

Hosts resolve their gateway to the HSRP virtual MAC
    [Documentation]    HSRPv2 vMAC is 0000.0c9f.fXXX with XXX = group number; the hosts must ARP the VIP, not a real SVI.
    FOR    ${h}    ${host}    IN    &{HOSTS}
        Host Command    ${host}[mgmt]    ping -c 1 -W 2 ${host}[gateway]
        ${neigh}=    Host Command    ${host}[mgmt]    ip neigh show ${host}[gateway]
        ${hexgrp}=    Evaluate    "%03x" % int("${host}[vlan]")
        ${vmac}=    Set Variable    00:00:0c:9f:f${hexgrp[0]}:${hexgrp[1:]}
        Should Contain    ${neigh}    ${vmac}    ignore_case=True
    END
