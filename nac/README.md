# Network-as-Code for the cat9000v lab

Cisco [Network as Code](https://netascode.cisco.com) drives the two switches
from a YAML data model via Terraform:

```
data/*.nac.yaml  ──▶  netascode/nac-iosxe/iosxe module  ──▶  CiscoDevNet/iosxe provider  ──▶  RESTCONF  ──▶  sw1, sw2
```

## Run it

```bash
../lab.sh nac init            # once
../lab.sh nac plan
../lab.sh nac apply           # also saves running-config -> startup-config on both switches
```

`lab.sh nac` exports `IOSXE_USERNAME`/`IOSXE_PASSWORD` (default `admin`/`admin`,
override in the environment) and runs `terraform` inside this directory.

## Data model

| File | Scope | Content |
|---|---|---|
| `data/global.nac.yaml` | all devices (lowest precedence) | variables (`nms_ip`, `domain_name`, …), domain, `ip routing`, CDP/LLDP, rapid-PVST with portfast/bpduguard defaults, **AAA** (local login + exec authorization), **SSH hardening**, `MGMT-ACCESS` ACL on the VTYs (`vrf-also`), service timestamps/password-encryption/login auditing, NTP + syslog + SNMP traps to the NMS jumphost, MOTD banner, an `errdisable_recovery` CLI template |
| `data/device_groups.nac.yaml` | group `CORE_SWITCHES` | VLANs 10/20/99/100, routed VLANs 110-119 (`L3-nnn`), layer-2 VLANs 210-219 (`L2-nnn`), `Gi1/0/1` trunk (native 99, allowed 10,20,100,110-119,210-219), access ports `Gi1/0/2-4`, transit SVI `Vlan100`, `Loopback0`, BGP AS 65000 with an iBGP neighbor `${peer_transit_ip}` |
| `data/devices.nac.yaml` | per device (highest precedence) | host/protocol, `router_id` / `transit_ip` / `peer_transit_ip` variables, STP priorities (sw1 4096 = root, sw2 8192), sw1 = gateways for `Vlan10` and `Vlan110-114`, sw2 = gateways for `Vlan20` and `Vlan115-119` (each `10.<vlan>.0.1/24`), and the BGP `network` statements each switch originates (its loopback + its gateway VLANs) |

Values written as `${name}` are resolved from `variables:` at any level
(device overrides group overrides global). Lists keyed by `id`/`name` are
merged across levels, so a device can add its own SVIs and BGP `network`
statements on top of the group's.

The resulting topology:

```
 sw1                                     sw2
 Lo0 10.255.0.1/32 (RID)                 Lo0 10.255.0.2/32 (RID)
 Vlan10 10.10.0.1/24  USERS gw           Vlan20 10.20.0.1/24  SERVERS gw
 Vlan110-114 10.11x.0.1/24 gateways     Vlan115-119 10.11x.0.1/24 gateways
 Vlan100 10.100.0.1/30 ═══ iBGP AS 65000 ═══ Vlan100 10.100.0.2/30
 Gi1/0/1 trunk (native 99; 10,20,100,110-119,210-219) ─── Gi1/0/1
 VLANs 210-219: layer-2 only, bridged over the trunk, no SVI
 Gi1/0/2-3 access 10, Gi1/0/4 access 20  (portfast + bpduguard)
```

`rendered-model.yaml` (git-ignored) is the fully merged model after every
plan/apply — the quickest way to see what a device will actually get.

## Versions and why

| Component | Version | Reason |
|---|---|---|
| `netascode/nac-iosxe/iosxe` | **0.1.0** | 1.0.0 requires provider 1.0.0 |
| `CiscoDevNet/iosxe` | **0.15.0** (pinned by the module) | last line that supports **RESTCONF** |
| transport | RESTCONF (`protocol: restconf` per device) | see below |

Provider 1.0.0 is NETCONF-only and unconditionally sends `<lock><target><running/>`
before every write. On this Cat9kv 17.18.2 image that RPC always returns
`operation-failed / application error` (reproduced with ncclient; `edit-config`
without a lock works fine). It is not fixed by `aaa new-model` + exec
authorization, `netconf-yang feature candidate-datastore`, a config `archive`,
`clear configuration lock`, or a reboot — DMI's internal session runs
`configure terminal lock` successfully and then aborts. Until a fixed image is
available, RESTCONF via provider 0.15 is the working path. To try NETCONF
again later: set `version = "1.0.0"` in `main.tf`, drop the `= 0.15.0` pin in
`versions.tf`, remove `protocol:` from the devices, and `terraform init -upgrade`.

Both `netconf-yang` and `restconf` stay enabled on the switches (`nodes/sw*/iosxe_config.txt`).

### Data-model differences in module 0.1.0

- Trunk allowed VLANs use the object form:
  `trunk_allowed_vlans: { vlans: { ids: [10, 20, 100], ranges: [{from: 200, to: 210}] } }`
  (the flat list form of 1.0.0 is silently ignored).
- OSPF (used before the switch to BGP) has `passive_interfaces` but no
  `non_passive_interfaces` in this version.
- BGP networks with a mask go in `address_family.ipv4_unicast.networks` as
  `{network, mask}` objects (rendered as `network X mask Y`).
- **`netconf-yang feature candidate-datastore` must be off** when using RESTCONF.
  With it enabled, RESTCONF PATCHes land in the candidate datastore and the
  provider sees `malformed-message` errors, writes that never return, and
  `%DMI-4-CANDIDATE_DATASTORE_DIRTY` in the log. (sw2 had it on from an earlier
  NETCONF experiment; that was the source of a day of odd asymmetric behaviour.)
- **AAA ordering:** the module creates `iosxe_aaa` (`aaa new-model`) and the
  authentication/authorization method lists as separate resources with no
  dependency. If `aaa new-model` lands and the method lists fail, IOS-XE denies
  RESTCONF (`access-denied`) and Terraform can no longer fix it — recover over
  SSH (`aaa authentication login default local` / `aaa authorization exec
  default local`). Day-0 (`iosxe_config.txt`) now carries the same three lines
  so a reload can never regress it.
- `errdisable` is driven by a CLI template, not `iosxe_errdisable`: a write to
  `/native/errdisable` breaks later reads of that subtree on this image
  (`no registration found for callpoint ec_genet_deprecated`).
- `spanning_tree.vlans` uses one `{id, priority}` entry per VLAN — IOS reports
  priorities per VLAN, so a range like `"1-4094"` (which also wedges the DMI
  transaction on Cat9kv) or a list string never matches on refresh.
- `line.vtys` is modelled as two blocks (`0-4`, `5-15`), the way IOS reports
  `line vty 0 15` back.
- The module's `save_config` is left `false`: with provider 0.15 the
  `iosxe_commit` resource re-plans `save_config = false -> true` on every run.
  `lab.sh nac apply` saves through the `cisco-ia:save-config` RESTCONF RPC instead.

## Adding to the model

Anything the module supports (see the `iosxe_*.tf` files in
`.terraform/modules/iosxe/` after `init`, or the
[data model reference](https://netascode.cisco.com/docs/data_models/iosxe/overview/))
can be added to the YAML. Typical next steps: eBGP/EVPN, port-channels between
the switches (`port_channel_id`/`port_channel_mode` on the ethernets plus
`interfaces.port_channels`), `cli_templates` for anything not modelled.
