#!/bin/bash
# ~/turtlebot_setup/install_version.sh <versie> - uitgevoerd door
# turtlebot-install@<versie>.service (als root), gestart vanuit Beheer ›
# Software › *Versie kiezen*: een vaste, getagde image-versie (bv. v0.20.0)
# installeren, bv. om een hele klas tijdens een les op dezelfde versie te
# houden. De huidige image wordt :vorige (Terug naar vorige versie werkt dus
# ook hierna). De volgende *Software bijwerken* haalt weer de nieuwste.
# Enkel de Docker-image; de setup-repo (scripts) blijft zoals ze is.

set -eu

SETUP_DIR="/home/turtlebot/turtlebot_setup"
STATUS_FILE="$SETUP_DIR/state/update_status.txt"
TAG="${1:-}"

status() {
  echo "$1"
  printf '%s\n' "$1" > "$STATUS_FILE" || true
}
fail() {
  status "❌ $1"
  exit 1
}

# Enkel getagde versies (vX.Y.Z), nooit een willekeurige image
[[ "$TAG" =~ ^v[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || fail "ongeldige versie: '$TAG'"

IMAGE_REF=$(docker compose --project-directory "$SETUP_DIR" config --images | head -1)
REPO="${IMAGE_REF%:*}"
WANT="$REPO:$TAG"
version() {
  docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" \
    | sed -n 's/^TURTLEBOT_IMAGE_VERSION=//p'
}

if ! docker image inspect "$WANT" >/dev/null 2>&1; then
  status "🔎 Internetverbinding controleren"
  timeout 10 bash -c ">/dev/tcp/registry-1.docker.io/443" 2>/dev/null \
    || fail "Docker Hub niet bereikbaar (internet via de AP?) - $TAG niet op deze robot"
  status "⬇️ Versie $TAG ophalen (kan enkele minuten duren)"
  timeout 25m docker pull -q "$WANT" >/dev/null || fail "$TAG ophalen mislukt - details: journalctl -u 'turtlebot-install@*'"
fi

NEW_ID=$(docker image inspect -f '{{.Id}}' "$WANT")
OLD_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE_REF" 2>/dev/null || true)
if [ "$NEW_ID" = "$OLD_ID" ]; then
  status "✅ $TAG draait al op deze robot"
  exit 0
fi
# Zoals update_turtlebot.sh: huidige bewaren als :vorige als er plaats is
if [ -n "$OLD_ID" ]; then
  FREE_GB=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
  if [ "$FREE_GB" -ge 5 ]; then
    docker tag "$OLD_ID" "$REPO:vorige"
  else
    docker rmi "$REPO:vorige" >/dev/null 2>&1 || true
    echo "⚠️ Slechts ${FREE_GB} GB vrij - vorige image niet bewaard"
  fi
fi

status "🔁 Versie $TAG installeren (container herstart)"
docker tag "$NEW_ID" "$IMAGE_REF"
docker compose --project-directory "$SETUP_DIR" up -d \
  || fail "docker compose up mislukt - details: journalctl -u 'turtlebot-install@*'"
docker image prune -f >/dev/null
# host_info.json opnieuw (image-digest/versie voor de statuspagina)
"$SETUP_DIR/setup_turtlebot.sh" >/dev/null
status "✅ $(version "$NEW_ID") geïnstalleerd - Software bijwerken haalt weer de nieuwste"
