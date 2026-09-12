# Nautobot on the NMS jumphost

Nautobot 3.2 runs on the `nms` VM (10.0.0.10) as a Docker Compose stack:

| Service | Image | Role |
|---|---|---|
| `nautobot` | `cat9000v/nautobot` (built from `networktocode/nautobot:3.2-py3.12` + apps) | web UI + REST/GraphQL API on **:8080** |
| `celery_worker` | same | jobs (Git repos, device sync, …) |
| `celery_beat` | same | scheduled jobs |
| `postgres` | `postgres:16-alpine` | database |
| `redis` | `redis:7-alpine` | cache + Celery broker |
| `volume_init` | (one-shot) | fixes ownership of the named volumes for uid 999 |
| `gitea` | `gitea/gitea:1.24` | Git server for Golden Config repos on **:3000** |

Access from the host (or anything on the OOB network):

- UI: http://10.0.0.10:8080 — `admin` / `admin`
- API: `curl -H "Authorization: Token <token>" http://10.0.0.10:8080/api/status/`
  (the token is printed by `install.sh` and lives in `/opt/nautobot/.env` on the NMS)

## Commands

```bash
../lab.sh nautobot install     # (re)deploy: copies files, generates .env once, pull, up, waits for /health/
../lab.sh nautobot status
../lab.sh nautobot logs 200 nautobot
../lab.sh nautobot down        # stop (data stays in the docker volumes)
../lab.sh nautobot up
```

`install.sh` is idempotent: an existing `/opt/nautobot/.env` (secret key, DB and
Redis passwords, API token) is kept, so re-running it after editing
`docker-compose.yml` is an in-place upgrade. Data lives in named volumes
(`postgres_data`, `redis_data`, `nautobot_media`, `nautobot_git`) on the NMS.

The NMS cloud-init (`nodes/nms/user-data`) now installs `docker.io` +
`docker-compose-v2` and puts `lab` in the `docker` group, so a rebuilt jumphost
only needs `lab.sh nautobot install`. The VM was raised to 8 GB
(`NMS_RAM_MIB` in `lab.conf`) for this stack.

## Apps (plugins)

Built into the image (`Dockerfile`, settings in `nautobot_config.py`, which is
bind-mounted so edits only need `docker compose up -d`):

| App | Used for |
|---|---|
| `nautobot-device-onboarding` | `Sync Devices From Network` — sw1/sw2 were created by SSH discovery (model, serial, platform, mgmt IP) |
| `nautobot-golden-config` | config backups, intended configs, compliance |
| `nautobot-plugin-nornir` | inventory + credentials (`CredentialsNautobotSecrets`: each switch carries the `lab-devices` secrets group) |
| `nautobot-ssot` | dependency of onboarding v5 |
| `nautobot-bgp-models` | first-class BGP objects: Autonomous System 65000, a BGP Routing Instance per switch (router-id = Loopback0), the sw1↔sw2 Peering with Peer Endpoints on the transit SVIs, IPv4 unicast address families |

Device credentials reach the containers as env vars (`LAB_DEVICE_*` in `.env`)
and are referenced by Nautobot *Secrets* (environment-variable provider) —
nothing sensitive is stored in the database.

## Nautobot as the source of truth

```
   switches ──(onboard.py: SSH discovery)──▶ Nautobot ◀──(seed.py: intent bootstrap)── nac/data/devices.nac.yaml
                                               │
                                               └──(render_nac.py)──▶ nac/data/devices.nac.yaml ──▶ terraform (NAC) ──▶ switches
```

| Script / command | What it does |
|---|---|
| `lab.sh nautobot onboard` | location, roles, secrets group; runs *Sync Devices From Network* for the switch IPs |
| `lab.sh nautobot seed` | idempotent bootstrap of the intent: roles, VLAN group + VLANs (with roles), prefixes, interfaces (trunk/access modes, tagged VLANs), SVIs/loopbacks with IPs, primary IPs, cables, hosts + NMS, per-device config context (`bgp.asn`, `stp_priority`), Vlan1 |
| `lab.sh nautobot render [--check]` | regenerates **`nac/data/devices.nac.yaml`** from Nautobot via GraphQL (`--check` only diffs) |
| `lab.sh nautobot golden` | Golden Config setup + backup → intended → compliance run |

Everything device-specific is *generated* from Nautobot:

| Nautobot object | Rendered configuration |
|---|---|
| VLAN group `cat9000v-lab` | VLAN database (incl. `QUARANTINE` 999, `TRANSIT-A` 101) |
| device tags `stp-root` / `stp-backup-root` | `spanning-tree vlan … priority 4096 / 8192` |
| interfaces: mode/untagged/tagged, `lag` | trunk on `Port-channel1`, LACP members, access ports (+portfast/bpduguard), shut + quarantine VLAN for unused ports |
| SVIs / loopbacks with IPs, interface `vrf` | `interface Vlan…` / `Loopback0`, `vrf forwarding` |
| VRFs (`Mgmt-vrf`, `TENANT-A` rd 65000:1) + device/prefix assignments | `vrf definition`, Gi0/0 in Mgmt-vrf |
| global config context `lab-services` | domain, NTP, syslog, SNMP, banner, OOB default route, `MGMT-ACCESS` ACL |
| Interface Redundancy Groups (HSRP) | `standby` config on the host VLAN SVIs (CLI template — HSRP is not in module 0.1.0) |
| BGP app: AS, routing instances, peerings, AFs, `export_policy` | `router bgp` incl. per-VRF address-families, `route-map BGP-OUT` + `prefix-list BGP-ADVERTISE` |
| prefixes tagged `bgp:advertise` | `network` statements (global or VRF, by the interface's VRF) |
| software version | (tested against `show version`) |

`device_groups.nac.yaml` is just group membership; `global.nac.yaml` holds
policy only (hardening, STP defaults, VTP mode, VTY lines). Round trip verified: rendering from Nautobot then `terraform plan`
gives *No changes*, and test `09_nautobot` fails if the committed file drifts
from Nautobot.

The renderer's query is saved in Nautobot as **Extensibility → GraphQL Queries →
`nac-device-model`** (seeded by `seed.py`); open it and press *Run* to execute it
in GraphiQL. `render_nac.py` fetches that saved copy by name (falling back to
its embedded version), so what you run in the GUI is exactly what generates the
YAML. `golden-config-lab` (takes `$device_id`) is the query behind the
intended-config template.

Rules encoded in the renderer: access ports get portfast + bpduguard, trunks
`nonegotiate`, an interface whose prefix has role `transit` provides
`transit_ip`, BGP `network` order is loopback first then ascending (the
provider treats the list as ordered). Nothing about the peering topology is
assumed any more — add a switch or an eBGP uplink by creating the objects.

## Golden Config

A **Gitea** container (`http://10.0.0.10:3000`, user `lab`) hosts three repos
that Nautobot uses as Git repositories: `config-backups`, `intended-configs`,
`golden-config-templates` (`cisco_xe.j2` from `golden-config-templates/`,
rendered from the `golden-config-lab` GraphQL query). 14 compliance features (VLAN database, SVIs incl. HSRP, loopbacks, BGP, BGP
policy, VRFs, management interface, static routes, NTP, syslog, SNMP, banner,
management ACL, port-channel) — **28/28 compliant**. Remediation
(`hierconfig`) is enabled on every rule; test `09_nautobot` deliberately drifts
one SNMP line and checks that Golden Config flags it and proposes the fix.

Two lab changes were needed for that: VTP is now *transparent* (via NAC) so the
VLAN database appears in running-config, and Vlan1 (shutdown) is modelled.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | the stack (deployed to `/opt/nautobot/` on the NMS) |
| `Dockerfile`, `nautobot_config.py` | image with the apps; config with `PLUGINS`/`PLUGINS_CONFIG` |
| `env.example` | all settings; `install.sh` turns it into `.env` with random secrets |
| `install.sh` | deploy / upgrade from the host over SSH (also bootstraps Gitea user/token/repos) |
| `onboard.py`, `seed.py`, `render_nac.py`, `golden_config.py` | see above |
| `golden-config-templates/cisco_xe.j2` | intended-config template (pushed to Gitea) |
