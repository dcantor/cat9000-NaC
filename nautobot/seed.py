#!/usr/bin/env python3
"""Seed Nautobot with the lab's intent (one-time bootstrap, idempotent).

Reads the NAC device model (../nac/data/devices.nac.yaml — the file render_nac.py
generates, so it doubles as the bootstrap source for a fresh Nautobot) and the lab inventory
(../lab.conf) and creates/updates in Nautobot: roles, platforms/device types for
the end hosts, VLAN group + VLANs, prefixes (with roles and VLAN links),
switch/host/NMS interfaces with modes, IP addresses (+ primary IPs), cables and
per-device config context (BGP ASN, STP priority). After this, Nautobot is the
source of truth and render_nac.py regenerates nac/data/devices.nac.yaml from it.

Usage: NAUTOBOT_TOKEN=... seed.py [--url http://10.0.0.10:8080]
"""
import argparse
import ipaddress
import os
import re
import subprocess
import sys
from pathlib import Path

import pynautobot
import yaml

LAB = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument("--url", default=os.environ.get("NAUTOBOT_URL", "http://10.0.0.10:8080"))
p.add_argument("--token", default=os.environ.get("NAUTOBOT_TOKEN"))
a = p.parse_args()
if not a.token:
    sys.exit("NAUTOBOT_TOKEN (or --token) is required")
nb = pynautobot.api(a.url, token=a.token)

# ---------------------------------------------------------------- inputs
def load_yaml(name):
    return yaml.safe_load((LAB / "nac" / "data" / name).read_text())["iosxe"]

devices_yaml = {d["name"]: d for d in load_yaml("devices.nac.yaml")["devices"]}
first = next(iter(devices_yaml.values()))           # VLAN database is identical on both switches

def lab_conf(*arrays):
    out = subprocess.run(["bash", "-c", f"source {LAB}/lab.conf; declare -p {' '.join(arrays)}"],
                         capture_output=True, text=True, check=True).stdout
    res = {}
    for name in arrays:
        m = re.search(rf"declare -A {name}=\((.*?)\)\n", out, re.S)
        res[name] = dict(re.findall(r'\[(\w+)\]="([^"]*)"', m.group(1)))
    return res
conf = lab_conf("HOST_ATTACH", "MGMT_IP")
MGMT = conf["MGMT_IP"]
HOSTS = {}
for h, spec in conf["HOST_ATTACH"].items():
    sp, vlan, cidr, gw = spec.split()
    HOSTS[h] = {"switch": sp.split(":")[0], "port": int(sp.split(":")[1]), "vlan": int(vlan), "cidr": cidr, "gw": gw}

def mask_to_prefixlen(mask):
    return ipaddress.IPv4Network(f"0.0.0.0/{mask}").prefixlen

# ---------------------------------------------------------------- helpers
created = []
def get_or_create(endpoint, lookup, **defaults):
    obj = endpoint.get(**lookup)
    if obj is None:
        obj = endpoint.create(**lookup, **defaults)
        created.append(f"{endpoint.name}:{list(lookup.values())[0]}")
    return obj

def ensure(obj, **fields):
    """Update obj if any of the given fields differ (compares ids for related objects)."""
    changes = {}
    for k, v in fields.items():
        cur = getattr(obj, k, None)
        cur_cmp = getattr(cur, "id", cur)
        if isinstance(cur, list):
            cur_cmp = sorted(getattr(x, "id", x) for x in cur)
            v_cmp = sorted(v)
        else:
            v_cmp = v
        if str(cur_cmp) != str(v_cmp):
            changes[k] = v
    if changes:
        obj.update(changes)
    return obj

active = nb.extras.statuses.get(name="Active")
connected = nb.extras.statuses.get(name="Connected")
site = nb.dcim.locations.get(name="cat9000v-lab")
ns = nb.ipam.namespaces.get(name="Global")
if site is None:
    sys.exit("location cat9000v-lab missing — run onboard.py first")

# ---------------------------------------------------------------- roles / types / platforms
role_core = get_or_create(nb.extras.roles, {"name": "core-switch"}, color="2196f3", content_types=["dcim.device"])
role_host = get_or_create(nb.extras.roles, {"name": "host"}, color="4caf50", content_types=["dcim.device"])
role_nms = get_or_create(nb.extras.roles, {"name": "nms"}, color="ff9800", content_types=["dcim.device"])
prefix_roles = {n: get_or_create(nb.extras.roles, {"name": n}, color=c, content_types=["ipam.prefix", "ipam.vlan"])
                for n, c in (("oob-management", "9e9e9e"), ("transit", "607d8b"), ("loopback", "795548"),
                             ("routed-vlan", "3f51b5"), ("layer2-vlan", "9c27b0"))}

cisco = nb.dcim.manufacturers.get(name="Cisco")
generic = get_or_create(nb.dcim.manufacturers, {"name": "Generic"})
dt_cirros = get_or_create(nb.dcim.device_types, {"model": "CirrOS VM"}, manufacturer=generic.id, u_height=0)
dt_ubuntu = get_or_create(nb.dcim.device_types, {"model": "Ubuntu VM"}, manufacturer=generic.id, u_height=0)
plat_xe = nb.dcim.platforms.get(name="cisco_xe")
ensure(plat_xe, napalm_driver="ios", manufacturer=cisco.id)          # golden-config / napalm need the driver
plat_linux = get_or_create(nb.dcim.platforms, {"name": "linux"}, network_driver="linux")

# ---------------------------------------------------------------- global config context: services
# Rendered into every switch by render_nac.py (domain, NTP, syslog, SNMP, banner, OOB routing/ACL)
SERVICES = {
    "domain_name": "lab.local",
    "oob": {"vrf": "Mgmt-vrf", "gateway": MGMT["nms"], "acl": "MGMT-ACCESS", "prefix": "10.0.0.0/24"},
    "ntp_servers": [{"ip": MGMT["nms"], "prefer": True}],
    "syslog_hosts": [MGMT["nms"]],
    "snmp": {"community": "lab", "location": "cat9000v-lab", "contact": "netops@lab.local",
             "trap_hosts": [MGMT["nms"]]},
    "banner_motd": "Managed by Network-as-Code (Terraform). Manual changes will be reverted.",
    "quarantine_vlan": 999,
}
cc = nb.extras.config_contexts.get(name="lab-services")
if cc is None:
    nb.extras.config_contexts.create(name="lab-services", weight=1000, description="NMS-provided services and OOB settings for every switch",
                                     data=SERVICES, roles=[role_core.id])
    created.append("config-context:lab-services")
elif cc.data != SERVICES:
    cc.update({"data": SERVICES})

# management VRF (core IPAM) — Gi0/0 lives in it on every switch
mgmt_vrf = nb.ipam.vrfs.get(name="Mgmt-vrf", namespace=ns.id)
if mgmt_vrf is None:
    mgmt_vrf = nb.ipam.vrfs.create(name="Mgmt-vrf", namespace=ns.id, description="OOB management VRF (Gi0/0)")
    created.append("vrf:Mgmt-vrf")

# software version (dcim 3.x) for the switches
swv = nb.dcim.software_versions.get(version="17.18.2", platform=plat_xe.id)
if swv is None:
    swv = nb.dcim.software_versions.create(version="17.18.2", platform=plat_xe.id, status=active.id,
                                           long_term_support=False, release_date="2025-12-19")
    created.append("software-version:17.18.2")

# ---------------------------------------------------------------- VLANs
vg = get_or_create(nb.ipam.vlan_groups, {"name": "cat9000v-lab"}, location=site.id)
vlans = {}
vlan_list = list(first["configuration"]["vlan"]["vlans"]) + [{"id": SERVICES["quarantine_vlan"], "name": "QUARANTINE"}]
for v in vlan_list:
    vid, name = int(v["id"]), v["name"]
    role = prefix_roles["routed-vlan"] if name.startswith("L3-") or vid in (10, 20) else \
           prefix_roles["transit"] if vid == 100 else prefix_roles["layer2-vlan"]
    vlan = nb.ipam.vlans.get(vid=vid, vlan_group=vg.id)
    if vlan is None:
        vlan = nb.ipam.vlans.create(vid=vid, name=name, vlan_group=vg.id, status=active.id, role=role.id)
        created.append(f"vlan:{vid}")
    else:
        ensure(vlan, name=name, role=role.id, status=active.id)
    vlans[vid] = vlan

# ---------------------------------------------------------------- prefixes
def ensure_prefix(cidr, role=None, vlan=None, ptype="network", desc=""):
    net = str(ipaddress.IPv4Network(cidr, strict=False))
    pf = nb.ipam.prefixes.get(prefix=net, namespace=ns.id)
    if pf is None:
        pf = nb.ipam.prefixes.create(prefix=net, namespace=ns.id, status=active.id, type=ptype)
        created.append(f"prefix:{net}")
    fields = {"status": active.id, "type": ptype, "description": desc}
    if role: fields["role"] = role.id
    if vlan: fields["vlan"] = vlan.id
    ensure(pf, **fields)
    return pf

ensure_prefix("10.0.0.0/24", prefix_roles["oob-management"], desc="OOB management (libvirt oob-mgmt bridge, host = .1)")
ensure_prefix("10.255.0.0/24", prefix_roles["loopback"], ptype="container", desc="router-id loopbacks")

# ---------------------------------------------------------------- devices
def ensure_device(name, dtype, role, platform, ctx=None):
    dev = nb.dcim.devices.get(name=name)
    if dev is None:
        dev = nb.dcim.devices.create(name=name, device_type=dtype.id, role=role.id, platform=platform.id,
                                     location=site.id, status=active.id)
        created.append(f"device:{name}")
    fields = {"role": role.id, "platform": platform.id, "status": active.id}
    if ctx is not None:
        fields["local_config_context_data"] = ctx
    ensure(dev, **fields)
    return dev

def ensure_iface(dev, name, itype, desc="", mgmt_only=False, mode=None, untagged=None, tagged=None, enabled=True):
    itf = nb.dcim.interfaces.get(device=dev.id, name=name)
    if itf is None:
        itf = nb.dcim.interfaces.create(device=dev.id, name=name, type=itype, status=active.id)
        created.append(f"interface:{dev.name}/{name}")
    fields = {"type": itype, "description": desc, "mgmt_only": mgmt_only, "enabled": enabled, "status": active.id}
    if mode:
        fields["mode"] = mode
        if untagged is not None: fields["untagged_vlan"] = vlans[untagged].id
    else:
        fields["mode"] = ""
    ensure(itf, **fields)
    if mode == "tagged":
        # tagged_vlans is not returned by the REST API (read it back via GraphQL), so pynautobot's
        # diff-based update() never sends it — PATCH it explicitly.
        nb.http_session.patch(f"{a.url}/api/dcim/interfaces/{itf.id}/",
                              json={"tagged_vlans": [vlans[v].id for v in (tagged or [])]},
                              headers={"Authorization": f"Token {a.token}", "Accept": "application/json"}).raise_for_status()
    return itf

def ensure_ip(itf, cidr, primary_of=None):
    ip = nb.ipam.ip_addresses.get(address=cidr, namespace=ns.id) or \
         nb.ipam.ip_addresses.get(address=cidr.split("/")[0], namespace=ns.id)
    if ip is None:
        ip = nb.ipam.ip_addresses.create(address=cidr, namespace=ns.id, status=active.id)
        created.append(f"ip:{cidr}")
    if not nb.ipam.ip_address_to_interface.get(ip_address=ip.id, interface=itf.id):
        nb.ipam.ip_address_to_interface.create(ip_address=ip.id, interface=itf.id)
    if primary_of is not None:
        ensure(primary_of, primary_ip4=ip.id)
    return ip

def ensure_cable(a_itf, b_itf):
    if a_itf.cable or b_itf.cable:
        return
    nb.dcim.cables.create(termination_a_type="dcim.interface", termination_a_id=a_itf.id,
                          termination_b_type="dcim.interface", termination_b_id=b_itf.id, status=connected.id)
    created.append(f"cable:{a_itf.device.name}:{a_itf.name}-{b_itf.device.name}:{b_itf.name}")

trunk_vlans = sorted(vid for vid in vlans if vid not in (99, SERVICES["quarantine_vlan"]))   # not native, not quarantine

switch_ifaces = {}
for sw, dy in devices_yaml.items():
    cfg = dy["configuration"]
    ctx = {"bgp": {"asn": int(dy["variables"]["bgp_asn"])},
           "stp_priority": cfg["spanning_tree"]["vlans"][0]["priority"]}
    dev = ensure_device(sw, nb.dcim.device_types.get(model="C9KV-UADP-8P"), role_core, plat_xe, ctx)
    ensure(dev, secrets_group=nb.extras.secrets_groups.get(name="lab-devices").id,   # Nornir/Golden Config creds
           software_version=swv.id)
    mgmt = ensure_iface(dev, "GigabitEthernet0/0", "1000base-t", "OOB management (Mgmt-vrf)", mgmt_only=True)
    if nb.ipam.vrf_device_assignments.get(vrf=mgmt_vrf.id, device=dev.id) is None:   # VRF must be on the device first
        nb.ipam.vrf_device_assignments.create(vrf=mgmt_vrf.id, device=dev.id)
        created.append(f"vrf-device:{sw}/Mgmt-vrf")
    ensure(mgmt, vrf=mgmt_vrf.id)
    ensure_ip(mgmt, f"{MGMT[sw]}/24", primary_of=dev)
    switch_ifaces[sw] = {}
    eth = {e["id"]: e for e in cfg["interfaces"]["ethernets"]}
    for n in range(1, 9):
        name = f"GigabitEthernet1/0/{n}"
        e = eth.get(f"1/0/{n}")
        if e is None:   # no cable, no role: shut and parked in the quarantine VLAN
            itf = ensure_iface(dev, name, "1000base-t", "unused (quarantine)", enabled=False,
                               mode="access", untagged=SERVICES["quarantine_vlan"])
        elif e["switchport"]["mode"] == "trunk":
            itf = ensure_iface(dev, name, "1000base-t", e["description"], mode="tagged", enabled=not e.get("shutdown", False),
                               untagged=e["switchport"]["trunk_native_vlan_id"], tagged=trunk_vlans)
        else:
            itf = ensure_iface(dev, name, "1000base-t", e["description"], mode="access", enabled=not e.get("shutdown", False),
                               untagged=e["switchport"]["access_vlan"])
        switch_ifaces[sw][n] = itf
    for lo in cfg["interfaces"]["loopbacks"]:
        itf = ensure_iface(dev, f"Loopback{lo['id']}", "virtual", lo["description"])
        cidr = f"{lo['ipv4']['address']}/{mask_to_prefixlen(lo['ipv4']['address_mask'])}"
        ensure_prefix(cidr, prefix_roles["loopback"], desc=f"{sw} {lo['description']}")   # /32 so it can carry bgp:advertise
        ensure_ip(itf, cidr)
    # Vlan1 exists on every Catalyst and is kept shut down (modelled so compliance sees it)
    ensure_iface(dev, "Vlan1", "virtual", "", enabled=False)
    for s in cfg["interfaces"]["vlans"]:
        vid = int(s["id"])
        addr = s["ipv4"]["address"]
        plen = mask_to_prefixlen(s["ipv4"]["address_mask"])
        role = prefix_roles["transit"] if vid == 100 else prefix_roles["routed-vlan"]
        ensure_prefix(f"{addr}/{plen}", role, vlans[vid], desc=s["description"])
        itf = ensure_iface(dev, f"Vlan{vid}", "virtual", s["description"], mode="access", untagged=vid)
        ensure_ip(itf, f"{addr}/{plen}")

# inter-switch trunk
ensure_cable(switch_ifaces["sw1"][1], switch_ifaces["sw2"][1])

# end hosts + NMS
for h, spec in HOSTS.items():
    dev = ensure_device(h, dt_cirros, role_host, plat_linux)
    e0 = ensure_iface(dev, "eth0", "virtual", "OOB management", mgmt_only=True)
    ensure_ip(e0, f"{MGMT[h]}/24", primary_of=dev)
    e1 = ensure_iface(dev, "eth1", "1000base-t", f"{spec['switch']} Gi1/0/{spec['port']} (VLAN {spec['vlan']})",
                      mode="access", untagged=spec["vlan"])
    ensure_ip(e1, spec["cidr"])
    ensure_cable(switch_ifaces[spec["switch"]][spec["port"]], e1)

nms = ensure_device("nms", dt_ubuntu, role_nms, plat_linux)
e0 = ensure_iface(nms, "eth0", "virtual", "libvirt default NAT (internet)")
e1 = ensure_iface(nms, "eth1", "virtual", "OOB management — NTP/syslog/SNMP/Nautobot")
ensure_ip(e1, f"{MGMT['nms']}/24", primary_of=nms)

# ---------------------------------------------------------------- BGP (nautobot-bgp-models)
bgp = nb.plugins.bgp
# the "Active" status must be allowed on the BGP models before it can be used there
need = ["nautobot_bgp_models.autonomoussystem", "nautobot_bgp_models.bgproutinginstance", "nautobot_bgp_models.peering"]
missing = [ct for ct in need if ct not in active.content_types]
if missing:
    active.update({"content_types": list(active.content_types) + missing})
    created.append("status Active: +bgp content types")
tag_adv = get_or_create(nb.extras.tags, {"name": "bgp:advertise"}, color="ff5722", content_types=["ipam.prefix"],
                        description="prefix is originated into BGP (network statement) by the switch that owns it")
asn = int(first["variables"]["bgp_asn"])
as_obj = get_or_create(bgp.autonomous_systems, {"asn": asn}, status=active.id, description="cat9000v lab (iBGP)")

ri, transit_ip_obj = {}, {}
for sw, dy in devices_yaml.items():
    dev = nb.dcim.devices.get(name=sw)
    rid_ip = nb.ipam.ip_addresses.get(address=f"{dy['variables']['router_id']}/32", namespace=ns.id)
    inst = bgp.routing_instances.get(device=dev.id)
    fields = {"autonomous_system": as_obj.id, "router_id": rid_ip.id, "status": active.id,
              "extra_attributes": {"log_neighbor_changes": True},
              "description": "core switch iBGP"}
    if inst is None:
        inst = bgp.routing_instances.create(device=dev.id, **fields)
        created.append(f"bgp-routing-instance:{sw}")
    else:
        ensure(inst, **{k: v for k, v in fields.items() if k != "extra_attributes"})
        if inst.extra_attributes != fields["extra_attributes"]:
            inst.update({"extra_attributes": fields["extra_attributes"]})
    ri[sw] = inst
    if bgp.address_families.get(routing_instance=inst.id, afi_safi="ipv4_unicast") is None:
        bgp.address_families.create(routing_instance=inst.id, afi_safi="ipv4_unicast")
        created.append(f"bgp-af:{sw}/ipv4_unicast")
    # transit address on this switch = peering source
    tip = dy["variables"]["transit_ip"]
    transit_ip_obj[sw] = next(ip for ip in nb.ipam.ip_addresses.filter(address=tip, namespace=ns.id))
    # prefixes this switch originates: loopback + every gateway VLAN it hosts
    for net in dy["configuration"]["routing"]["bgp"]["address_family"]["ipv4_unicast"]["networks"]:
        plen = mask_to_prefixlen(net["mask"])
        pf = nb.ipam.prefixes.get(prefix=f"{net['network']}/{plen}", namespace=ns.id)
        if pf and tag_adv.id not in [t.id for t in pf.tags]:
            pf.update({"tags": [t.id for t in pf.tags] + [tag_adv.id]})
            created.append(f"tag bgp:advertise on {pf.prefix}")

# one iBGP peering between the two core switches over the transit SVIs
names = sorted(ri)
if len(names) == 2:
    a_sw, b_sw = names
    existing = [e for e in bgp.peer_endpoints.filter(routing_instance=ri[a_sw].id) if getattr(e.source_ip, "id", None) == transit_ip_obj[a_sw].id]
    if existing:
        peering = existing[0].peering
    else:
        peering = bgp.peerings.create(status=active.id)
        created.append(f"bgp-peering:{a_sw}<->{b_sw}")
        eps = {}
        for sw in names:
            eps[sw] = bgp.peer_endpoints.create(peering=peering.id, routing_instance=ri[sw].id, source_ip=transit_ip_obj[sw].id,
                                                autonomous_system=as_obj.id, description="iBGP to peer core switch", enabled=True)
            bgp.peer_endpoint_address_families.create(peer_endpoint=eps[sw].id, afi_safi="ipv4_unicast")
        created.append("bgp-peer-endpoints + ipv4_unicast AFs")

# saved GraphQL query: the exact query render_nac.py uses, runnable from Extensibility > GraphQL Queries
NAC_QUERY = """{
  devices(role: "core-switch") {
    name
    primary_ip4 { address }
    local_config_context_data
    config_context
    software_version { version }
    interfaces {
      name
      description
      enabled
      mgmt_only
      mode
      untagged_vlan { vid }
      tagged_vlans { vid }
      vrf { name }
      ip_addresses {
        address
        parent { role { name } prefix }
      }
    }
  }
  vlan_groups(name: "cat9000v-lab") {
    vlans { vid name role { name } }
  }
  bgp_routing_instances {
    device { name }
    autonomous_system { asn }
    router_id { address }
    extra_attributes
    address_families { afi_safi }
    endpoints {
      description
      enabled
      source_ip { address }
      address_families { afi_safi }
      peer {
        source_ip { address }
        autonomous_system { asn }
      }
    }
  }
  prefixes(tags: "bgp:advertise") { prefix }
}
"""
gq = nb.extras.graphql_queries.get(name="nac-device-model")
if gq is None:
    nb.extras.graphql_queries.create(name="nac-device-model", query=NAC_QUERY)
    created.append("graphql-query:nac-device-model")
elif gq.query != NAC_QUERY:   # pynautobot's diff-based update() skips this field; PATCH directly
    nb.http_session.patch(f"{a.url}/api/extras/graphql-queries/{gq.id}/", json={"query": NAC_QUERY},
                          headers={"Authorization": f"Token {a.token}", "Accept": "application/json"}).raise_for_status()
    created.append("graphql-query:nac-device-model (updated)")

print(f"seed complete: {len(created)} objects created" + (":\n  " + "\n  ".join(created) if created else " (nothing new)"))
