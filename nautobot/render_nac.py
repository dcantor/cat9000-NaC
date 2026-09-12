#!/usr/bin/env python3
"""Render the NAC device model (nac/data/devices.nac.yaml) from Nautobot.

Nautobot is the source of truth for the per-device intent: management IPs,
VLAN database, switchport modes, SVIs/loopbacks and their addresses, STP
priorities and BGP ASN (device config context). This script queries it over
GraphQL and writes the YAML the netascode/nac-iosxe module consumes.
Everything that is *not* modelled in Nautobot (services, hardening, the BGP
peering skeleton) stays hand-written in global.nac.yaml / device_groups.nac.yaml.

Usage: NAUTOBOT_TOKEN=... render_nac.py [--url URL] [--out nac/data/devices.nac.yaml] [--check]
  --check   render to memory and exit 1 if the file on disk differs (used by the tests)
"""
import argparse
import ipaddress
import os
import re
import sys
from pathlib import Path

import requests
import yaml

LAB = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument("--url", default=os.environ.get("NAUTOBOT_URL", "http://10.0.0.10:8080"))
p.add_argument("--token", default=os.environ.get("NAUTOBOT_TOKEN"))
p.add_argument("--out", default=str(LAB / "nac" / "data" / "devices.nac.yaml"))
p.add_argument("--group", default="CORE_SWITCHES")
p.add_argument("--check", action="store_true")
a = p.parse_args()
if not a.token:
    sys.exit("NAUTOBOT_TOKEN (or --token) is required")

# The query is saved in Nautobot as "nac-device-model" (Extensibility > GraphQL Queries) so it
# can be run from the GUI; that saved copy is used when present, this is the fallback.
QUERY = """
{
  devices(role: "core-switch") {
    name
    primary_ip4 { address }
    local_config_context_data
    config_context
    software_version { version }
    interfaces {
      name description enabled mgmt_only mode
      untagged_vlan { vid }
      tagged_vlans { vid }
      vrf { name }
      ip_addresses { address parent { role { name } prefix } }
    }
  }
  vlan_groups(name: "cat9000v-lab") { vlans { vid name role { name } } }
  bgp_routing_instances {
    device { name }
    autonomous_system { asn }
    router_id { address }
    extra_attributes
    address_families { afi_safi }
    endpoints {
      description enabled
      source_ip { address }
      address_families { afi_safi }
      peer { source_ip { address } autonomous_system { asn } }
    }
  }
  prefixes(tags: "bgp:advertise") { prefix }
}
"""
saved = requests.get(f"{a.url}/api/extras/graphql-queries/", params={"name": "nac-device-model"},
                     headers={"Authorization": f"Token {a.token}"}, timeout=30)
if saved.ok and saved.json()["count"] == 1:
    QUERY = saved.json()["results"][0]["query"]
r = requests.post(f"{a.url}/api/graphql/", json={"query": QUERY},
                  headers={"Authorization": f"Token {a.token}"}, timeout=60)
r.raise_for_status()
data = r.json()
if data.get("errors"):
    sys.exit(f"GraphQL errors: {data['errors']}")
devices = sorted(data["data"]["devices"], key=lambda d: d["name"])
vlans = sorted(data["data"]["vlan_groups"][0]["vlans"], key=lambda v: v["vid"])
vlan_ids = [v["vid"] for v in vlans]
bgp_ri = {r["device"]["name"]: r for r in data["data"]["bgp_routing_instances"]}
advertise = {p["prefix"] for p in data["data"]["prefixes"]}


def ifnum(name):                      # GigabitEthernet1/0/3 -> (1,0,3) for natural sorting
    return tuple(int(x) for x in re.findall(r"\d+", name))


def netmask(cidr):
    n = ipaddress.IPv4Interface(cidr)
    return str(n.ip), str(n.network.netmask), str(n.network)


def wildcard(prefix):
    return str(ipaddress.IPv4Network(prefix).hostmask)


def render_device(dev):
    name = dev["name"]
    ctx = dev["local_config_context_data"] or {}
    svc = dev["config_context"] or {}          # merged global ("lab-services") + local context
    oob = svc.get("oob", {})
    ifaces = sorted(dev["interfaces"], key=lambda i: (i["name"].rstrip("0123456789/"), ifnum(i["name"])))
    svis, loopbacks, ethernets, networks = [], [], [], []
    router_id = transit_ip = None
    ri = bgp_ri.get(name)

    for i in ifaces:
        n = i["name"]
        ips = [ip["address"] for ip in i["ip_addresses"]]
        parent = i["ip_addresses"][0]["parent"] if i["ip_addresses"] and i["ip_addresses"][0]["parent"] else None
        role = (parent["role"] or {}).get("name") if parent else None
        if parent and parent["prefix"] in advertise:          # explicit: prefix tagged bgp:advertise
            net = ipaddress.IPv4Network(parent["prefix"])
            networks.append({"network": str(net.network_address), "mask": str(net.netmask)})
        if n == "GigabitEthernet0/0" and ips:          # OOB management in the management VRF
            addr, mask, _ = netmask(ips[0])
            ethernets.append({"type": "GigabitEthernet", "id": "0/0", "description": i["description"],
                              "shutdown": not i["enabled"], "vrf_forwarding": i["vrf"]["name"] if i["vrf"] else None,
                              "ipv4": {"address": addr, "address_mask": mask}})
            continue
        if n.startswith("GigabitEthernet1/0/"):
            port = n.split("GigabitEthernet")[1]
            e = {"type": "GigabitEthernet", "id": port, "description": i["description"], "shutdown": not i["enabled"]}
            if i["mode"] == "TAGGED":
                e["switchport"] = {"enable": True, "mode": "trunk",
                                   "trunk_native_vlan_id": i["untagged_vlan"]["vid"],
                                   "trunk_allowed_vlans": {"vlans": {"ids": sorted(v["vid"] for v in i["tagged_vlans"])}},
                                   "nonegotiate": True}
            elif i["mode"] == "ACCESS":
                e["switchport"] = {"enable": True, "mode": "access", "access_vlan": i["untagged_vlan"]["vid"]}
                if i["enabled"]:                           # quarantined (shut) ports get no edge-port settings
                    e["spanning_tree"] = {"portfast": True, "bpduguard": True}
            else:
                continue
            ethernets.append(e)
        elif n.startswith("Vlan") and ips:
            vid = int(n[4:])
            addr, mask, net = netmask(ips[0])
            svis.append({"id": vid, "description": i["description"], "shutdown": not i["enabled"],
                         "ipv4": {"address": addr, "address_mask": mask}})
            if role == "transit":
                transit_ip = addr
        elif n.startswith("Loopback") and ips:
            addr, mask, net = netmask(ips[0])
            loopbacks.append({"id": int(n[8:]), "description": i["description"], "ipv4": {"address": addr, "address_mask": mask}})
            if n == "Loopback0":
                router_id = addr

    # BGP from nautobot-bgp-models: routing instance (AS, router-id), peer endpoints, address families
    bgp = None
    if ri:
        neighbors, af_neighbors = [], []
        for ep in sorted(ri["endpoints"], key=lambda e: e["peer"]["source_ip"]["address"] if e["peer"] else ""):
            if not ep["peer"] or not ep["enabled"]:
                continue
            peer_ip = ep["peer"]["source_ip"]["address"].split("/")[0]
            neighbors.append({"ip": peer_ip, "remote_as": ep["peer"]["autonomous_system"]["asn"],
                              "description": ep["description"]})
            if any(af["afi_safi"] == "IPV4_UNICAST" for af in ep["address_families"]):
                af_neighbors.append({"ip": peer_ip, "activate": True})
        bgp = {"as_number": ri["autonomous_system"]["asn"],
               "router_id": ri["router_id"]["address"].split("/")[0] if ri["router_id"] else router_id,
               "log_neighbor_changes": bool((ri["extra_attributes"] or {}).get("log_neighbor_changes", True)),
               "neighbors": neighbors,
               "address_family": {"ipv4_unicast": {"neighbors": af_neighbors,
                                                   # loopback (/32) first, then subnets ascending — matches the
                                                   # order already on the switches, the provider treats it as ordered
                                                   "networks": sorted(networks, key=lambda n: (n["mask"] != "255.255.255.255", ipaddress.IPv4Address(n["network"])))}}}

    services = {}
    if svc:
        services = {
            "system": {"hostname": name, "ip_domain_name": svc.get("domain_name")},
            "ntp": {"servers": [{"ip": n["ip"], "vrf": oob.get("vrf"), "prefer": n.get("prefer", False)} for n in svc.get("ntp_servers", [])]},
            "logging": {"hosts": [{"ip": h, "vrf": oob.get("vrf")} for h in svc.get("syslog_hosts", [])]},
            "snmp_server": {
                "contact": svc["snmp"]["contact"], "location": svc["snmp"]["location"],
                "snmp_communities": [{"name": svc["snmp"]["community"], "permission": "ro"}],
                "hosts": [{"ip": h, "vrf": oob.get("vrf"), "community": svc["snmp"]["community"], "version": "2c"}
                          for h in svc["snmp"].get("trap_hosts", [])],
                "enable_traps": True,
            } if svc.get("snmp") else {},
            "banner": {"motd": svc["banner_motd"]} if svc.get("banner_motd") else {},
            "access_lists": {"standard": [{
                "name": oob["acl"],
                "entries": [{"sequence": 10, "remark": "OOB management network (host, NMS, lab hosts)"},
                            {"sequence": 20, "action": "permit", "prefix": str(ipaddress.IPv4Network(oob["prefix"]).network_address),
                             "prefix_mask": wildcard(oob["prefix"])},
                            {"sequence": 30, "action": "deny", "any": True, "log": True}]}]} if oob.get("acl") else {},
            "routing": {"static_routes": [{"vrf": oob["vrf"], "prefix": "0.0.0.0", "mask": "0.0.0.0",
                                           "next_hops": [{"ip": oob["gateway"]}]}]} if oob.get("gateway") else {},
        }
    routing = dict(services.pop("routing", {}))
    if bgp:
        routing["bgp"] = bgp

    return {
        "name": name,
        "host": dev["primary_ip4"]["address"].split("/")[0],
        "protocol": "restconf",
        "device_groups": [a.group],
        "variables": {"router_id": router_id, "transit_ip": transit_ip,
                      "bgp_asn": ri["autonomous_system"]["asn"] if ri else ctx.get("bgp", {}).get("asn")},
        "configuration": {
            **{k: v for k, v in services.items() if v and k != "system"},
            "system": services.get("system", {"hostname": name}),
            "spanning_tree": {"vlans": [{"id": v, "priority": ctx.get("stp_priority")} for v in [1] + vlan_ids]},
            "vlan": {"vlans": [{"id": v["vid"], "name": v["name"]} for v in vlans]},
            "interfaces": {"ethernets": ethernets, "vlans": svis, "loopbacks": loopbacks},
            **({"routing": routing} if routing else {}),
        },
    }


rendered = [render_device(d) for d in devices]

header = ("---\n"
          "# GENERATED from Nautobot by nautobot/render_nac.py — do not edit by hand.\n"
          f"# Source of truth: {a.url}  (devices with role core-switch, VLAN group cat9000v-lab)\n")
out = header + yaml.safe_dump({"iosxe": {"devices": rendered}}, sort_keys=False, default_flow_style=False, width=120)

if a.check:
    current = Path(a.out).read_text() if Path(a.out).exists() else ""
    if current != out:
        import difflib
        sys.stdout.writelines(difflib.unified_diff(current.splitlines(True), out.splitlines(True), "on-disk", "nautobot"))
        sys.exit(1)
    print(f"{a.out} matches Nautobot")
else:
    Path(a.out).write_text(out)
    print(f"wrote {a.out}: {len(rendered)} devices, {len(vlans)} VLANs")
