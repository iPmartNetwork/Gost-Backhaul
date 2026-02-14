#!/usr/bin/env bash
set -euo pipefail

############################################
# Gost + Backhaul Ultimate Installer
# iPmart Network tunnel script
############################################

CONF_DIR="/etc/gost"
SERVICE_DIR="/lib/systemd/system"
AUTOSWITCH_BIN="/usr/local/bin/gost-autoswitch.sh"

BACKHAUL_LOCAL_PORT_DEFAULT=4000
BACKHAUL_REMOTE_PORT_DEFAULT=9000
CHECK_INTERVAL_DEFAULT=30

PROFILES=(basic ws wss cdn reality ultimate)

############################################
# Utils
############################################
require_root() {
  [[ $EUID -ne 0 ]] && { echo "[ERROR] Run as root"; exit 1; }
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="armv7" ;;
    *) echo "[ERROR] Unsupported architecture"; exit 1 ;;
  esac
}

is_port_free() {
  ! ss -lnt | awk '{print $4}' | grep -q ":$1$"
}

install_deps() {
  echo "[INFO] Installing dependencies..."
  if command -v apt >/dev/null; then
    apt update -y
    apt install -y curl wget jq tar ca-certificates iproute2
  elif command -v yum >/dev/null; then
    yum install -y curl wget jq tar ca-certificates iproute
  else
    echo "[ERROR] Unsupported package manager"
    exit 1
  fi
}

############################################
# Install gost
############################################
install_gost() {
  echo "[INFO] Installing gost..."
  detect_arch
  API="https://api.github.com/repos/go-gost/gost/releases/latest"
  ASSET=$(curl -fsSL "$API" | jq -r ".assets[] | select(.name | test(\"linux.*${ARCH}\")) | .browser_download_url" | head -n1)
  [[ -z "$ASSET" ]] && { echo "[ERROR] gost asset not found"; exit 1; }

  curl -fL "$ASSET" -o /tmp/gost.tar.gz
  tar -xzf /tmp/gost.tar.gz -C /tmp
  install -m 755 /tmp/gost /usr/bin/gost
  /usr/bin/gost -V >/dev/null
}

############################################
# Install Backhaul
############################################
install_backhaul() {
  echo "[INFO] Installing Backhaul..."
  detect_arch
  API="https://api.github.com/repos/Musixal/Backhaul/releases/latest"
  ASSET=$(curl -fsSL "$API" | jq -r ".assets[] | select(.name | test(\"linux.*${ARCH}\")) | .browser_download_url" | head -n1)
  [[ -z "$ASSET" ]] && { echo "[ERROR] Backhaul asset not found"; exit 1; }

  curl -fL "$ASSET" -o /usr/bin/backhaul
  chmod +x /usr/bin/backhaul
  /usr/bin/backhaul version >/dev/null 2>&1 || true
}

############################################
# Backhaul Service
############################################
setup_backhaul_service() {
  read -p "Backhaul local port [${BACKHAUL_LOCAL_PORT_DEFAULT}]: " BACKHAUL_LOCAL_PORT
  BACKHAUL_LOCAL_PORT=${BACKHAUL_LOCAL_PORT:-$BACKHAUL_LOCAL_PORT_DEFAULT}

  read -p "Backhaul remote port [${BACKHAUL_REMOTE_PORT_DEFAULT}]: " BACKHAUL_REMOTE_PORT
  BACKHAUL_REMOTE_PORT=${BACKHAUL_REMOTE_PORT:-$BACKHAUL_REMOTE_PORT_DEFAULT}

  read -p "Foreign server IP/domain: " FOREIGN_IP
  [[ -z "$FOREIGN_IP" ]] && { echo "[ERROR] Foreign IP required"; exit 1; }

cat >"$SERVICE_DIR/backhaul.service" <<EOF
[Unit]
Description=Backhaul Client
After=network.target

[Service]
ExecStart=/usr/bin/backhaul client \
  --remote ${FOREIGN_IP}:${BACKHAUL_REMOTE_PORT} \
  --local 127.0.0.1:${BACKHAUL_LOCAL_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

############################################
# Gost Instance
############################################
create_gost_instance() {
  local PORT=$1
  local PROFILE=$2
  local CONF="$CONF_DIR/$PORT.json"

  case "$PROFILE" in
    basic) LISTENER="tcp" ;;
    ws) LISTENER="ws" ;;
    wss) LISTENER="wss" ;;
    cdn) LISTENER="tcp" ;;
    reality|ultimate) LISTENER="reality" ;;
    *) echo "[ERROR] Invalid profile"; exit 1 ;;
  esac

cat >"$CONF" <<EOF
{
  "profile": "${PROFILE}",
  "Services": [
    {
      "Name": "${PROFILE}-${PORT}",
      "Addr": ":${PORT}",
      "Listener": {
        "Type": "${LISTENER}",
        "TLS": { "ServerName": "www.cloudflare.com" }
      },
      "Handler": { "Type": "tcp" },
      "Forwarder": {
        "Nodes": [
          { "Addr": "127.0.0.1:${BACKHAUL_LOCAL_PORT}" }
        ]
      }
    }
  ]
}
EOF

cat >"$SERVICE_DIR/gost@${PORT}.service" <<EOF
[Unit]
Description=Gost Instance ${PORT}
After=network.target backhaul.service
Requires=backhaul.service

[Service]
ExecStart=/usr/bin/gost -C ${CONF}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

############################################
# Auto Switch Daemon
############################################
create_autoswitch() {
cat >"$AUTOSWITCH_BIN" <<'EOF'
#!/usr/bin/env bash

CONF_DIR="/etc/gost"
PROFILES=(basic ws wss cdn reality ultimate)
INTERVAL=30

while true; do
  for cfg in "$CONF_DIR"/*.json; do
    PORT=$(basename "$cfg" .json)
    CUR=$(jq -r '.profile' "$cfg")

    LOSS=$(ping -c 5 -W 2 8.8.8.8 | grep -oP '\d+(?=% packet loss)' || echo 100)
    timeout 3 bash -c ">/dev/tcp/127.0.0.1/$PORT" 2>/dev/null || TCP_FAIL=1

    if [[ ${LOSS:-0} -gt 20 || ${TCP_FAIL:-0} -eq 1 ]]; then
      IDX=$(printf "%s\n" "${PROFILES[@]}" | grep -n "^$CUR$" | cut -d: -f1)
      NEXT=${PROFILES[$IDX]}

      [[ -z "$NEXT" ]] && continue

      jq ".profile=\"$NEXT\"" "$cfg" >"$cfg.tmp" && mv "$cfg.tmp" "$cfg"
      systemctl restart gost@"$PORT"
    fi
    TCP_FAIL=0
  done
  sleep "$INTERVAL"
done
EOF

chmod +x "$AUTOSWITCH_BIN"

cat >"$SERVICE_DIR/gost-autoswitch.service" <<EOF
[Unit]
Description=Gost Auto Switch Daemon
After=network.target

[Service]
ExecStart=$AUTOSWITCH_BIN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

############################################
# MAIN
############################################
require_root
install_deps
install_gost
install_backhaul

mkdir -p "$CONF_DIR"

setup_backhaul_service

read -p "How many gost instances do you want? " COUNT
[[ "$COUNT" =~ ^[0-9]+$ ]] || exit 1

for ((i=1;i<=COUNT;i++)); do
  echo "---- Instance $i ----"
  while true; do
    read -p "Listen port: " PORT
    is_port_free "$PORT" && break
    echo "Port busy, choose another"
  done

  echo "Profiles: ${PROFILES[*]}"
  read -p "Select initial profile: " PROFILE
  create_gost_instance "$PORT" "$PROFILE"
  systemctl enable gost@"$PORT"
done

create_autoswitch

systemctl daemon-reload
systemctl enable backhaul gost-autoswitch
systemctl restart backhaul gost-autoswitch

for cfg in "$CONF_DIR"/*.json; do
  PORT=$(basename "$cfg" .json)
  systemctl restart gost@"$PORT"
done

echo
echo "✅ Installation completed with REAL Auto-Switch enabled"
