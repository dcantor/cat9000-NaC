*** Settings ***
Documentation     Shared settings for all cat9000v lab suites.
Library           LabLib.py
Variables         lab_vars.py
Library           Collections
Library           String

*** Keywords ***
Suite Teardown Close Connections
    Close All Connections

Switch Host
    [Arguments]    ${sw}
    ${host}=    Set Variable    ${SWITCHES}[${sw}][host]
    RETURN    ${host}

Show
    [Documentation]    Run a show command on a switch by name.
    [Arguments]    ${sw}    ${command}    ${timeout}=60
    ${host}=    Switch Host    ${sw}
    ${out}=    Run Command    ${host}    ${command}    ${timeout}
    RETURN    ${out}

Use Host Inventory From Nautobot
    [Documentation]    Replace the static HOSTS/HOST_PATH variables with what Nautobot models (source of truth).
    ${hosts}    ${path}=    Hosts From Nautobot
    Set Suite Variable    ${HOSTS}    ${hosts}
    Set Suite Variable    ${HOST_PATH}    ${path}
    ${names}=    Get Dictionary Keys    ${HOSTS}
    Set Suite Variable    ${HOST_NAMES}    ${names}
