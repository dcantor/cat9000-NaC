# Catalyst 9000v network lab (libvirt/KVM)

Two Cisco Catalyst 9000v switches connected back-to-back, a CirrOS end host
on each switch (in different VLANs), plus an Ubuntu NMS/jumphost — all on an
out-of-band management network.

```
 host (10.0.0.1)                     internet
      │                                 │  (libvirt "default" NAT, 192.168.122.0/24)
      │                              eth0│
      │                             ┌────┴────┐
      │                             │   nms   │  Ubuntu 24.04 jumphost / NMS
      │                             │10.0.0.10│  NAT gateway for the switches
      │                             └────┬────┘
      │                              eth1│
 ═════╧══════════ oob-mgmt  10.0.0.0/24 ═╧════════════════════════════
              │ Gi0/0 (Mgmt-vrf)                     │ Gi0/0 (Mgmt-vrf)
         ┌────┴────┐                            ┌────┴────┐
         │   sw1   │ Gi1/0/1 ══════════ Gi1/0/1 │   sw2   │
         │10.0.0.11│ Gi1/0/5 ══ Po1 (LACP) ═══ Gi1/0/5 │10.0.0.12│
         └────┬────┘                            └────┬────┘
              │ Gi1/0/2  access VLAN 10             │ Gi1/0/4  access VLAN 20
         ┌────┴────┐                            ┌────┴────┐
         │  host1  │ 10.10.0.100/24  (CirrOS)   │  host2  │ 10.20.0.100/24  (CirrOS)
         │10.0.0.21│ gw 10.10.0.1 (sw1 Vlan10)  │10.0.0.22│ gw 10.20.0.1 (sw2 Vlan20)
         └─────────┘                            └─────────┘
```

host1 ↔ host2 traffic is routed sw1 → (iBGP AS 65000 over Vlan100 on the trunk) → sw2;
the hosts' OOB NICs (eth0) are only for SSH access from the host/NMS.

## Quick start

```bash
./lab.sh up               # define networks + nodes, start everything
./lab.sh bootstrap        # wait for the switches to boot, generate SSH keys (first boot only)
./lab.sh status
./lab.sh ssh nms          # lab / lab   (your ~/.ssh keys are also authorized)
./lab.sh ssh sw1          # admin / admin
./lab.sh console sw1      # serial console (exit: Ctrl-] then q)
./lab.sh down             # saves switch configs, stops all VMs
```

Credentials: switches `admin`/`admin` (enable `admin`), SNMP community `lab`;
jumphost `lab`/`lab` with passwordless sudo; CirrOS hosts `cirros`/`gocubsgo`. From the jumphost, `ssh sw1`
works as-is (an ssh config with the right user/algorithms is pre-installed).

## Layout

| Path | Purpose |
|---|---|
| `lab.conf` | All tunables: RAM/CPU, IPs, console ports, links |
| `lab.sh` | Controller (`up`, `down`, `status`, `console`, `ssh`, `bootstrap`, `log`, `nac`, `rebuild`, `clean`) |
| `nac/` | Network-as-Code Terraform root + YAML data model for the switches |
| `tests/` | Robot Framework suites, keyword library, `run.sh` |
| `nautobot/` | Docker Compose stack + installer for Nautobot on the NMS |
| `results/` | One folder per test run: configs + Robot report/log (git-ignored) |
| `networks/oob-mgmt.xml` | libvirt definition of the OOB bridge (`virbr-oob`, host = 10.0.0.1) |
| `nodes/swN/iosxe_config.txt` | Day-0 config, delivered on a CD-ROM ISO and re-applied by `bootstrap` |
| `nodes/swN/post-boot.txt` | Commands run once over the console (RSA key generation) |
| `nodes/nms/{user-data,meta-data,network-config}` | cloud-init for the jumphost |
| `nodes/hostN/{user-data,meta-data}` | generated NoCloud seed for the CirrOS hosts (from `HOST_ATTACH` in `lab.conf`) |
| `nodes/*/disk.qcow2` | Overlay disks (the base images are never modified) |
| `nodes/*/console.log` | Serial console log |
| `cat9kv-*.qcow2`, `images/` | Base images (Cat9kv, Ubuntu cloud image, CirrOS) |

Generated files (`disk.qcow2`, `*.iso`, `domain.xml`, `console.log`) are
recreated by `lab.sh`; `./lab.sh clean` wipes them for a factory-fresh lab.

## Adding links

Switch data ports (Gi1/0/1–8) are QEMU UDP tunnels, which pass every frame
(802.1Q, STP BPDUs, LACP, LLDP) unlike a Linux bridge. To connect more ports,
add pairs to `LINKS` in `lab.conf` and re-define the switches:

```bash
# lab.conf
LINKS=( "sw1:1 sw2:1"  "sw1:2 sw2:2" )
./lab.sh down sw1 sw2 && ./lab.sh rebuild sw1 sw2 && ./lab.sh up
```

To add a third switch, add it to `SWITCHES`, `ALL_NODES`, `NODE_IDX`,
`MGMT_IP`, `CONSOLE_PORT`, and create `nodes/sw3/{iosxe_config.txt,post-boot.txt}`.

## Adding end hosts

CirrOS hosts are declared in `HOST_ATTACH` in `lab.conf` — one line per host:
`[host3]="sw2:5 20 10.20.0.101/24 10.20.0.1"` (switch port, VLAN, address,
gateway) — plus entries in `HOSTS`, `ALL_NODES`, `NODE_IDX`, `MGMT_IP` and
`CONSOLE_PORT`. The link is derived automatically; the switch side of a new
link needs `./lab.sh down swN && ./lab.sh rebuild swN && ./lab.sh up`. The
access-port VLAN itself is configured through the NAC data model.

## Resources

Each Cat9000v is 4 vCPU / 18 GB (Cisco's recommendation; set
`CAT9KV_RAM_MIB` in `lab.conf` to change). First boot takes 5–10 minutes.

## Requirements

`libvirt-daemon-system`, `qemu-system-x86`, `qemu-utils`, `genisoimage`,
`socat`, `terraform` >= 1.9 (in `~/.local/bin`); your user in the `libvirt` group, and `libvirt-qemu` able to
traverse into this directory (`setfacl -m u:libvirt-qemu:x /home/$USER`).

## Switch configuration as code

The switches' feature config (VLANs, trunk, SVIs, iBGP, AAA/SSH/VTY
hardening, STP, NTP/syslog/SNMP to the NMS) is managed with Cisco Network-as-Code — a YAML data model rendered
by the `netascode/nac-iosxe` Terraform module. See [nac/README.md](nac/README.md).

```bash
./lab.sh nac plan
./lab.sh nac apply
```

The day-0 files in `nodes/sw*/iosxe_config.txt` only bootstrap management
access (hostname, Gi0/0, users, SSH, NETCONF/RESTCONF); everything else
belongs in `nac/data/`.

## Nautobot

[Nautobot](nautobot/README.md) 3.2 runs on the NMS jumphost as a Docker
Compose stack with Device Onboarding, Golden Config, Nornir and SSoT apps and
a Gitea server: http://10.0.0.10:8080 (`admin`/`admin`), http://10.0.0.10:3000.
Nautobot is the **source of truth** for the switches' per-device intent —
`nac/data/devices.nac.yaml` is rendered from it (`./lab.sh nautobot render`) —
and Golden Config backs up and checks compliance of the running configs.

## Tests

Robot Framework suites validate every enabled feature end to end
(management plane, L2, L3/BGP, NTP/syslog/SNMP via the NMS, end hosts, hardening, NAC drift).
Each run backs up the switches' running/startup configs (before and after) and writes
everything to `results/<date>_<time>/` (`results/latest` symlink).
See [tests/README.md](tests/README.md).

```bash
./lab.sh test
```

## Notes / gotchas

- **Data ports show `notconnect` for the first ~3 minutes** after the IOS prompt
  appears while the virtual UADP dataplane initialises. They then flip to
  `connected` on their own.
- **Day-0 config is applied once.** IOS-XE (CVAC) records the ISO's checksum
  and ignores it on later boots (`%CVAC-4-FILE_IGNORED`). Editing
  `iosxe_config.txt` + `./lab.sh rebuild swN` produces a new checksum and the
  file is merged on the next boot. `./lab.sh bootstrap` also re-pushes it over
  the console at any time.
- **virtio offloads are disabled on the switch NICs** (`<driver name='qemu'>`
  in the generated XML). Without this, TCP from the host/jumphost to the
  switch is dropped with `TCP: checksum failure` (SSH hangs while HTTPS works).
- `./lab.sh down` does `write memory` over the console before powering a
  switch off (Cat9kv doesn't honour ACPI shutdown).
- The switches' `Mgmt-vrf` default route points at the jumphost, which NATs
  them to the internet (`ping vrf Mgmt-vrf 8.8.8.8` works).
- libvirt chowns generated disks/ISOs to `libvirt-qemu`; `lab.sh` writes
  ISOs via a temp file + rename for that reason.
- **Keep `iosxe_config.txt` management-only.** Because CVAC re-merges the ISO
  whenever its checksum changes, anything in it that overlaps with the NAC
  data model (interface descriptions, VLANs, …) will overwrite Terraform's
  config on the next reload and show up as drift in `05_nac_compliance`.
- **CirrOS NoCloud seed:** `meta-data` must be JSON (`{"instance-id": ...}`);
  YAML meta-data makes cirros-init fail with `json2fstree failed` and the
  user-data script (which sets the addresses) never runs. CirrOS boots take
  ~4 minutes because it waits for DHCP on both NICs first.
