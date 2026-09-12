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

What is modelled in Nautobot is *generated*: the VLAN database, switchport
modes/allowed VLANs, SVIs and loopbacks with addresses, STP priorities, the BGP
networks each switch originates, management addresses. `device_groups.nac.yaml`
keeps only the iBGP peering skeleton and `global.nac.yaml` the services and
hardening. Round trip verified: rendering from Nautobot then `terraform plan`
gives *No changes*, and test `09_nautobot` fails if the committed file drifts
from Nautobot.

Rules encoded in the renderer: access ports get portfast + bpduguard, trunks
`nonegotiate`, prefixes with role `transit` are excluded from BGP, Loopback0 is
the router-id, the iBGP peer is the other core switch's transit address.

## Golden Config

A **Gitea** container (`http://10.0.0.10:3000`, user `lab`) hosts three repos
that Nautobot uses as Git repositories: `config-backups`, `intended-configs`,
`golden-config-templates` (`cisco_xe.j2` from `golden-config-templates/`,
rendered from the `golden-config-lab` GraphQL query). Compliance features:
VLAN database, SVIs, Loopbacks — all **compliant** on both switches.

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
