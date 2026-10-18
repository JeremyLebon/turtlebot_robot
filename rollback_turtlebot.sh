#!/bin/bash
# ~/turtlebot_setup/rollback_turtlebot.sh - uitgevoerd door
# turtlebot-rollback.service (als root): terug naar de image van voor de
# laatste update (:vorige, bewaard door update_turtlebot.sh). Werkt zonder
# internet. Wisselt de twee images om: nog eens uitvoeren = terug naar de
# nieuwe. "Software bijwerken" haalt daarna gewoon weer de nieuwste op.
# Enkel de Docker-image; de setup-repo (scripts) blijft zoals ze is.

set -eu

SETUP_DIR="/home/turtlebot/turtlebot_setup"
STATUS_FILE="$SETUP_DIR/state/update_status.txt"

status() {
  echo "$1"
  printf '%s\n' "$1" > "$STATUS_FILE" || true
}
fail() {
  status "❌ $1"
  exit 1
}

IMAGE_REF=$(docker compose --project-directory "$SETUP_DIR" config --images | head -1)
PREV_REF="${IMAGE_REF%:*}:vorige"
CUR_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE_REF" 2>/dev/null) || fail "huidige image niet gevonden"
PREV_ID=$(docker image inspect -f '{{.Id}}' "$PREV_REF" 2>/dev/null) \
  || fail "geen vorige versie bewaard (pas na de volgende update, of te weinig schijfruimte)"
version() {
  docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" \
    | sed -n 's/^TURTLEBOT_IMAGE_VERSION=//p'
}

status "⏪ Terug naar vorige versie ($(version "$PREV_ID"))"
docker tag "$PREV_ID" "$IMAGE_REF"
docker tag "$CUR_ID" "$PREV_REF"
docker compose --project-directory "$SETUP_DIR" up -d \
  || fail "docker compose up mislukt - details: journalctl -u turtlebot-rollback"
# host_info.json opnieuw (image-digest/versie voor de statuspagina)
"$SETUP_DIR/setup_turtlebot.sh" >/dev/null
status "✅ Teruggeschakeld naar $(version "$PREV_ID") - nog eens terugschakelen = terug naar $(version "$CUR_ID")"
