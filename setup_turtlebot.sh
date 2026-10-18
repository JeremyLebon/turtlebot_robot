#!/bin/bash
# ~/turtlebot_setup/setup_turtlebot.sh (rechtstreeks uit de git-clone, zodat
# een `git pull` ook dit script bijwerkt)
#
# Per-robot configuratie, bij elke boot uitgevoerd door
# turtlebot-setup.service (als root). De robot wordt herkend aan het
# MAC-adres van wlan0 via turtlebot_config.csv. Zo kan één SD-kaart
# (golden image) naar alle robots gekloond worden: dit script maakt er bij
# de eerste boot op een ander bord een turtlebot<nr> van.
#
# Idempotent: doet enkel iets als er effectief iets verschilt.

set -u

SETUP_USER="turtlebot"
SETUP_DIR="${SETUP_DIR:-/home/$SETUP_USER/turtlebot_setup}"   # clone van turtlebot_setup
CONFIG_FILE="${CONFIG_FILE:-$SETUP_DIR/turtlebot_config.csv}"
NET_IFACE="wlan0"
STATE_DIR="/var/lib/turtlebot-setup"
BUILD_ROBOT_NR=9   # enkel deze robot bouwt images (buildx-builder "rpi5")

# Lees MAC-adres
MAC=$(tr '[:lower:]' '[:upper:]' < /sys/class/net/$NET_IFACE/address)

# Zoek configuratie
LINE=$(grep -i ",$MAC," "$CONFIG_FILE")

if [ -z "$LINE" ]; then
  echo "⚠️ Geen match gevonden voor MAC $MAC in $CONFIG_FILE"
  exit 1
fi

# Parse CSV (nr,mac,hostname,ros_domain_id,lidar,camera)
IFS=',' read -r NR CSV_MAC HOSTNAME ROS_DOMAIN_ID LIDAR CAMERA <<< "$LINE"
CAMERA=$(echo "${CAMERA:-false}" | tr -d '[:space:]')
NR2=$(printf '%02d' "$NR")

echo "✅ Instellingen gevonden voor $HOSTNAME (nr $NR, ROS_DOMAIN_ID=$ROS_DOMAIN_ID)"

# --- Rootpartitie vergroten --------------------------------------------------
# De golden image is ingekrompen met PiShrink -s (zonder diens rc.local-
# auto-expand, die zou met de identiteits-reboot hieronder botsen). Hier groeit de
# rootpartitie online tot het einde van de kaart, als er meer dan 1 GB vrij is.
ROOT_PART=$(findmnt -no SOURCE /)                       # bv. /dev/mmcblk0p2
ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_PART")"       # bv. /dev/mmcblk0
PART_NR=$(cat "/sys/class/block/$(basename "$ROOT_PART")/partition")
DISK_SECTORS=$(cat "/sys/class/block/$(basename "$ROOT_DISK")/size")
PART_END=$(( $(cat "/sys/class/block/$(basename "$ROOT_PART")/start") + \
             $(cat "/sys/class/block/$(basename "$ROOT_PART")/size") ))
if [ $(( DISK_SECTORS - PART_END )) -gt $(( 2 * 1024 * 1024 )) ]; then   # 512 B-sectoren
  echo "💾 Rootpartitie vergroten tot het einde van de kaart..."
  growpart "$ROOT_DISK" "$PART_NR" && resize2fs "$ROOT_PART" \
    && echo "✅ Rootpartitie vergroot: $(df -h / | awk 'NR==2 {print $2}')"
fi

# --- Hostname ----------------------------------------------------------------
if [ "$(hostname)" != "$HOSTNAME" ]; then
  hostnamectl set-hostname "$HOSTNAME"
  echo "✅ Hostname ingesteld op $HOSTNAME"
fi
# /etc/hosts mee aanpassen, anders kan sudo de hostname niet herleiden
# (wacht dan telkens op een DNS-timeout).
if grep -q '^127\.0\.1\.1' /etc/hosts; then
  sed -i "s/^127\.0\.1\.1\s.*/127.0.1.1\t\t$HOSTNAME/" /etc/hosts
else
  printf '127.0.1.1\t\t%s\n' "$HOSTNAME" >> /etc/hosts
fi

# --- Unieke identiteit na het klonen --------------------------------------
# Een gekloonde kaart heeft dezelfde machine-id (DHCP-client-ID) en SSH-
# host-keys als het origineel. Eenmalig per MAC-adres opnieuw genereren;
# daarna een reboot zodat alle services de nieuwe machine-id gebruiken.
# Na de hostname, zodat de nieuwe SSH-keys root@<nieuwe hostname> heten.
REBOOT_NEEDED=false
mkdir -p "$STATE_DIR"
IDENTITY_MARKER="$STATE_DIR/identity-$(echo "$MAC" | tr -d ':')"
if [ ! -f "$IDENTITY_MARKER" ]; then
  echo "🔑 Nieuw bord ($MAC): machine-id en SSH-host-keys opnieuw genereren"
  rm -f "$STATE_DIR"/identity-*
  rm -f /etc/machine-id
  systemd-machine-id-setup
  rm -f /etc/ssh/ssh_host_*
  ssh-keygen -A
  touch "$IDENTITY_MARKER"
  REBOOT_NEEDED=true
fi

# Journal-mappen van een andere machine-id (meegekloond van het origineel)
for d in /var/log/journal/*/; do
  [ "$(basename "$d")" = "$(cat /etc/machine-id)" ] || rm -rf "$d"
done

# Avahi herstarten zodat de nieuwe hostname meteen zichtbaar is via .local
if systemctl cat avahi-daemon.service >/dev/null 2>&1; then
  systemctl restart avahi-daemon
else
  echo "⚠️ Avahi-daemon niet gevonden — controleer of Avahi is geïnstalleerd."
fi

# --- Wifi: eigen access point TB-AP-<nr> -------------------------------------
# Profielen van andere robots (bv. TB-AP-09 op een kloon van turtlebot09)
# worden verwijderd.
#
# Het wifi-wachtwoord staat NIET in deze (publieke) repo. Het staat lokaal op
# de robot in state/wifi_psk (buiten git) en dient ook als wachtwoord van de
# webterminal (TERMINAL_PASSWORD in .env). Bron, in volgorde:
#   1. state/wifi_psk (al aanwezig)
#   2. /boot/firmware/turtlebot_wifi_psk - na het flashen/klonen van een kaart
#      op de laptop aanmaken (één regel: het wachtwoord); wordt verplaatst
#   3. het bestaande wifi-profiel TB-AP-<nr> van deze robot
AP_NAME="TB-AP-$NR2"
PSK_FILE="$SETUP_DIR/state/wifi_psk"
BOOT_PSK=/boot/firmware/turtlebot_wifi_psk
mkdir -p "$SETUP_DIR/state"
if [ -s "$BOOT_PSK" ]; then
  tr -d '\r\n' < "$BOOT_PSK" > "$PSK_FILE" && rm -f "$BOOT_PSK" \
    && echo "🔑 Wifi-wachtwoord overgenomen uit $BOOT_PSK"
elif [ ! -s "$PSK_FILE" ] && nmcli -t -f NAME connection show | grep -qx "$AP_NAME"; then
  nmcli -s -g 802-11-wireless-security.psk connection show "$AP_NAME" 2>/dev/null \
    | tr -d '\r\n' > "$PSK_FILE"
  [ -s "$PSK_FILE" ] && echo "🔑 Wifi-wachtwoord overgenomen uit het profiel $AP_NAME"
fi
chmod 600 "$PSK_FILE" 2>/dev/null
AP_PSK=$(cat "$PSK_FILE" 2>/dev/null)

for con in $(nmcli -t -f NAME connection show | grep '^TB-AP-'); do
  if [ "$con" != "$AP_NAME" ]; then
    nmcli connection delete "$con" && echo "🗑️ Wifi-profiel $con verwijderd"
  fi
done
if ! nmcli -t -f NAME connection show | grep -qx "$AP_NAME"; then
  if [ -n "$AP_PSK" ]; then
    nmcli connection add type wifi ifname "$NET_IFACE" con-name "$AP_NAME" \
      ssid "$AP_NAME" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$AP_PSK" \
      connection.autoconnect yes connection.autoconnect-priority 100 \
      && echo "✅ Wifi-profiel $AP_NAME aangemaakt"
  else
    echo "⚠️ Geen wifi-wachtwoord voor $AP_NAME: zet het in $BOOT_PSK (SD-kaart) of $PSK_FILE"
  fi
elif [ -n "$AP_PSK" ]; then
  # Wachtwoord gewijzigd (nieuw bestand)? Profiel bijwerken.
  [ "$(nmcli -s -g 802-11-wireless-security.psk connection show "$AP_NAME" 2>/dev/null)" = "$AP_PSK" ] \
    || nmcli connection modify "$AP_NAME" wifi-sec.psk "$AP_PSK"
fi
# Ook op een bestaand profiel zetten (op turtlebot09 was TB-AP-09 met de hand
# aangemaakt, met prioriteit 0 - even hoog als RobotWifi enz.). Oneindig opnieuw
# proberen: start de robot voor zijn AP (die trager opstart), dan blokkeert
# NetworkManager het profiel anders ~5 min na enkele pogingen.
nmcli connection modify "$AP_NAME" connection.autoconnect yes \
  connection.autoconnect-priority 100 connection.autoconnect-retries 0

# Andere wifi-profielen (RobotWifi, Wifi_turtlebots, het profiel van Raspberry
# Pi Imager, ...) verwijderen: NetworkManager schakelt niet zelf over van een
# verbonden netwerk naar een met hogere prioriteit, dus een robot die bij het
# opstarten zijn AP nog niet zag, bleef op dat andere netwerk hangen. Enkel als
# de eigen AP effectief zichtbaar is - anders zit een robot waarvan de AP nog
# niet geconfigureerd is nergens meer op.
if nmcli -t -f SSID device wifi list ifname "$NET_IFACE" --rescan yes 2>/dev/null | grep -qx "$AP_NAME"; then
  nmcli -t -f NAME,TYPE connection show | while IFS=: read -r con type; do
    if [ "$type" = "802-11-wireless" ] && [ "$con" != "$AP_NAME" ]; then
      nmcli connection delete "$con" >/dev/null && echo "🗑️ Wifi-profiel $con verwijderd"
    fi
  done
else
  echo "⚠️ $AP_NAME niet zichtbaar - andere wifi-profielen blijven staan"
fi

# Mag mislukken (AP nog niet geconfigureerd/buiten bereik): autoconnect
# probeert het later opnieuw.
if ! nmcli -t -f NAME connection show --active | grep -qx "$AP_NAME"; then
  nmcli --wait 20 connection up "$AP_NAME" >/dev/null 2>&1 \
    || echo "⚠️ $AP_NAME (nog) niet bereikbaar"
fi

# --- Systeembestanden uit de repo -------------------------------------------
# systemd-units en polkit-regel uit de clone naar /etc kopiëren als ze
# verschillen, zodat een `git pull` ze ook bijwerkt.
install_if_changed() {  # bron doel modus
  if ! cmp -s "$1" "$2"; then
    install -D -m "$3" "$1" "$2" && echo "✅ $2 bijgewerkt" && return 0
  fi
  return 1
}
UNITS_CHANGED=false
for unit in turtlebot-setup.service turtlebot-update.service turtlebot-rollback.service \
            turtlebot-usb-power@.service; do
  install_if_changed "$SETUP_DIR/systemd/$unit" "/etc/systemd/system/$unit" 644 \
    && UNITS_CHANGED=true
done
[ "$UNITS_CHANGED" = true ] && systemctl daemon-reload
install_if_changed "$SETUP_DIR/polkit/50-turtlebot-networkmanager.rules" \
  /etc/polkit-1/rules.d/50-turtlebot-networkmanager.rules 644

# uhubctl: USB-stroom aan/uit (lidar-spaarstand, usb_power_host.sh). Mag
# mislukken zonder internet - dan blijft de USB-stroom gewoon aan.
if ! command -v uhubctl >/dev/null; then
  apt-get install -y uhubctl >/dev/null 2>&1 && echo "✅ uhubctl geïnstalleerd" \
    || echo "⚠️ uhubctl niet geïnstalleerd (geen internet?) - USB-spaarstand werkt niet"
fi

# Swap enkel als zram (geen /var/swap van 2 GB op de SD-kaart), actief na
# de volgende herstart
install_if_changed "$SETUP_DIR/rpi/swap-turtlebot.conf" \
  /etc/rpi/swap.conf.d/50-turtlebot.conf 644 \
  && echo "ℹ️ Swap-instelling gewijzigd - actief na een herstart"

# Desktop standaard uit (tekstmodus: ~400 MB RAM minder, geen nutteloze
# processen); actief na de volgende herstart. Desktop terug op een robot:
#   echo true > ~/turtlebot_setup/state/desktop   (+ herstart)
if [ "$(cat "$SETUP_DIR/state/desktop" 2>/dev/null)" = true ]; then
  WANT_TARGET=graphical.target
else
  WANT_TARGET=multi-user.target
fi
if [ "$(systemctl get-default)" != "$WANT_TARGET" ]; then
  systemctl set-default "$WANT_TARGET" >/dev/null 2>&1 \
    && echo "ℹ️ Opstartmodus $WANT_TARGET - actief na een herstart"
fi

# Persistente journal (Raspberry Pi OS staat standaard op volatile), zodat
# `journalctl -b -1` na een crash/shutdown nog werkt. Begrensd tot 100 MB.
install_if_changed "$SETUP_DIR/systemd/journald-turtlebot.conf" \
  /etc/systemd/journald.conf.d/50-turtlebot.conf 644 \
  && systemctl restart systemd-journald && journalctl --flush

# NTP: vaste servers (Belgische pool, Debian als terugval)
install_if_changed "$SETUP_DIR/systemd/timesyncd-turtlebot.conf" \
  /etc/systemd/timesyncd.conf.d/50-turtlebot.conf 644 \
  && systemctl restart systemd-timesyncd

# --- Host-info voor de statuspagina -------------------------------------------
# De container ziet de host-software niet; schrijf ze in state/host_info.json
# (bind-mounted in de container, gelezen door system_info_node).
# /etc/turtlebot-golden: stempel gezet door tools/golden_prepare.sh bij het
# maken van de golden image, meegekloond naar elke robot.
write_host_info() {
  # maps/: map_saver maakt geen mappen aan -> eerste "Kaart opslaan" op een
  # verse robot mislukte (2026-10-10, turtlebot05)
  mkdir -p "$SETUP_DIR/state/maps"
  local prev_end prev_clean
  if journalctl -b -1 -n 0 >/dev/null 2>&1; then
    prev_end=$(journalctl -b -1 -n 1 -o short-iso --no-pager 2>/dev/null | awk '{print $1}')
    # Een nette afsluiting eindigt met systemd-shutdown + "Journal stopped";
    # stroom weg / batterij uitgetrokken laat de journal halverwege stoppen.
    if journalctl -b -1 -n 30 -o cat --no-pager 2>/dev/null | grep -q "Journal stopped"; then
      prev_clean=true
    else
      prev_clean=false
    fi
  else
    prev_end=""; prev_clean=""
  fi
  local git_as="runuser -u $SETUP_USER -- git -C $SETUP_DIR"
  # Image uit de compose-file + de digest van de lokale image (voor de
  # "update beschikbaar"-check tegen Docker Hub in system_info_node)
  local image_ref image_digest
  image_ref=$(docker compose --project-directory "$SETUP_DIR" config --images 2>/dev/null | head -1)
  image_digest=$(docker image inspect "$image_ref" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
                 | head -1 | sed 's/.*@//')
  SETUP_FULL="$($git_as rev-parse HEAD 2>/dev/null)" \
  SETUP_BRANCH="$($git_as rev-parse --abbrev-ref HEAD 2>/dev/null)" \
  SETUP_REPO="$($git_as remote get-url origin 2>/dev/null)" \
  SETUP_LOG="$($git_as log -5 --format='%H%x09%cs%x09%s' 2>/dev/null)" \
  # :vorige = image van voor de laatste update (rollback_turtlebot.sh)
  local image_prev
  image_prev=$(docker image inspect "${image_ref%:*}:vorige" \
               --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
               | sed -n 's/^TURTLEBOT_IMAGE_VERSION=//p')
  # oudere builds zonder versie-env: dan de bouwdatum
  [ -z "$image_prev" ] && image_prev=$(docker image inspect "${image_ref%:*}:vorige" \
               --format 'gebouwd {{.Created}}' 2>/dev/null | cut -c1-24)
  IMAGE_REF="$image_ref" IMAGE_DIGEST="$image_digest" IMAGE_PREVIOUS="$image_prev" \
  GOLDEN="$(cat /etc/turtlebot-golden 2>/dev/null)" \
  SETUP_COMMIT="$(runuser -u "$SETUP_USER" -- git -C "$SETUP_DIR" log -1 --format='%h %cs' 2>/dev/null)" \
  OS_NAME="$(. /etc/os-release; echo "$PRETTY_NAME")" \
  RPI_ISSUE="$(head -1 /etc/rpi-issue 2>/dev/null)" \
  KERNEL="$(uname -r)" \
  DOCKER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null)" \
  BOOTLOADER="$(vcgencmd bootloader_version 2>/dev/null | head -1)" \
  PREV_END="$prev_end" PREV_CLEAN="$prev_clean" \
  python3 - "$SETUP_DIR/state/host_info.json" <<'PY'
import json, os, sys, time
e = os.environ
clean = {"true": True, "false": False}.get(e.get("PREV_CLEAN", ""))
repo = (e.get("SETUP_REPO") or "").strip()
if repo.endswith(".git"):
    repo = repo[:-4]
log = []
for line in (e.get("SETUP_LOG") or "").splitlines():
    parts = line.split("\t", 2)
    if len(parts) == 3:
        log.append({"hash": parts[0], "date": parts[1], "subject": parts[2]})
info = {
    "golden": e.get("GOLDEN") or None,
    "setup_commit_full": e.get("SETUP_FULL") or None,
    "setup_branch": e.get("SETUP_BRANCH") or None,
    "setup_repo_url": repo or None,
    "setup_log": log,
    "image_ref": e.get("IMAGE_REF") or None,
    "image_digest": e.get("IMAGE_DIGEST") or None,
    "image_previous": e.get("IMAGE_PREVIOUS") or None,
    "setup_commit": e.get("SETUP_COMMIT") or None,
    "os": e.get("OS_NAME") or None,
    "rpi_issue": e.get("RPI_ISSUE") or None,
    "kernel": e.get("KERNEL") or None,
    "docker": e.get("DOCKER_VERSION") or None,
    "bootloader": e.get("BOOTLOADER") or None,
    "prev_boot_end": e.get("PREV_END") or None,
    "prev_shutdown_clean": clean,
    "written": int(time.time()),
}
with open(sys.argv[1], "w") as f:
    json.dump(info, f, indent=1)
PY
}
write_host_info

# --- Omgevingsvariabelen -----------------------------------------------------
# .env naast docker-compose.yaml: die leest Docker Compose zelf, ook bij een
# automatische herstart (profile.d enkel bij een interactieve login).
# Fleet monitor op de laptop van de docent (monitor/monitor.py): adres voor
# alle robots samen in monitor.conf (MONITOR_URL=...), leeg = uit.
MONITOR_URL=$(sed -n 's/^MONITOR_URL=//p' "$SETUP_DIR/monitor.conf" 2>/dev/null | tr -d '[:space:]' | tail -1)
ENV_CONTENT="TURTLEBOT_NR=$NR
ROS_DOMAIN_ID=$ROS_DOMAIN_ID
LDS_MODEL=$LIDAR
ENABLE_CAMERA=$CAMERA
MONITOR_URL=$MONITOR_URL
TERMINAL_PASSWORD=$AP_PSK"

cat > /etc/profile.d/turtlebot_config.sh <<EOF
export TURTLEBOT_NR=$NR
export ROS_DOMAIN_ID=$ROS_DOMAIN_ID
export LDS_MODEL=$LIDAR
export ENABLE_CAMERA=$CAMERA
EOF

ENV_FILE="$SETUP_DIR/.env"
if [ -d "$SETUP_DIR" ]; then
  if [ ! -f "$ENV_FILE" ] || [ "$(cat "$ENV_FILE")" != "$ENV_CONTENT" ]; then
    echo "$ENV_CONTENT" > "$ENV_FILE"
    chown "$SETUP_USER:$SETUP_USER" "$ENV_FILE"
    # Vlag i.p.v. variabele: overleeft de identiteits-reboot hieronder
    touch "$STATE_DIR/compose-pending"
    echo "✅ $ENV_FILE bijgewerkt (nr $NR, lidar $LIDAR, camera $CAMERA)"
  fi
else
  echo "⚠️ $SETUP_DIR bestaat niet — geen .env geschreven"
fi

if [ "$REBOOT_NEEDED" = true ]; then
  echo "🔄 Herstarten om de nieuwe identiteit te activeren..."
  systemctl --no-block reboot
  exit 0
fi

# --- Buildkit enkel op de bouwrobot ------------------------------------------
# Een kloon van de bouwrobot erft de buildx-builder (container + cache van
# enkele GB) - op de andere robots niet nodig.
if [ "$NR" != "$BUILD_ROBOT_NR" ]; then
  for c in $(docker ps -a --format '{{.Names}}' | grep '^buildx_buildkit_'); do
    docker rm -f "$c" && docker volume rm -f "${c}_state" >/dev/null \
      && echo "🗑️ Buildkit-builder $c + cache verwijderd"
  done
  docker image rm moby/buildkit:buildx-stable-1 >/dev/null 2>&1 \
    && echo "🗑️ Image moby/buildkit verwijderd"
fi

# --- Studentenwerkmap ros2_ws -------------------------------------------------
# Bind mount ./ros2_ws -> /root/ros2_ws (docker-compose.yaml). Zelf
# aanmaken als turtlebot-user; anders maakt Docker ze aan als root.
if [ -d "$SETUP_DIR" ] && [ ! -d "$SETUP_DIR/ros2_ws/src" ]; then
  runuser -u "$SETUP_USER" -- mkdir -p "$SETUP_DIR/ros2_ws/src" \
    && echo "📁 $SETUP_DIR/ros2_ws aangemaakt"
fi

# --- Container ---------------------------------------------------------------
# Enkel na een gewijzigde .env (bv. eerste boot van een kloon, die nog de
# container van de originele robot heeft). Anders zorgt
# restart: unless-stopped er zelf voor.
if [ -f "$STATE_DIR/compose-pending" ] && [ -f "$SETUP_DIR/docker-compose.yaml" ]; then
  # Container(s) met een ander nummer (kloon van een andere robot) of uit een
  # andere compose-map (bv. het oude ~/turtlebot_setup_test) opruimen
  for c in $(docker ps -a --format '{{.Names}}' | grep '^turtlebot_[0-9]*$'); do
    dir=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')
    if [ "$c" != "turtlebot_$NR" ] || [ "$dir" != "$SETUP_DIR" ]; then
      docker rm -f "$c" && echo "🗑️ Container $c verwijderd"
    fi
  done
  docker compose --project-directory "$SETUP_DIR" up -d \
    && rm -f "$STATE_DIR/compose-pending" \
    && echo "✅ Container turtlebot_$NR gestart"
fi

echo "🎉 TurtleBot setup voltooid!"
