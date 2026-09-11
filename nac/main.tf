# Cisco Network-as-Code for the cat9000v lab.
#
# The netascode/nac-iosxe module reads the YAML data model in ./data, merges
# global -> device_groups -> devices, and maps it onto CiscoDevNet/iosxe
# provider resources.
#
# Transport: RESTCONF (HTTPS). Module 1.0.0 / provider 1.0.0 are NETCONF-only
# and always <lock> the running datastore, which fails with "application error"
# on Cat9kv 17.18.2 (see ../README.md). Module 0.1.0 pins provider 0.15.0,
# which supports `protocol: restconf` per device in the data model.
#
# Credentials come from the environment (see ../lab.sh nac-env):
#   export IOSXE_USERNAME=admin IOSXE_PASSWORD=admin

module "iosxe" {
  source  = "netascode/nac-iosxe/iosxe"
  version = "0.1.0"

  yaml_directories = ["data"]

  # Not using the module's save_config: with provider 0.15 the iosxe_commit
  # resource shows a permanent "save_config = false -> true" diff. lab.sh nac
  # apply saves via the RESTCONF cisco-ia:save-config RPC instead.
  save_config = false

  # dump the fully merged/rendered model for inspection (git-ignored)
  write_model_file = "rendered-model.yaml"
}
