#!/bin/bash
# USB-stroom van de Pi 5 aan/uit - draait op de HOST (turtlebot-usb-power@on
# / @off.service), gestart door usb_power in de container via D-Bus.
#
# De Pi 5 schakelt de 5V van zijn 4 USB-poorten enkel samen, en pas als alle
# poorten van alle 4 root hubs uit staan (uhubctl-README). Getest 2026-10-09
# op turtlebot09: lidar stopt, OpenCR (op batterij) en F710 komen na "aan"
# terug. Op de host i.p.v. in de container: daar bleven de toestellen na
# "uit" als spook staan (/dev/bus/usb in de container is een vaste kopie).
set -u
STATE_FILE=/home/turtlebot/turtlebot_setup/state/usb_power   # in de container: /root/turtlebot_state/usb_power

# root hubs, USB3 (5000 Mb/s) eerst - zelfde volgorde als de geteste
hubs() {
  for d in /sys/bus/usb/devices/usb*; do
    echo "$(cat "$d/speed") ${d##*/usb}"
  done | sort -rn | awk '{print $2}'
}

case "${1:-}" in
  on|off)
    for h in $(hubs); do uhubctl -l "$h" -a "$1" >/dev/null; done
    echo "$1" > "$STATE_FILE"
    ;;
  *)
    echo "gebruik: $0 on|off" >&2
    exit 1
    ;;
esac
