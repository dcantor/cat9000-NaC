#!/usr/bin/env python3
"""Discover the lab switches into Nautobot with the Device Onboarding app.

Creates the prerequisites (location, secrets group backed by container env vars,
device role/status) and runs the "Sync Devices From Network" job for the
switch management IPs, then waits for the job to finish.

Usage: onboard.py [--url http://10.0.0.10:8080] [--token ...] [ip ...]
"""
import argparse
import os
import sys
import time

import pynautobot

p = argparse.ArgumentParser()
p.add_argument("--url", default=os.environ.get("NAUTOBOT_URL", "http://10.0.0.10:8080"))
p.add_argument("--token", default=os.environ.get("NAUTOBOT_TOKEN"))
p.add_argument("ips", nargs="*", default=["10.0.0.11", "10.0.0.12"])
a = p.parse_args()
if not a.token:
    sys.exit("NAUTOBOT_TOKEN (or --token) is required")

nb = pynautobot.api(a.url, token=a.token)


def get_or_create(endpoint, lookup, **defaults):
    obj = endpoint.get(**lookup)
    if obj is None:
        obj = endpoint.create(**lookup, **defaults)
        print(f"  created {endpoint.name}: {lookup}")
    return obj


active = nb.extras.statuses.get(name="Active")

# location type + location (VLANs, prefixes, devices, racks may live here)
lt = get_or_create(nb.dcim.location_types, {"name": "Site"},
                   content_types=["dcim.device", "ipam.prefix", "ipam.vlan", "ipam.vlangroup",
                                  "circuits.circuittermination", "dcim.rack", "dcim.rackgroup"])
site = get_or_create(nb.dcim.locations, {"name": "cat9000v-lab"},
                     location_type=lt.id, status=active.id, description="libvirt/KVM lab")

# roles
role = get_or_create(nb.extras.roles, {"name": "core-switch"}, color="2196f3", content_types=["dcim.device"])
ns = nb.ipam.namespaces.get(name="Global")

# secrets: env-var provider -> values come from the container environment (.env on the NMS)
sec = {}
for key, env in (("username", "LAB_DEVICE_USERNAME"), ("password", "LAB_DEVICE_PASSWORD"), ("secret", "LAB_DEVICE_SECRET")):
    sec[key] = get_or_create(nb.extras.secrets, {"name": f"lab-device-{key}"},
                             provider="environment-variable", parameters={"variable": env})
sg = get_or_create(nb.extras.secrets_groups, {"name": "lab-devices"})
have = {(x.access_type, x.secret_type) for x in nb.extras.secrets_groups_associations.filter(secrets_group=sg.id)}
for access, stype, key in (("Generic", "username", "username"), ("Generic", "password", "password"), ("Generic", "secret", "secret")):
    if (access, stype) not in have:
        nb.extras.secrets_groups_associations.create(secrets_group=sg.id, access_type=access,
                                                     secret_type=stype, secret=sec[key].id)
        print(f"  associated {key} with secrets group")

job = nb.extras.jobs.get(name="Sync Devices From Network")
if job is None:
    sys.exit("Sync Devices From Network job not found — is nautobot-device-onboarding installed?")
if not job.enabled:
    job.update({"enabled": True})
    print("  enabled job")

data = {
    "location": site.id,
    "namespace": ns.id,
    "ip_addresses": ",".join(a.ips),
    "port": 22,
    "timeout": 30,
    "secrets_group": sg.id,
    "device_role": role.id,
    "device_status": active.id,
    "interface_status": active.id,
    "ip_address_status": active.id,
    "set_mgmt_only": True,
    "update_devices_without_primary_ip": False,
    "dryrun": False,
    "memory_profiling": False,
    "debug": False,
}
print(f"==> running '{job.name}' for {a.ips}")
result = nb.extras.jobs.run(job_id=job.id, data=data)
jr_id = result.job_result.id if hasattr(result, "job_result") else result["job_result"]["id"]
for _ in range(120):
    jr = nb.extras.job_results.get(jr_id)
    st = str(jr.status)
    if st in ("SUCCESS", "FAILURE", "REVOKED"):
        break
    time.sleep(5)
print(f"==> job result: {st}   {a.url}/extras/job-results/{jr_id}/")
for entry in nb.extras.job_logs.filter(job_result=jr_id):
    if str(entry.log_level) in ("warning", "error", "critical", "failure"):
        print(f"   [{entry.log_level}] {entry.message[:200]}")
if st != "SUCCESS":
    sys.exit(1)
for ip in a.ips:
    dev = nb.dcim.devices.get(primary_ip4=ip) if False else None
for d in nb.dcim.devices.filter(location=site.id):
    print(f"   device {d.name}: type={d.device_type.model} platform={getattr(d.platform,'name',None)} serial={d.serial} primary={getattr(d.primary_ip4,'address',None)}")
