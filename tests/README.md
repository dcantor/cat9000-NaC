# Robot Framework tests for the cat9000v lab

End-to-end validation of every feature the lab enables — run from the host
against the live topology (switches over SSH + RESTCONF, the NMS jumphost
over SSH, Terraform for drift detection).

```bash
../lab.sh test                      # or: tests/run.sh
../lab.sh test --exclude internet   # skip tests that need external connectivity
../lab.sh test --exclude slow       # skip NTP-sync (needs a few minutes after first apply)
../lab.sh test --suite 03_layer3    # one suite
../lab.sh test --test "*BGP*"      # matching tests only
```

`lab.sh test` creates the virtualenv on first use (`tests/setup.sh`,
packages in `requirements.txt`). Credentials default to `admin`/`admin`
and can be overridden with `IOSXE_USERNAME` / `IOSXE_PASSWORD`.

## Results

All results live in `results/`. Every run gets its own sub-folder named by
date and time, and `results/latest` points at the most recent one:

```
results/
└── 2026-09-11_06-42-52/
    ├── configs/
    │   ├── pre-run/                 running + startup config of sw1/sw2 before the tests
    │   ├── post-run/                the same after the tests — the config backup of record
    │   │   ├── sw1.running-config.txt
    │   │   ├── sw1.startup-config.txt
    │   │   ├── sw2.running-config.txt
    │   │   └── sw2.startup-config.txt
    │   └── pre-vs-post.diff         what the run changed (empty when nothing did)
    ├── report.html                  pass/fail summary
    ├── log.html                     every command and its output
    └── output.xml                   machine-readable (robot/rebot)
```

## Suites

| Suite | Covers |
|---|---|
| `01_management` | ICMP/SSH/RESTCONF/NETCONF reachability of each switch, Gi0/0 state, Mgmt-vrf reachability of the NMS, NMS on both networks with forwarding, NMS→switch SSH, internet via NMS NAT (`internet` tag) |
| `02_layer2` | Gi1/0/1 link up, VLAN database, trunk (native VLAN, allowed list, nonegotiate), access ports + portfast + bpduguard, rapid-PVST and trunk forwarding, CDP + LLDP neighbours |
| `03_layer3` | SVI/loopback addresses up/up, `ip routing`, BGP AS + router-id, iBGP session Established, advertised prefixes, export route-map filters the global session, tenant VRF (rd, its own iBGP session, routes, ping), HSRP active/standby per VLAN, inter-VLAN and loopback pings |
| `04_services` | NTP server config + association (+ synced, `slow` tag), syslog end-to-end (marker via `send log`, seen in `/var/log/lab/swN.log` on the NMS), SNMP identity queried from the NMS + trap host, banner, CDP/LLDP global |
| `06_vlans` | Routed VLANs 110-119: present on both switches, SVI up with the /24 gateway on the owning switch, originated into BGP by the owner, learned via iBGP on the other switch, gateway pingable across the trunk; L2 VLANs 210-219: present, no SVI, STP forwarding on the trunk; trunk allowed list |
| `07_hosts` | (inventory read from **Nautobot** at suite start) CirrOS hosts: OOB reachability + hostname, eth1 address and default route via the SVI, switch sees the host MAC/ARP on the right access port and VLAN, gateway ping, **host1 ↔ host2 ping through the switches (iBGP-routed)**, traceroute hops = sw1 SVI → sw2 transit SVI (never the OOB net), far-switch loopback and routed-VLAN gateways reachable |
| `08_hardening` | AAA parity (local login + exec authz on both), SSH v2/timeout/retries, VTY blocks SSH-only with `MGMT-ACCESS in vrf-also`, ACL admits the OOB net and **blocks SSH from a user VLAN** (host1 → SVI, deny counter increases), sw1 root / sw2 backup for every trunked VLAN, portfast + bpduguard defaults, errdisable recovery, service timestamps/password-encryption, login auditing seen in NMS syslog |
| `09_nautobot` | Nautobot health + worker, apps installed, every node a device, switch serial/type/mgmt IP match the live switches, VLAN group, trunk/access/SVI/cabling per switch, config context, **`devices.nac.yaml` == render from Nautobot**, Golden Config backups in Gitea, all compliance rows compliant, BGP objects and **live BGP sessions (global + VRF) match the modelled peerings**, services config context, VRF/HSRP/STP-tag/export-policy objects, and a **drift test**: one SNMP line changed out of band → Golden Config non-compliant with the right remediation → restored |
| `05_nac_compliance` | `terraform plan -detailed-exitcode` == 0 (device config matches the NAC data model), rendered model present |

Host credentials (`cirros`/`gocubsgo`) and attachments (`HOSTS`) are in
`resources/lab_vars.py` too — keep them in sync with `HOST_ATTACH` in `lab.conf`.

Expected values live in `resources/lab_vars.py` — update it alongside
`nac/data/*.nac.yaml` when the model changes. Keywords that talk to devices are
in `resources/LabLib.py` (`Run Command`, `Restconf Get`, `Nms Command`,
`Host Ping`, `Terraform Plan Exit Code`, …).
