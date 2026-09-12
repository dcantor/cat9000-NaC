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
        ${d}=    Nautobot Graphql    { devices(name:"${sw}") { interfaces { name mode untagged_vlan { vid } tagged_vlans { vid } ip_addresses { address } connected_interface { name device { name } } } } }
        ${ifs}=    Create Dictionary
        FOR    ${i}    IN    @{d}[devices][0][interfaces]
            Set To Dictionary    ${ifs}    ${i}[name]    ${i}
        END
        Should Be Equal    ${ifs}[GigabitEthernet1/0/1][mode]    TAGGED
        Should Be Equal As Integers    ${ifs}[GigabitEthernet1/0/1][untagged_vlan][vid]    ${TRUNK_NATIVE_VLAN}
        Length Should Be    ${ifs}[GigabitEthernet1/0/1][tagged_vlans]    23
        Should Be Equal    ${ifs}[GigabitEthernet1/0/1][connected_interface][device][name]    ${SWITCHES}[${sw}][peer]
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
    Should Be True    ${cc}[count] >= 6    msg=expected at least 3 features x 2 devices, got ${cc}[count]
    FOR    ${row}    IN    @{cc}[results]
        Should Be True    ${row}[compliance]    msg=non-compliant: ${row}[device] ${row}[rule] missing=${row}[missing] extra=${row}[extra]
    END
