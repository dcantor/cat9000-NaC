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
scp -q "${ssh_opts[@]}" "$here/docker-compose.yml" "$here/env.example" "$here/Dockerfile" "$here/nautobot_config.py" "lab@$nms:/opt/nautobot/"

echo "==> .env (generated once; secrets are random)"
run 'cd /opt/nautobot && if [ ! -f .env ]; then
  sed -e "s|^NAUTOBOT_SECRET_KEY=.*|NAUTOBOT_SECRET_KEY=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 50)|" \
      -e "s|^NAUTOBOT_SUPERUSER_API_TOKEN=.*|NAUTOBOT_SUPERUSER_API_TOKEN=$(tr -dc a-f0-9 </dev/urandom | head -c 40)|" \
      -e "s|^NAUTOBOT_DB_PASSWORD=.*|NAUTOBOT_DB_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)|" \
      -e "s|^NAUTOBOT_REDIS_PASSWORD=.*|NAUTOBOT_REDIS_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)|" \
      -e "s|^GITEA_PASSWORD=.*|GITEA_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)|" \
      env.example > .env && chmod 600 .env && echo "    created"; else echo "    kept existing .env"; fi'

echo "==> docker compose build (base image + lab apps) + up"
run 'cd /opt/nautobot && sg docker -c "docker compose pull -q postgres redis gitea && docker compose build -q && docker compose up -d --remove-orphans"'

echo "==> gitea: admin user + API token (once)"
run 'cd /opt/nautobot && set -a && . ./.env && set +a
  for _ in $(seq 30); do curl -sf http://localhost:3000/api/healthz >/dev/null && break; sleep 3; done
  # keys added to .env by older installs
  grep -q ^GITEA_USER= .env || printf "NMS_IP=10.0.0.10\nGITEA_USER=lab\nGITEA_PASSWORD=%s\nGITEA_TOKEN=\n" "$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)" >> .env
  set -a && . ./.env && set +a
  if ! curl -sf -u "$GITEA_USER:$GITEA_PASSWORD" http://localhost:3000/api/v1/user >/dev/null; then
    sg docker -c "docker compose exec -T -u git gitea gitea admin user create --admin --username $GITEA_USER --password $GITEA_PASSWORD --email $GITEA_USER@lab.local --must-change-password=false" >/dev/null && echo "    created gitea user $GITEA_USER"
  fi
  if [ -z "$GITEA_TOKEN" ]; then
    tok=$(curl -sf -u "$GITEA_USER:$GITEA_PASSWORD" -H "Content-Type: application/json" -X POST http://localhost:3000/api/v1/users/$GITEA_USER/tokens -d "{\"name\":\"nautobot-$(date +%s)\",\"scopes\":[\"write:repository\",\"read:user\"]}" | sed -n "s/.*\"sha1\":\"\([a-f0-9]*\)\".*/\1/p")
    [ -n "$tok" ] && sed -i "s|^GITEA_TOKEN=.*|GITEA_TOKEN=$tok|" .env && echo "    created gitea API token"
    sg docker -c "docker compose up -d nautobot celery_worker celery_beat" >/dev/null   # pick up GITEA_TOKEN
  fi
  for repo in config-backups intended-configs golden-config-templates; do
    curl -sf -u "$GITEA_USER:$GITEA_PASSWORD" http://localhost:3000/api/v1/repos/$GITEA_USER/$repo >/dev/null || \
      curl -sf -u "$GITEA_USER:$GITEA_PASSWORD" -H "Content-Type: application/json" -X POST http://localhost:3000/api/v1/user/repos -d "{\"name\":\"$repo\",\"auto_init\":true,\"default_branch\":\"main\",\"private\":false}" >/dev/null && echo "    created repo $repo"
  done'

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
echo "Gitea:           http://$nms:3000   (lab / see GITEA_PASSWORD in /opt/nautobot/.env)"
echo "API token:       $(run 'grep ^NAUTOBOT_SUPERUSER_API_TOKEN /opt/nautobot/.env | cut -d= -f2')"
