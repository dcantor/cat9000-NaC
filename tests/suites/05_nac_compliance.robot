*** Settings ***
Documentation     Configuration compliance: the switches match the Network-as-Code data model (no Terraform drift).
Resource          ../resources/common.resource
Library           OperatingSystem

*** Test Cases ***
Terraform plan reports no drift from the NAC data model
    [Tags]    nac
    ${rc}=    Terraform Plan Exit Code
    Should Be Equal As Integers    ${rc}    0    msg=terraform plan exit code ${rc} (0 = in sync, 2 = drift, 1 = error)

Rendered model was produced by the last plan
    [Tags]    nac
    File Should Exist    ${CURDIR}/../../nac/rendered-model.yaml
    ${model}=    Get File    ${CURDIR}/../../nac/rendered-model.yaml
    FOR    ${sw}    IN    @{SWITCH_NAMES}
        Should Match Regexp    ${model}    "?name"?: "?${sw}"?
    END
