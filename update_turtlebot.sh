#!/bin/bash
# ~/turtlebot_setup/update_turtlebot.sh - uitgevoerd door
# turtlebot-update.service (als root): repo bijwerken, nieuwste image
# ophalen en de container enkel opnieuw aanmaken als er iets veranderde.

set -eu

SETUP_USER="turtlebot"
SETUP_DIR="/home/$SETUP_USER/turtlebot_setup"
# Laatste stap / fout, getoond op system.html (state/ is in de container
# gemount op /root/turtlebot_state, gelezen door launch_control_node)
STATUS_FILE="$SETUP_DIR/state/update_status.txt"

status() {
  echo "$1"
  mkdir -p "$SETUP_DIR/state"
  printf '%s\n' "$1" > "$STATUS_FILE" || true
}
fail() {
  status "❌ $1"
  exit 1
}

# --- Internet? ---------------------------------------------------------------
# Zonder deze check blijven git/docker hangen op DNS- en connect-timeouts
# (AP zonder werkende WAN-uplink).
status "🔎 Internetverbinding controleren"
online() {
  timeout 10 bash -c ">/dev/tcp/$1/443" 2>/dev/null
}
if ! online 1.1.1.1 && ! online 8.8.8.8; then
  fail "Geen internet via de AP (WAN-poort van de AP niet verbonden?) - update niet mogelijk"
fi
for host in github.com registry-1.docker.io; do
  getent hosts "$host" >/dev/null || fail "Internet wel, maar DNS werkt niet ($host) - update niet mogelijk"
  online "$host" || fail "$host niet bereikbaar - update niet mogelijk"
done

status "🔄 Setup-repo bijwerken (git pull)"
timeout 120 runuser -u "$SETUP_USER" -- git -C "$SETUP_DIR" pull --ff-only \
  || fail "git pull mislukt - details: journalctl -u turtlebot-update"

# Setup opnieuw (nieuwe CSV/units/.env uit de pull toepassen)
status "⚙️ Setup toepassen"
"$SETUP_DIR/setup_turtlebot.sh" || fail "setup_turtlebot.sh mislukt - details: journalctl -u turtlebot-update"

# Huidige image onthouden: na de pull wordt ze :vorige (terugschakelen met
# rollback_turtlebot.sh, ook zonder internet)
IMAGE_REF=$(docker compose --project-directory "$SETUP_DIR" config --images | head -1)
OLD_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE_REF" 2>/dev/null || true)

status "⬇️ Nieuwe image ophalen (docker compose pull, kan enkele minuten duren)"
docker compose --project-directory "$SETUP_DIR" pull \
  || fail "docker compose pull mislukt - details: journalctl -u turtlebot-update"

NEW_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE_REF" 2>/dev/null || true)
if [ -n "$OLD_ID" ] && [ "$OLD_ID" != "$NEW_ID" ]; then
  # Enkel de verschillende lagen kosten ruimte; toch nooit de kaart vol laten
  # lopen (turtlebot09: 32 GB + buildkit-cache)
  FREE_GB=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
  if [ "$FREE_GB" -ge 5 ]; then
    docker tag "$OLD_ID" "${IMAGE_REF%:*}:vorige"
    echo "💾 Vorige image bewaard als ${IMAGE_REF%:*}:vorige"
  else
    docker rmi "${IMAGE_REF%:*}:vorige" >/dev/null 2>&1 || true
    echo "⚠️ Slechts ${FREE_GB} GB vrij - vorige image niet bewaard (geen terugschakelen mogelijk)"
  fi
fi

# Herstart enkel als image of compose-config veranderde
status "🔁 Container bijwerken"
docker compose --project-directory "$SETUP_DIR" up -d \
  || fail "docker compose up mislukt - details: journalctl -u turtlebot-update"
docker image prune -f >/dev/null
# host_info.json opnieuw (nieuwe image-digest/commits voor de statuspagina)
"$SETUP_DIR/setup_turtlebot.sh" >/dev/null
status "🎉 Update voltooid"
