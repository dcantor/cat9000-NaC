"""Robot Framework variable file: lab inventory and expected state.

Keep in sync with ../../lab.conf and ../../nac/data/*.nac.yaml.
"""
import os

USERNAME = os.environ.get("IOSXE_USERNAME", "admin")
PASSWORD = os.environ.get("IOSXE_PASSWORD", "admin")

NMS = {"name": "nms", "host": "10.0.0.10", "user": "lab"}

SWITCHES = {
    "sw1": {
        "host": "10.0.0.11",
        "router_id": "10.255.0.1",
        "transit_ip": "10.100.0.1",
        "peer": "sw2",
        "svis": {"Vlan10": "10.10.0.1", "Vlan100": "10.100.0.1"},
    },
    "sw2": {
        "host": "10.0.0.12",
        "router_id": "10.255.0.2",
        "transit_ip": "10.100.0.2",
        "peer": "sw1",
        "svis": {"Vlan20": "10.20.0.1", "Vlan100": "10.100.0.2"},
    },
}
SWITCH_NAMES = list(SWITCHES)

# Routing: single-AS iBGP between the switches over the transit SVIs
BGP_ASN = "65000"
# prefixes each switch originates (loopback + the VLANs it is the gateway for)
BGP_NETWORKS = {
    "sw1": ["10.255.0.1/32", "10.10.0.0/24"] + [f"10.{v}.0.0/24" for v in range(110, 115)],
    "sw2": ["10.255.0.2/32", "10.20.0.0/24"] + [f"10.{v}.0.0/24" for v in range(115, 120)],
}

# CirrOS end hosts (from lab.conf HOST_ATTACH): OOB mgmt IP + data NIC on a switch access port
HOSTS = {
    "host1": {"mgmt": "10.0.0.21", "switch": "sw1", "port": "Gi1/0/2", "vlan": "10",
              "ip": "10.10.0.100", "gateway": "10.10.0.1", "mac": "5254.00c9.0301", "peer": "host2"},
    "host2": {"mgmt": "10.0.0.22", "switch": "sw2", "port": "Gi1/0/4", "vlan": "20",
              "ip": "10.20.0.100", "gateway": "10.20.0.1", "mac": "5254.00c9.0401", "peer": "host1"},
}
HOST_NAMES = list(HOSTS)
# hops a host1 -> host2 traceroute must show: sw1 Vlan10 gateway, then sw2's transit SVI
HOST_PATH = {"host1": ["10.10.0.1", "10.100.0.2"], "host2": ["10.20.0.1", "10.100.0.1"]}

# Expected VLAN database (from nac/data/device_groups.nac.yaml)
VLANS = {"10": "USERS", "20": "SERVERS", "99": "NATIVE", "100": "TRANSIT"}

# Routed VLANs: one /24 each, SVI (gateway .1) hosted on one switch, advertised in OSPF
L3_VLANS = {}
for _v in range(110, 120):
    L3_VLANS[str(_v)] = {
        "name": f"L3-{_v}",
        "subnet": f"10.{_v}.0.0/24",
        "gateway": f"10.{_v}.0.1",
        "owner": "sw1" if _v < 115 else "sw2",
    }
# Layer-2-only VLANs: bridged across the trunk, no SVI anywhere
L2_VLANS = {str(_v): f"L2-{_v}" for _v in range(210, 220)}
VLANS.update({k: v["name"] for k, v in L3_VLANS.items()})
VLANS.update(L2_VLANS)

TRUNK_PORT = "Po1"                                   # LACP port-channel carrying the trunk
TRUNK_MEMBERS = ["Gi1/0/1", "Gi1/0/5"]
TRUNK_NATIVE_VLAN = "99"
TRUNK_ALLOWED_VLANS = "10,20,100,110-119,210-219"
ACCESS_PORTS = {"Gi1/0/2": "10", "Gi1/0/3": "10", "Gi1/0/4": "20"}
UNUSED_PORTS = ["Gi1/0/6", "Gi1/0/7", "Gi1/0/8"]   # shut, parked in the quarantine VLAN
QUARANTINE_VLAN = "999"
VLANS[QUARANTINE_VLAN] = "QUARANTINE"
SOFTWARE_VERSION = "17.18.2"
STP_MODE = "rapid-pvst"

# Hardening (from nac/data/global.nac.yaml / devices.nac.yaml)
MGMT_ACL = "MGMT-ACCESS"
STP_PRIORITY = {"sw1": 4096, "sw2": 8192}       # sw1 = root, sw2 = backup root
STP_ROOT_MAC = "5254.00c9.0100"                  # sw1 bridge MAC (52:54:00:c9:01:00)

# Services (from nac/data/global.nac.yaml)
NTP_SERVER = "10.0.0.10"
SYSLOG_HOST = "10.0.0.10"
SNMP_COMMUNITY = "lab"
SNMP_LOCATION = "cat9000v-lab"
SNMP_CONTACT = "netops@lab.local"
DOMAIN_NAME = "lab.local"
BANNER_TEXT = "Managed by Network-as-Code"
