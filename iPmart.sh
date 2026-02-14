#!/usr/bin/env bash

echo "=============================================="
echo " Gost + Backhaul Ultimate Installer"
echo "=============================================="

################ BASIC SANITY ################
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Run as root"
  exit 1
fi

set -e

CONF_DIR="/etc/gost"
SERVICE_DIR="/lib/systemd/system"
AUTOSWITCH_BIN="/usr/local/bin/gost-autoswitch.sh"

PROFILES=(basic ws wss cdn reality ultimate)

################ ARCH ################
detect_arch() {
  case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="armv7" ;;
    *)
      echo "[ERROR] Unsupported architecture"
      exit 1
      ;;
  esac
}

################ PORT CHECK ################
is_port_free() {
  ! ss -lnt | awk '{print $4}' | grep -q ":$1$"
}

################ DEPS ################
install_deps() {
  echo "[INFO] Installing dependencies..."
  if command -v apt >/dev/null; then
    apt update -y
    apt install -y curl jq tar ca-certificates iproute2
  elif command -v yum >/dev/null; then
    yum install -y curl jq tar ca-certificates iproute
  else
    echo "[ERROR] Unsupported OS"
    exit 1
  fi
}

################ GOST ################
install_gost() {
  echo "[INFO] Installing gost..."
  detect_arch

  API="https://api.github.com/repos/go-gost/gost/releases/latest"
  URL=$(curl -fsSL "$API" | jq -r ".assets[] | select(.name | test(\"linux.*${ARCH}\")) | .browser_download_url" | head -n1)

  [[ -z "$URL" ]] && { echo "[ERROR] gost asset not found"; exit 1; }

  curl -fL "$URL" -o /tmp/gost.tar.gz
  tar -xzf /tmp/gost.tar.gz -C /tmp
  install -m 755 /tmp/gost /usr/bin/gost

  gost -V
}

################ BACKHAUL ################
install_backhaul() {
  echo "[INFO] Installing Backhaul..."
  detect_arch

  API="https://api.github.com/repos/Musixal/Backhaul/releases/latest"
  URL=$(curl -fsSL "$API" | jq -r ".assets[] | select(.name | test(\"linux.*${ARCH}\")) | .browser_download_url" | head -n1)

  [[ -z "$URL" ]] && { echo "[ERROR] Backhaul asset not found"; exit 1; }

  curl -fL "$URL" -o /usr/bin/backhaul
  chmod +x /usr/bin/backhaul
}

################ BACKHAUL SERVICE ################
setup_backhaul() {
  read -p "Foreign server IP/domain: " FOREIGN_IP
  read -p "Backhaul remote port [9000]: " BACKHAUL_REMOTE_PORT
  read -p "Backhaul local port [4000]: " BACKHAUL_LOCAL_PORT

  BACKHAUL_REMOTE_PORT=${BACKHAUL_REMOTE_PORT:-9000}
  BACKHAUL_LOCAL_PORT=${BACKHAUL_LOCAL_PORT:-4000}

cat >"$SERVICE_DIR/backhaul.service" <<EOF
[Unit]
After=network.target

[Service]
ExecStart=/usr/bin/backhaul client \
  --remote ${FOREIGN_IP}:${BACKHAUL_REMOTE_PORT} \
  --local 127.0.0.1:${BACKHAUL_LOCAL_PORT}
Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

################ GOST INSTANCE ################
create_instance() {
  PORT="$1"
  PROFILE="$2"

  case "$PROFILE" in
    basic) LISTENER="tcp" ;;
    ws) LISTENER="ws" ;;
    wss) LISTENER="wss" ;;
    cdn) LISTENER="tcp" ;;
    reality|ultimate) LISTENER="reality" ;;
    *) echo "[ERROR] Invalid profile"; exit 1 ;;
  esac

cat >"$CONF_DIR/$PORT.json" <<EOF
{
  "Services": [
    {
      "Name": "$PROFILE-$PORT",
      "Addr": ":$PORT",
      "Listener": {
        "Type": "$LISTENER",
        "TLS": { "ServerName": "www.cloudflare.com" }
      },
      "Handler": { "Type": "tcp" },
      "Forwarder": {
        "Nodes": [{ "Addr": "127.0.0.1:${BACKHAUL_LOCAL_PORT}" }]
      }
    }
  ]
}
EOF

cat >"$SERVICE_DIR/gost@$PORT.service" <<EOF
[Unit]
After=network.target backhaul.service
Requires=backhaul.service

[Service]
ExecStart=/usr/bin/gost -C $CONF_DIR/$PORT.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

################ AUTOSWITCH (STABLE) ################
setup_autoswitch() {
cat >"$AUTOSWITCH_BIN" <<'EOF'
#!/usr/bin/env bash
CONF_DIR="/etc/gost"
PROFILES=(basic ws wss cdn reality ultimate)
INTERVAL=30

while true; do
  for f in "$CONF_DIR"/*.json; do
    PORT=$(basename "$f" .json)
    LOSS=$(ping -c 3 -W 2 8.8.8.8 | grep -oP '\d+(?=% packet loss)' || echo 100)
    if [ "$LOSS" -gt 20 ]; then
      systemctl restart gost@"$PORT"
    fi
  done
  sleep "$INTERVAL"
done
EOF

chmod +x "$AUTOSWITCH_BIN"

cat >"$SERVICE_DIR/gost-autoswitch.service" <<EOF
[Unit]
After=network.target

[Service]
ExecStart=$AUTOSWITCH_BIN
Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

################ MAIN ################
install_deps
install_gost
install_backhaul

mkdir -p "$CONF_DIR"
setup_backhaul

read -p "How many gost instances? " COUNT

for ((i=1;i<=COUNT;i++)); do
  echo "---- Instance $i ----"
  while true; do
    read -p "Listen port: " PORT
    is_port_free "$PORT" && break
    echo "Port busy"
  done
  echo "Profiles: ${PROFILES[*]}"
  read -p "Profile: " PROFILE
  create_instance "$PORT" "$PROFILE"
  systemctl enable gost@"$PORT"
done

setup_autoswitch

systemctl daemon-reload
systemctl enable backhaul gost-autoswitch
systemctl restart backhaul gost-autoswitch

for f in "$CONF_DIR"/*.json; do
  systemctl restart gost@"$(basename "$f" .json)"
done

echo "=============================================="
echo " Installation completed successfully"
echo "=============================================="
