*** Settings ***
Documentation     Management services delivered to/from the NMS: NTP, syslog, SNMP, banner, CDP/LLDP globals.
Resource          ../resources/common.resource
Suite Teardown    Suite Teardown Close Connections

*** Test Cases ***
NTP is configured against the NMS and the NMS serves time
    ${srv}=    Nms Command    sudo ss -ulnp | grep ':123 '
    Should Contain    ${srv}    chronyd
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${cfg}=    Show    ${sw}    show run | include ^ntp server
        Should Match Regexp    ${cfg}    ntp server vrf Mgmt-vrf ${NTP_SERVER}( prefer)?
        ${assoc}=    Show    ${sw}    show ntp associations
        Should Match Regexp    ${assoc}    (?m)^[ *+#x.o~-]*${NTP_SERVER}\\s
    END

NTP clock is synchronized to the NMS
    [Documentation]    Takes several minutes after the first apply; tagged so it can be excluded on a fresh lab.
    [Tags]    slow
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${st}=    Show    ${sw}    show ntp status | include Clock
        Should Contain    ${st}    Clock is synchronized
        Should Contain    ${st}    reference is ${NTP_SERVER}
    END

Syslog messages from the switches arrive on the NMS
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${cfg}=    Show    ${sw}    show run | include ^logging host
        Should Contain    ${cfg}    logging host ${SYSLOG_HOST} vrf Mgmt-vrf
        ${marker}=    Unique Marker    robot-${sw}
        Show    ${sw}    send log 6 ${marker}
        Wait Until Keyword Succeeds    20s    2s    Nms Command    grep -q ${marker} /var/log/lab/${sw}.log
    END

SNMP answers the NMS with the modelled identity
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${out}=    Nms Command    snmpget -v2c -c ${SNMP_COMMUNITY} -t 5 -r 2 ${sw} sysName.0 sysLocation.0 sysContact.0
        Should Contain    ${out}    sysName.0 = STRING: ${sw}.${DOMAIN_NAME}
        Should Contain    ${out}    sysLocation.0 = STRING: ${SNMP_LOCATION}
        Should Contain    ${out}    sysContact.0 = STRING: ${SNMP_CONTACT}
        ${cfg}=    Show    ${sw}    show run | include ^snmp-server host
        Should Match Regexp    ${cfg}    snmp-server host ${SYSLOG_HOST} vrf Mgmt-vrf version 2c \\S+
    END

Banner, CDP and LLDP are enabled
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        ${banner}=    Show    ${sw}    show run | section ^banner motd
        Should Contain    ${banner}    ${BANNER_TEXT}
        ${cdp}=    Show    ${sw}    show cdp | include enabled
        Should Contain    ${cdp}    Sending CDPv2 advertisements is enabled
        ${lldp}=    Show    ${sw}    show lldp | include Status
        Should Contain    ${lldp}    Status: ACTIVE
    END
