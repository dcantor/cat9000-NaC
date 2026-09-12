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

QUERY = """
{
  devices(role: "core-switch") {
    name
    primary_ip4 { address }
    local_config_context_data
    interfaces {
      name description enabled mgmt_only mode
      untagged_vlan { vid }
      tagged_vlans { vid }
      ip_addresses { address parent { role { name } } }
    }
  }
  vlan_groups(name: "cat9000v-lab") { vlans { vid name role { name } } }
}
"""
r = requests.post(f"{a.url}/api/graphql/", json={"query": QUERY},
                  headers={"Authorization": f"Token {a.token}"}, timeout=60)
r.raise_for_status()
data = r.json()
if data.get("errors"):
    sys.exit(f"GraphQL errors: {data['errors']}")
devices = sorted(data["data"]["devices"], key=lambda d: d["name"])
vlans = sorted(data["data"]["vlan_groups"][0]["vlans"], key=lambda v: v["vid"])
vlan_ids = [v["vid"] for v in vlans]


def ifnum(name):                      # GigabitEthernet1/0/3 -> (1,0,3) for natural sorting
    return tuple(int(x) for x in re.findall(r"\d+", name))


def netmask(cidr):
    n = ipaddress.IPv4Interface(cidr)
    return str(n.ip), str(n.network.netmask), str(n.network)


def render_device(dev):
    name = dev["name"]
    ctx = dev["local_config_context_data"] or {}
    ifaces = sorted(dev["interfaces"], key=lambda i: (i["name"].rstrip("0123456789/"), ifnum(i["name"])))
    svis, loopbacks, ethernets, networks = [], [], [], []
    router_id = transit_ip = None

    for i in ifaces:
        n = i["name"]
        ips = [ip["address"] for ip in i["ip_addresses"]]
        role = (i["ip_addresses"][0]["parent"]["role"] or {}).get("name") if i["ip_addresses"] and i["ip_addresses"][0]["parent"] else None
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
                e["spanning_tree"] = {"portfast": True, "bpduguard": True}
            else:
                continue                                  # unused ports stay at device defaults
            ethernets.append(e)
        elif n.startswith("Vlan") and ips:
            vid = int(n[4:])
            addr, mask, net = netmask(ips[0])
            svis.append({"id": vid, "description": i["description"], "shutdown": not i["enabled"],
                         "ipv4": {"address": addr, "address_mask": mask}})
            if role == "transit":
                transit_ip = addr
            else:
                networks.append({"network": net.split("/")[0], "mask": mask})
        elif n.startswith("Loopback") and ips:
            addr, mask, net = netmask(ips[0])
            loopbacks.append({"id": int(n[8:]), "description": i["description"], "ipv4": {"address": addr, "address_mask": mask}})
            if n == "Loopback0":
                router_id = addr
                networks.insert(0, {"network": addr, "mask": mask})

    return {
        "name": name,
        "host": dev["primary_ip4"]["address"].split("/")[0],
        "protocol": "restconf",
        "device_groups": [a.group],
        "variables": {"router_id": router_id, "transit_ip": transit_ip, "bgp_asn": ctx.get("bgp", {}).get("asn")},
        "configuration": {
            "system": {"hostname": name},
            "spanning_tree": {"vlans": [{"id": v, "priority": ctx.get("stp_priority")} for v in [1] + vlan_ids]},
            "vlan": {"vlans": [{"id": v["vid"], "name": v["name"]} for v in vlans]},
            "interfaces": {"ethernets": ethernets, "vlans": svis, "loopbacks": loopbacks},
            "routing": {"bgp": {"address_family": {"ipv4_unicast": {"networks": networks}}}},
        },
    }


rendered = [render_device(d) for d in devices]
# the iBGP peer is the other core switch's transit address
for d in rendered:
    others = [o for o in rendered if o is not d]
    d["variables"]["peer_transit_ip"] = others[0]["variables"]["transit_ip"] if len(others) == 1 else None

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
