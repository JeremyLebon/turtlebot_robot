#!/bin/bash
# Statuspagina van deze robot ook van thuis/elders bereiken via Tailscale
# (privé-VPN, t27). Enkel uitgaande verbindingen: niets openzetten op de AP
# of de campusfirewall; enkel toestellen in je eigen Tailscale-account
# kunnen erbij. Daarna: http://<hostname>:8080 (bv. http://turtlebot09:8080)
# vanaf je laptop/smartphone met Tailscale aan. De pagina en rosbridge
# gebruiken de hostnaam uit de URL, dus alles werkt ook via de VPN.
#
# Bewust NIET in setup_turtlebot.sh (niet automatisch op elke robot): eerst
# afstemmen met ICT van VIVES. Per robot met de hand:
#
#   sudo ~/turtlebot_setup/tools/tailscale_setup.sh [auth-key]
#
# auth-key: Tailscale admin console > Settings > Keys > Generate auth key
# (reusable, pre-approved, eventueel tag:turtlebot). Nooit in git. Zonder
# key toont tailscale een login-URL om deze robot aan je account te koppelen.
#
# Uitzetten: sudo tailscale down (blijft geïnstalleerd, `up` = terug aan).
# Verwijderen: sudo tailscale logout && sudo apt purge tailscale
# Golden image: golden_prepare.sh meldt Tailscale af (anders delen alle
# klonen dezelfde identiteit).
set -eu

[ "$(id -u)" = 0 ] || { echo "Start met sudo."; exit 1; }

if ! command -v tailscale >/dev/null; then
  echo "⬇️ Tailscale installeren (officieel script, apt-repository)..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled

HOST=$(hostname)
# Geen DNS/routes van het tailnet overnemen: de robot blijft zijn eigen
# netwerk (AP) gebruiken zoals voordien, Zenoh/ROS verandert niet.
ARGS=(up --hostname="$HOST" --accept-dns=false --accept-routes=false)
[ -n "${1:-}" ] && ARGS+=(--auth-key="$1")
tailscale "${ARGS[@]}"

IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
echo "✅ $HOST in Tailscale: http://$HOST:8080  (of http://${IP:-<100.x.y.z>}:8080)"
echo "   Uitzetten: sudo tailscale down"
