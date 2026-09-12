#!/usr/bin/env bash
# Deploy (or update) Nautobot on the NMS jumphost with Docker Compose.
#   nautobot/install.sh            # copy files, generate .env if missing, pull, up, wait for /health/
# Re-runnable: an existing .env (and therefore the data) is kept.
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$here/../lab.conf"
nms="${MGMT_IP[nms]}"
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
run() { ssh "${ssh_opts[@]}" "lab@$nms" "$@"; }

echo "==> copying deployment files to lab@$nms:/opt/nautobot"
run 'sudo mkdir -p /opt/nautobot && sudo chown lab:lab /opt/nautobot'
scp -q "${ssh_opts[@]}" "$here/docker-compose.yml" "$here/env.example" "lab@$nms:/opt/nautobot/"

echo "==> .env (generated once; secrets are random)"
run 'cd /opt/nautobot && if [ ! -f .env ]; then
  sed -e "s|^NAUTOBOT_SECRET_KEY=.*|NAUTOBOT_SECRET_KEY=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 50)|" \
      -e "s|^NAUTOBOT_SUPERUSER_API_TOKEN=.*|NAUTOBOT_SUPERUSER_API_TOKEN=$(tr -dc a-f0-9 </dev/urandom | head -c 40)|" \
      -e "s|^NAUTOBOT_DB_PASSWORD=.*|NAUTOBOT_DB_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)|" \
      -e "s|^NAUTOBOT_REDIS_PASSWORD=.*|NAUTOBOT_REDIS_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)|" \
      env.example > .env && chmod 600 .env && echo "    created"; else echo "    kept existing .env"; fi'

echo "==> docker compose pull + up"
run 'cd /opt/nautobot && sg docker -c "docker compose pull -q && docker compose up -d --remove-orphans"'

echo "==> waiting for Nautobot (first start: migrations + superuser, a few minutes)"
for _ in $(seq 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$nms:8080/health/" || true)"
  [[ "$code" == "200" ]] && break
  sleep 10
done
[[ "${code:-}" == "200" ]] || { echo "Nautobot did not become healthy; check: nautobot/install.sh logs" >&2; run 'cd /opt/nautobot && sg docker -c "docker compose ps"'; exit 1; }
run 'cd /opt/nautobot && sg docker -c "docker compose ps --format \"table {{.Service}}\t{{.Status}}\""'
echo
echo "Nautobot is up:  http://$nms:8080   (admin / admin)"
echo "API token:       $(run 'grep ^NAUTOBOT_SUPERUSER_API_TOKEN /opt/nautobot/.env | cut -d= -f2')"
