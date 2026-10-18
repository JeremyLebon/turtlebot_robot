#!/bin/bash
# Voorbereiden van de bouwrobot (turtlebot09) vlak voor het inlezen van zijn
# SD-kaart als golden image. Daarna: robot uitschakelen, kaart inlezen met
# sdclone.sh (laptop). Zie docs/todo.md, "Uitrolmethode: SD-kaart klonen".
#
#   sudo ~/turtlebot_setup/tools/golden_prepare.sh [major.minor.patch]
set -eu

SETUP_DIR=/home/turtlebot/turtlebot_setup
[ "$(id -u)" = 0 ] || { echo "Start met sudo."; exit 1; }

echo "🔄 Systeem bijwerken (apt full-upgrade)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get full-upgrade -y -q -o Dpkg::Options::=--force-confold
apt-get autoremove -y -q
apt-get clean

echo "🔄 Repo + Docker-image bijwerken..."
runuser -u turtlebot -- git -C "$SETUP_DIR" pull --ff-only
docker compose --project-directory "$SETUP_DIR" pull
docker image prune -f >/dev/null

# Stempel: zichtbaar op de statuspagina van elke kloon (host_info.json).
# Versie V<major>.<minor>.<patch>.<build>: major.minor.patch kies je zelf
# (eerste argument, bv. "1.0.0" voor een uitrol naar de vloot; zonder
# argument blijft de vorige), build telt altijd op. Bijgehouden op de
# bouwrobot. Historiek: build 1 = eerste kloon naar turtlebot06 (2026-10-07).
VERSION_FILE=/var/lib/turtlebot-setup/golden-version
PREV=$(cat "$VERSION_FILE" 2>/dev/null || echo "0.1.0.1")
BASE="${1:-${PREV%.*}}"
if ! [[ "$BASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Ongeldige versie '$BASE' - verwacht major.minor.patch, bv. 1.0.0"; exit 1
fi
BUILD=$(( ${PREV##*.} + 1 ))
VERSION="$BASE.$BUILD"
mkdir -p "$(dirname "$VERSION_FILE")" && echo "$VERSION" > "$VERSION_FILE"
STAMP="V$VERSION - $(date '+%F %H:%M') - van $(hostname), setup $(runuser -u turtlebot -- git -C "$SETUP_DIR" log -1 --format=%h)"
echo "$STAMP" > /etc/turtlebot-golden
echo "🏷️  $STAMP"

# Opkuisen: niets persoonlijks/tijdelijks meeklonen. De robot-specifieke
# rest (machine-id, SSH-keys, wifi, .env, state/) regelt setup_turtlebot.sh
# op elke kloon zelf.
rm -f /home/turtlebot/.bash_history /root/.bash_history
rm -f "$SETUP_DIR"/state/camera_enabled "$SETUP_DIR"/state/container_starts
# Wifi-wachtwoord van deze robot hoort niet op de kloon van een andere.
# state/terminal_password blijft: dat is op elke robot hetzelfde (docent).
rm -f "$SETUP_DIR"/state/wifi_psk
rm -rf /tmp/* 2>/dev/null || true
# Studentencode van de bouwrobot niet meeklonen (lege workspace laten staan)
rm -rf "$SETUP_DIR"/ros2_ws && runuser -u turtlebot -- mkdir -p "$SETUP_DIR"/ros2_ws/src
journalctl --vacuum-time=1s >/dev/null 2>&1 || true

echo "✅ Klaar. Schakel de robot nu uit (statuspagina of 'sudo poweroff')"
echo "   en lees de kaart in met: sudo bash ~/turtlebot_clone/sdclone.sh read /dev/mmcblk0"
