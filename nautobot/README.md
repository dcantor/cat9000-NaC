# Nautobot on the NMS jumphost

Nautobot 3.2 runs on the `nms` VM (10.0.0.10) as a Docker Compose stack:

| Service | Image | Role |
|---|---|---|
| `nautobot` | `networktocode/nautobot:3.2-py3.12` | web UI + REST/GraphQL API on **:8080** |
| `celery_worker` | same | jobs (Git repos, device sync, …) |
| `celery_beat` | same | scheduled jobs |
| `postgres` | `postgres:16-alpine` | database |
| `redis` | `redis:7-alpine` | cache + Celery broker |
| `volume_init` | (one-shot) | fixes ownership of the named volumes for uid 999 |

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

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | the stack (deployed to `/opt/nautobot/` on the NMS) |
| `env.example` | all settings; `install.sh` turns it into `.env` with random secrets |
| `install.sh` | deploy / upgrade from the host over SSH |

The NMS cloud-init (`nodes/nms/user-data`) now installs `docker.io` +
`docker-compose-v2` and puts `lab` in the `docker` group, so a rebuilt jumphost
only needs `lab.sh nautobot install`. The VM was raised to 8 GB
(`NMS_RAM_MIB` in `lab.conf`) for this stack.

## Next steps (not done yet)

- Model the lab in Nautobot: location, device types (C9KV-UADP-8P), sw1/sw2 with
  interfaces, VLANs 10/20/99/100/110-119/210-219, prefixes, IPs — ideally
  generated from the NAC data model so Nautobot becomes the source of truth
  and `nac/data/` is rendered from it.
- Plugins worth adding to the image: `nautobot-device-onboarding` (SSH discovery
  of sw1/sw2), `nautobot-golden-config` (backup/compliance against the NAC
  intent), `nautobot-plugin-nornir`.
