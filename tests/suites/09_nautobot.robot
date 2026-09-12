*** Settings ***
Documentation     Nautobot on the NMS: service health, apps, and the lab as modelled in it — Nautobot is the
...               source of truth for nac/data/devices.nac.yaml and must match both that file and the devices.
Resource          ../resources/common.resource
Suite Teardown    Suite Teardown Close Connections

*** Test Cases ***
Nautobot is healthy with a Celery worker
    ${st}=    Nautobot Get    status/
    Should Match Regexp    ${st}[nautobot-version]    ^3\\.
    Should Be True    ${st}[celery-workers-running] >= 1

Lab apps are installed
    ${st}=    Nautobot Get    status/
    FOR    ${app}    IN    nautobot_device_onboarding    nautobot_golden_config    nautobot_plugin_nornir    nautobot_ssot
        Dictionary Should Contain Key    ${st}[installed-apps]    ${app}
    END

Every lab node is a device in the lab location
    FOR    ${node}    IN    sw1    sw2    host1    host2    nms
        ${r}=    Nautobot Get    dcim/devices/    name=${node}    depth=1
        Should Be Equal As Integers    ${r}[count]    1    msg=${node} missing in Nautobot
        Should Be Equal    ${r}[results][0][location][name]    cat9000v-lab
    END

Switch identity in Nautobot matches the running switches
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${d}=    Nautobot Get    dcim/devices/    name=${sw}    depth=1
        ${dev}=    Set Variable    ${d}[results][0]
        Should Be Equal    ${dev}[device_type][model]    C9KV-UADP-8P
        Should Be Equal    ${dev}[primary_ip4][host]    ${SWITCHES}[${sw}][host]
        ${ver}=    Show    ${sw}    show version | include System Serial Number|Model Number
        Should Contain    ${ver}    ${dev}[serial]
        Should Be Equal    ${dev}[software_version][version]    ${SOFTWARE_VERSION}
        ${run}=    Show    ${sw}    show version | include ^Cisco IOS XE Software
        # IOS prints 17.18.02, Nautobot stores 17.18.2 — compare numerically per field
        ${ios}=    Get Regexp Matches    ${run}    Version (\\S+)    1
        ${norm}=    Evaluate    ".".join(str(int(x)) for x in "${ios}[0]".split("."))
        Should Be Equal    ${norm}    ${SOFTWARE_VERSION}
    END

Services and OOB settings come from the lab-services config context
    ${d}=    Nautobot Graphql    { devices(role:"core-switch") { name config_context interfaces(name:"GigabitEthernet0/0") { vrf { name } ip_addresses { address } } } }
    FOR    ${dev}    IN    @{d}[devices]
        ${cc}=    Set Variable    ${dev}[config_context]
        Should Be Equal    ${cc}[domain_name]    ${DOMAIN_NAME}
        Should Be Equal    ${cc}[oob][vrf]    Mgmt-vrf
        Should Be Equal    ${cc}[oob][gateway]    ${NMS}[host]
        Should Be Equal    ${cc}[oob][acl]    ${MGMT_ACL}
        Should Be Equal    ${cc}[ntp_servers][0][ip]    ${NTP_SERVER}
        Should Be Equal    ${cc}[syslog_hosts][0]    ${SYSLOG_HOST}
        Should Be Equal    ${cc}[snmp][community]    ${SNMP_COMMUNITY}
        Should Be Equal    ${cc}[snmp][location]    ${SNMP_LOCATION}
        Should Be Equal    ${dev}[interfaces][0][vrf][name]    Mgmt-vrf
        Should Be Equal    ${dev}[interfaces][0][ip_addresses][0][address]    ${SWITCHES}[${dev}[name]][host]/24
    END

VLAN group holds the modelled VLANs
    ${vg}=    Nautobot Graphql    { vlan_groups(name:"cat9000v-lab") { vlans { vid name } } }
    ${got}=    Create Dictionary
    FOR    ${v}    IN    @{vg}[vlan_groups][0][vlans]
        ${vid}=    Convert To String    ${v}[vid]
        Set To Dictionary    ${got}    ${vid}    ${v}[name]
    END
    Dictionaries Should Be Equal    ${got}    ${VLANS}

Trunk, access ports, SVIs and cabling are modelled per switch
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${d}=    Nautobot Graphql    { devices(name:"${sw}") { interfaces { name mode lag { name } untagged_vlan { vid } tagged_vlans { vid } ip_addresses { address } connected_interface { name device { name } } } } }
        ${ifs}=    Create Dictionary
        FOR    ${i}    IN    @{d}[devices][0][interfaces]
            Set To Dictionary    ${ifs}    ${i}[name]    ${i}
        END
        Should Be Equal    ${ifs}[Port-channel1][mode]    TAGGED
        Should Be Equal As Integers    ${ifs}[Port-channel1][untagged_vlan][vid]    ${TRUNK_NATIVE_VLAN}
        Length Should Be    ${ifs}[Port-channel1][tagged_vlans]    23
        FOR    ${m}    IN    @{TRUNK_MEMBERS}
            ${name}=    Replace String    ${m}    Gi    GigabitEthernet
            Should Be Equal    ${ifs}[${name}][lag][name]    Port-channel1
            Should Be Equal    ${ifs}[${name}][connected_interface][device][name]    ${SWITCHES}[${sw}][peer]
            Should Be Equal    ${ifs}[${name}][connected_interface][name]    ${name}
        END
        FOR    ${port}    ${vlan}    IN    &{ACCESS_PORTS}
            ${name}=    Replace String    ${port}    Gi    GigabitEthernet
            Should Be Equal    ${ifs}[${name}][mode]    ACCESS
            Should Be Equal As Integers    ${ifs}[${name}][untagged_vlan][vid]    ${vlan}
        END
        FOR    ${svi}    ${ip}    IN    &{SWITCHES}[${sw}][svis]
            Should Start With    ${ifs}[${svi}][ip_addresses][0][address]    ${ip}/
        END
        Should Be Equal    ${ifs}[Loopback0][ip_addresses][0][address]    ${SWITCHES}[${sw}][router_id]/32
    END
    FOR    ${h}    ${host}    IN    &{HOSTS}
        ${d}=    Nautobot Graphql    { devices(name:"${h}") { interfaces(name:"eth1") { connected_interface { name device { name } } ip_addresses { address } } } }
        ${e1}=    Set Variable    ${d}[devices][0][interfaces][0]
        Should Be Equal    ${e1}[connected_interface][device][name]    ${host}[switch]
        ${port}=    Replace String    ${host}[port]    Gi    GigabitEthernet
        Should Be Equal    ${e1}[connected_interface][name]    ${port}
        Should Be Equal    ${e1}[ip_addresses][0][address]    ${host}[ip]/24
    END

Config context carries the routing and STP intent
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${d}=    Nautobot Graphql    { devices(name:"${sw}") { local_config_context_data } }
        ${ctx}=    Set Variable    ${d}[devices][0][local_config_context_data]
        Should Be Equal As Integers    ${ctx}[bgp][asn]    ${BGP_ASN}
        Should Be Equal As Integers    ${ctx}[stp_priority]    ${STP_PRIORITY}[${sw}]
    END

NAC device model rendered from Nautobot matches the committed file
    [Tags]    nac
    ${rc}=    Render Nac Check
    Should Be Equal As Integers    ${rc}    0    msg=nac/data/devices.nac.yaml differs from Nautobot — run ./lab.sh nautobot render

Golden Config: backups of both switches are in the lab Gitea
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${r}=    Nms Command    curl -sf http://localhost:3000/api/v1/repos/lab/config-backups/raw/${sw}.cfg
        Should Contain    ${r}    hostname ${sw}
        Should Contain    ${r}    router bgp ${BGP_ASN}
    END

Golden Config: every switch is compliant with the Nautobot-rendered intent
    ${cc}=    Nautobot Get    plugins/golden-config/config-compliance/    limit=100
    Should Be True    ${cc}[count] >= 22    msg=expected at least 11 features x 2 devices, got ${cc}[count]
    FOR    ${row}    IN    @{cc}[results]
        Should Be True    ${row}[compliance]    msg=non-compliant: ${row}[device] ${row}[rule] missing=${row}[missing] extra=${row}[extra]
    END

BGP is modelled: AS, routing instances, peering and advertised prefixes
    ${d}=    Nautobot Graphql    { bgp_routing_instances { device { name } autonomous_system { asn } router_id { address } endpoints { enabled source_ip { address } peer { source_ip { address } autonomous_system { asn } routing_instance { device { name } } } } } prefixes(tags:"bgp:advertise") { prefix } }
    Length Should Be    ${d}[bgp_routing_instances]    2
    FOR    ${ri}    IN    @{d}[bgp_routing_instances]
        ${sw}=    Set Variable    ${ri}[device][name]
        Should Be Equal As Integers    ${ri}[autonomous_system][asn]    ${BGP_ASN}
        Should Be Equal    ${ri}[router_id][address]    ${SWITCHES}[${sw}][router_id]/32
        Length Should Be    ${ri}[endpoints]    1
        ${ep}=    Set Variable    ${ri}[endpoints][0]
        Should Start With    ${ep}[source_ip][address]    ${SWITCHES}[${sw}][transit_ip]/
        Should Be Equal    ${ep}[peer][routing_instance][device][name]    ${SWITCHES}[${sw}][peer]
        Should Start With    ${ep}[peer][source_ip][address]    ${SWITCHES}[${SWITCHES}[${sw}][peer]][transit_ip]/
    END
    ${adv}=    Create List
    FOR    ${p}    IN    @{d}[prefixes]
        Append To List    ${adv}    ${p}[prefix]
    END
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        FOR    ${net}    IN    @{BGP_NETWORKS}[${sw}]
            List Should Contain Value    ${adv}    ${net}    msg=${net} not tagged bgp:advertise in Nautobot
        END
    END

Live BGP sessions match the peerings modelled in Nautobot
    ${d}=    Nautobot Graphql    { bgp_routing_instances { device { name } endpoints { peer { source_ip { address } autonomous_system { asn } } } } }
    FOR    ${ri}    IN    @{d}[bgp_routing_instances]
        ${sw}=    Set Variable    ${ri}[device][name]
        ${sum}=    Show    ${sw}    show bgp ipv4 unicast summary | begin Neighbor
        FOR    ${ep}    IN    @{ri}[endpoints]
            ${peer_ip}=    Fetch From Left    ${ep}[peer][source_ip][address]    /
            Should Match Regexp    ${sum}    (?m)^${peer_ip}\\s+4\\s+${ep}[peer][autonomous_system][asn]\\s+.*\\s\\d+\\s*$    msg=${sw}: session to ${peer_ip} not Established
        END
    END
