*** Settings ***
Documentation     Out-of-band management plane: reachability, SSH, RESTCONF, NETCONF, NMS jumphost, Mgmt-vrf routing.
Resource          ../resources/common.resource
Suite Teardown    Suite Teardown Close Connections
Test Template     Verify Management Access

*** Test Cases ***                  sw
sw1 management plane                sw1
sw2 management plane                sw2

*** Keywords ***
Verify Management Access
    [Arguments]    ${sw}
    ${host}=    Switch Host    ${sw}
    Host Ping    ${host}
    Tcp Port Should Be Open    ${host}    22
    Tcp Port Should Be Open    ${host}    830
    Tcp Port Should Be Open    ${host}    443
    ${ver}=    Show    ${sw}    show version | include uptime
    Should Contain    ${ver}    ${sw} uptime
    ${json}=    Restconf Get    ${host}    Cisco-IOS-XE-native:native/hostname
    Should Be Equal    ${json}[Cisco-IOS-XE-native:hostname]    ${sw}
    ${mgmt}=    Show    ${sw}    show ip interface brief | include GigabitEthernet0/0
    Should Match Regexp    ${mgmt}    GigabitEthernet0/0\\s+${host}\\s+YES\\s+\\S+\\s+up\\s+up
    ${ping}=    Show    ${sw}    ping vrf Mgmt-vrf ${NMS}[host] repeat 3
    Should Match Regexp    ${ping}    Success rate is (100|66) percent
    ${dom}=    Show    ${sw}    show run | include ^ip domain name
    Should Contain    ${dom}    ${DOMAIN_NAME}

*** Test Cases ***
NMS jumphost is reachable and on both networks
    [Template]    NONE
    Host Ping    ${NMS}[host]
    ${ip}=    Nms Command    ip -br addr show eth1
    Should Contain    ${ip}    ${NMS}[host]/24
    ${fwd}=    Nms Command    sysctl -n net.ipv4.ip_forward
    Should Be Equal As Integers    ${fwd}    1

NMS jumphost can SSH and SNMP to the switches
    [Template]    NONE
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${out}=    Nms Command    sshpass -p ${PASSWORD} ssh -o ConnectTimeout=10 ${sw} "show clock"
        Should Match Regexp    ${out}    \\d\\d:\\d\\d:\\d\\d
    END

Switches reach the internet through the NMS NAT
    [Template]    NONE
    [Tags]    internet
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${ping}=    Show    ${sw}    ping vrf Mgmt-vrf 8.8.8.8 repeat 3
        Should Match Regexp    ${ping}    Success rate is (100|66) percent
    END
