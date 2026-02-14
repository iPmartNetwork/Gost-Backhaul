#!/usr/bin/env bash

echo "=================================================="
echo " Gost + Backhaul Ultimate Installer "
echo "=================================================="

############################
# SANITY
############################
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Please run as root"
  exit 1
fi
set -e

############################
# PATHS
############################
BIN_DIR="/usr/bin"
CONF_DIR="/etc/gost"
SWITCHD_DIR="/opt/gost-switchd"
STATE_DIR="/var/lib/gost-switchd"
SYSTEMD_DIR="/lib/systemd/system"

############################
# ARCH
############################
detect_arch() {
  case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="armv7" ;;
    *) echo "[ERROR] Unsupported architecture"; exit 1 ;;
  esac
}

############################
# PORT CHECK
############################
is_port_free() {
  ! ss -lnt | awk '{print $4}' | grep -q ":$1$"
}

############################
# DEPENDENCIES
############################
install_deps() {
  echo "[INFO] Installing dependencies..."
  if command -v apt >/dev/null; then
    apt update -y
    apt install -y curl jq tar ca-certificates iproute2 \
                   python3 python3-pip openssl netcat-openbsd
  elif command -v yum >/dev/null; then
    yum install -y curl jq tar ca-certificates iproute \
                   python3 python3-pip openssl nc
  else
    echo "[ERROR] Unsupported OS"
    exit 1
  fi
  pip3 install --no-cache-dir requests
}

############################
# INSTALL GOST
############################
install_gost() {
  echo "[INFO] Installing gost..."
  detect_arch

  API="https://api.github.com/repos/go-gost/gost/releases/latest"
  URL=$(curl -fsSL "$API" \
    | jq -r ".assets[] | select(.name | contains(\"linux\") and contains(\"$ARCH\")) | .browser_download_url" \
    | head -n1)

  [[ -z "$URL" ]] && { echo "[ERROR] gost binary not found"; exit 1; }

  curl -fL "$URL" -o /tmp/gost.tar.gz
  tar -xzf /tmp/gost.tar.gz -C /tmp
  install -m 755 /tmp/gost "$BIN_DIR/gost"

  echo "[OK] gost installed:"
  gost -V
}

############################
# INSTALL BACKHAUL (FIXED)
############################
install_backhaul() {
  echo "[INFO] Installing Backhaul..."
  detect_arch

  API="https://api.github.com/repos/Musixal/Backhaul/releases/latest"
  URL=$(curl -fsSL "$API" | jq -r \
    --arg arch "linux_${ARCH}.tar.gz" \
    '.assets[] | select(.name | endswith($arch)) | .browser_download_url' \
    | head -n1)

  if [[ -z "$URL" ]]; then
    echo "[ERROR] Backhaul archive not found for architecture: $ARCH"
    exit 1
  fi

  TMP="/tmp/backhaul"
  rm -rf "$TMP"
  mkdir -p "$TMP"

  curl -fL "$URL" -o "$TMP/backhaul.tar.gz"
  tar -xzf "$TMP/backhaul.tar.gz" -C "$TMP"

  BIN=$(find "$TMP" -type f -name backhaul | head -n1)
  [[ -z "$BIN" ]] && { echo "[ERROR] Backhaul binary not found in archive"; exit 1; }

  install -m 755 "$BIN" "$BIN_DIR/backhaul"

  echo "[OK] Backhaul installed:"
  backhaul version || true
}

############################
# BACKHAUL SERVICE
############################
setup_backhaul_service() {
  read -p "Foreign server IP/domain: " FOREIGN_IP
  read -p "Backhaul remote port [9000]: " BACKHAUL_REMOTE_PORT
  read -p "Backhaul local port [4000]: " BACKHAUL_LOCAL_PORT

  BACKHAUL_REMOTE_PORT=${BACKHAUL_REMOTE_PORT:-9000}
  BACKHAUL_LOCAL_PORT=${BACKHAUL_LOCAL_PORT:-4000}

cat >"$SYSTEMD_DIR/backhaul.service" <<EOF
[Unit]
Description=Backhaul Client
After=network.target

[Service]
ExecStart=$BIN_DIR/backhaul client \
  --remote ${FOREIGN_IP}:${BACKHAUL_REMOTE_PORT} \
  --local 127.0.0.1:${BACKHAUL_LOCAL_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

############################
# GOST INSTANCE
############################
create_gost_instance() {
  PORT="$1"
  PROFILE="$2"

  case "$PROFILE" in
    basic) LISTENER="tcp" ;;
    ws) LISTENER="ws" ;;
    wss) LISTENER="wss" ;;
    cdn) LISTENER="tcp" ;;
    reality|ultimate) LISTENER="reality" ;;
    h3) LISTENER="quic" ;;
    *) echo "[ERROR] Invalid profile"; exit 1 ;;
  esac

cat >"$CONF_DIR/$PORT.json" <<EOF
{
  "profile": "$PROFILE",
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

cat >"$SYSTEMD_DIR/gost@$PORT.service" <<EOF
[Unit]
Description=Gost Instance on port $PORT
After=network.target backhaul.service
Requires=backhaul.service

[Service]
ExecStart=$BIN_DIR/gost -C $CONF_DIR/$PORT.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

############################
# INSTALL SWITCH DAEMON FILES
############################
install_switchd_files() {
  echo "[INFO] Installing DPI / QUIC switch daemon..."
  mkdir -p "$SWITCHD_DIR" "$STATE_DIR" "$CONF_DIR"

  cp switchd/gost-switchd.py "$SWITCHD_DIR/gost-switchd.py"
  cp profiles/profiles.json "$CONF_DIR/profiles.json"
  cp systemd/gost-switchd.service "$SYSTEMD_DIR/gost-switchd.service"

  chmod +x "$SWITCHD_DIR/gost-switchd.py"
}

############################
# MAIN
############################
install_deps
install_gost
install_backhaul

mkdir -p "$CONF_DIR"
setup_backhaul_service

read -p "How many gost instances do you want? " COUNT

for ((i=1;i<=COUNT;i++)); do
  echo "---- Instance $i ----"
  while true; do
    read -p "Listen port: " PORT
    is_port_free "$PORT" && break
    echo "Port is busy, choose another."
  done
  read -p "Profile (basic/ws/wss/cdn/reality/ultimate/h3): " PROFILE
  create_gost_instance "$PORT" "$PROFILE"
  systemctl enable gost@"$PORT"
done

install_switchd_files

systemctl daemon-reload
systemctl enable backhaul gost-switchd
systemctl restart backhaul gost-switchd

for f in "$CONF_DIR"/*.json; do
  systemctl restart gost@"$(basename "$f" .json)"
done

echo "=================================================="
echo " Installation completed successfully"
echo " DPI / QUIC / Rollback daemon is ACTIVE"
echo "=================================================="
