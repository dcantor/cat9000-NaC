#!/usr/bin/env python3
"""Configure Nautobot Golden Config for the lab and run a configuration backup.

- Secret/SecretsGroup for Gitea (token from the container env GITEA_TOKEN)
- GitRepository objects: config-backups (backup configs), intended-configs,
  golden-config-templates (jinja templates), all hosted on the NMS Gitea
- DynamicGroup "core-switches" (role core-switch)
- GoldenConfigSetting "lab" pointing at the repos, backups as <device>.cfg
- runs the "Backup Configurations" job and waits for it (--no-backup to skip)

Usage: NAUTOBOT_TOKEN=... golden_config.py [--url URL] [--no-backup]
"""
import argparse
import os
import sys
import time

import pynautobot

p = argparse.ArgumentParser()
p.add_argument("--url", default=os.environ.get("NAUTOBOT_URL", "http://10.0.0.10:8080"))
p.add_argument("--token", default=os.environ.get("NAUTOBOT_TOKEN"))
p.add_argument("--gitea", default=os.environ.get("GITEA_URL", "http://10.0.0.10:3000"))
p.add_argument("--gitea-user", default=os.environ.get("GITEA_USER", "lab"))
p.add_argument("--no-backup", action="store_true")
a = p.parse_args()
if not a.token:
    sys.exit("NAUTOBOT_TOKEN (or --token) is required")
nb = pynautobot.api(a.url, token=a.token)
active = nb.extras.statuses.get(name="Active")


def get_or_create(endpoint, lookup, **defaults):
    obj = endpoint.get(**lookup)
    if obj is None:
        obj = endpoint.create(**lookup, **defaults)
        print(f"  created {endpoint.name}: {list(lookup.values())[0]}")
    return obj


# --- Gitea credentials as Nautobot secrets (values come from the container environment)
s_user = get_or_create(nb.extras.secrets, {"name": "gitea-username"}, provider="environment-variable", parameters={"variable": "GITEA_USER"})
s_tok = get_or_create(nb.extras.secrets, {"name": "gitea-token"}, provider="environment-variable", parameters={"variable": "GITEA_TOKEN"})
sg = get_or_create(nb.extras.secrets_groups, {"name": "gitea"})
have = {(x.access_type, x.secret_type) for x in nb.extras.secrets_groups_associations.filter(secrets_group=sg.id)}
for access, stype, sec in (("HTTP(S)", "username", s_user), ("HTTP(S)", "token", s_tok)):
    if (access, stype) not in have:
        nb.extras.secrets_groups_associations.create(secrets_group=sg.id, access_type=access, secret_type=stype, secret=sec.id)

# --- Git repositories
repos = {}
for name, contents in (("config-backups", ["nautobot_golden_config.backupconfigs"]),
                       ("intended-configs", ["nautobot_golden_config.intendedconfigs"]),
                       ("golden-config-templates", ["nautobot_golden_config.jinjatemplate"])):
    repo = nb.extras.git_repositories.get(name=name)
    fields = {"remote_url": f"{a.gitea}/{a.gitea_user}/{name}.git", "branch": "main",
              "secrets_group": sg.id, "provided_contents": contents}
    if repo is None:
        repo = nb.extras.git_repositories.create(name=name, **fields)
        print(f"  created git repository {name}")
    repos[name] = repo

# --- scope: all core switches
dg = nb.extras.dynamic_groups.get(name="core-switches")
if dg is None:
    dg = nb.extras.dynamic_groups.create(name="core-switches", content_type="dcim.device",
                                         group_type="dynamic-filter", filter={"role": ["core-switch"]})
    print("  created dynamic group core-switches")

# --- GraphQL query feeding intended-config templates (SoT aggregation); must start with device_id
gq = nb.extras.graphql_queries.get(name="golden-config-lab")
GQL = """query ($device_id: ID!) {
  device(id: $device_id) {
    name hostname: name platform { network_driver } primary_ip4 { address }
    local_config_context_data
    config_context
    interfaces { name description enabled mode untagged_vlan { vid } tagged_vlans { vid } vrf { name }
                 ip_addresses { address parent { prefix tags { name } } } }
    location { vlan_groups { vlans { vid name } } }
    bgp_routing_instances {
      autonomous_system { asn }
      router_id { address }
      extra_attributes
      endpoints {
        description enabled
        address_families { afi_safi }
        peer { source_ip { address } autonomous_system { asn } }
      }
    }
  }
}"""
if gq is None:
    gq = nb.extras.graphql_queries.create(name="golden-config-lab", query=GQL)
    print("  created GraphQL query golden-config-lab")
elif gq.query != GQL:
    gq.update({"query": GQL})

# --- Golden Config settings
gcs_ep = nb.plugins.golden_config.golden_config_settings
default = gcs_ep.get(name="Default Settings")     # plugin-created, matches every device: remove it
if default is not None:
    default.delete()
    print("  removed plugin 'Default Settings'")
gcs = gcs_ep.get(name="lab")
fields = {"slug": "lab", "weight": 1000, "dynamic_group": dg.id,
          "backup_repository": repos["config-backups"].id, "backup_path_template": "{{obj.name}}.cfg",
          "backup_test_connectivity": False,
          "intended_repository": repos["intended-configs"].id, "intended_path_template": "{{obj.name}}.cfg",
          "jinja_repository": repos["golden-config-templates"].id, "jinja_path_template": "{{obj.platform.network_driver}}.j2",
          "sot_agg_query": gq.id}
if gcs is None:
    gcs = gcs_ep.create(name="lab", **fields)
    print("  created golden config setting 'lab'")
else:
    gcs.update(fields)

# --- Jinja template -> Gitea (golden-config-templates repo), then compliance features/rules
import base64, requests
from pathlib import Path
tpl = Path(__file__).resolve().parent / "golden-config-templates" / "cisco_xe.j2"
gitea_pw = os.environ.get("GITEA_PASSWORD")
if gitea_pw:
    api = f"{a.gitea}/api/v1/repos/{a.gitea_user}/golden-config-templates/contents/cisco_xe.j2"
    cur = requests.get(api, auth=(a.gitea_user, gitea_pw), timeout=30)
    body = {"content": base64.b64encode(tpl.read_bytes()).decode(), "branch": "main",
            "message": "cisco_xe.j2 from cat9000v lab"}
    if cur.status_code == 200:
        if base64.b64decode(cur.json()["content"]) != tpl.read_bytes():
            body["sha"] = cur.json()["sha"]
            requests.put(api, auth=(a.gitea_user, gitea_pw), json=body, timeout=30).raise_for_status()
            print("  updated cisco_xe.j2 in Gitea")
    else:
        requests.post(api, auth=(a.gitea_user, gitea_pw), json=body, timeout=30).raise_for_status()
        print("  pushed cisco_xe.j2 to Gitea")
else:
    print("  (GITEA_PASSWORD not set: template not pushed)")

plat = nb.dcim.platforms.get(name="cisco_xe")
feat_ep = nb.plugins.golden_config.compliance_feature
rule_ep = nb.plugins.golden_config.compliance_rule
for slug, name, match in (("vlan", "VLAN database", "vlan"),
                          ("loopback", "Loopbacks", "interface Loopback"),
                          ("svi", "SVIs", "interface Vlan"),
                          ("bgp", "BGP", "router bgp"),
                          ("mgmt-interface", "Management interface", "interface GigabitEthernet0/0"),
                          ("static-routes", "Static routes", "ip route"),
                          ("ntp", "NTP", "ntp server"),
                          ("syslog", "Syslog", "logging host"),
                          ("snmp", "SNMP", "snmp-server community\nsnmp-server location\nsnmp-server contact\nsnmp-server host"),
                          ("banner", "Banner", "banner motd"),
                          ("mgmt-acl", "Management ACL", "ip access-list standard MGMT-ACCESS")):
    feat = feat_ep.get(slug=slug) or feat_ep.create(slug=slug, name=name, description=f"{name} (from Nautobot)")
    rule = rule_ep.get(feature=feat.id, platform=plat.id)
    fields = {"feature": feat.id, "platform": plat.id, "config_type": "cli", "match_config": match,
              "config_ordered": False, "config_remediation": False}
    if rule is None:
        rule_ep.create(**fields)
        print(f"  created compliance rule {slug}")

if a.no_backup:
    sys.exit(0)

# --- run backup -> intended -> compliance
devs = [d.id for d in nb.dcim.devices.filter(role="core-switch")]
def run_job(name):
    job = nb.extras.jobs.get(name=name)
    if not job.enabled:
        job.update({"enabled": True})
    print(f"==> running '{name}' for {len(devs)} devices")
    res = nb.extras.jobs.run(job_id=job.id, data={"device": devs, "debug": False})
    jr_id = res.job_result.id
    for _ in range(120):
        st = str(nb.extras.job_results.get(jr_id).status)
        if st in ("SUCCESS", "FAILURE", "REVOKED"):
            break
        time.sleep(5)
    errors = [e for e in nb.extras.job_logs.filter(job_result=jr_id) if str(e.log_level) in ("error", "critical", "failure")]
    print(f"    {st}   {a.url}/extras/job-results/{jr_id}/")
    for e in errors:
        print(f"   [{e.log_level}] {e.message[:300]}")
    return st == "SUCCESS" and not errors

ok = run_job("Backup Configurations") and run_job("Generate Intended Configurations") and run_job("Perform Configuration Compliance")
for c in nb.plugins.golden_config.config_compliance.all():
    print(f"   compliance {c.device.name if hasattr(c.device,'name') else c.device} / {c.rule}: {'COMPLIANT' if c.compliance else 'NON-COMPLIANT'}")
sys.exit(0 if ok else 1)
