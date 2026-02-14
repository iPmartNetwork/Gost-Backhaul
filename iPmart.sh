#!/bin/bash

### ================= BASIC =================
BACKHAUL_LOCAL_PORT=4000
BACKHAUL_REMOTE_PORT=9000
CONF_DIR="/etc/gost"
SERVICE_DIR="/usr/lib/systemd/system"

PROFILES=(basic ws wss cdn reality ultimate)

require_root() {
  [[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }
}

install_deps() {
  apt update -y >/dev/null 2>&1 || yum update -y
  apt install -y curl wget tar jq socat ca-certificates >/dev/null 2>&1 \
  || yum install -y curl wget tar jq socat ca-certificates
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="armv7" ;;
    *) echo "Unsupported architecture"; exit 1 ;;
  esac
}

is_port_free() {
  ! ss -lnt | awk '{print $4}' | grep -q ":$1$"
}

### ================= INSTALL BINARIES =================
install_gost() {
  detect_arch
  VER=$(curl -s https://api.github.com/repos/go-gost/gost/releases/latest | jq -r .tag_name | sed 's/v//')
  curl -L -o /tmp/gost.tar.gz \
    https://github.com/go-gost/gost/releases/download/v$VER/gost_${VER}_linux_${ARCH}.tar.gz
  tar -xzf /tmp/gost.tar.gz -C /tmp
  install -m 755 /tmp/gost /usr/bin/gost
}

install_backhaul() {
  detect_arch
  curl -L --fail \
    https://github.com/Musixal/Backhaul/releases/latest/download/backhaul-linux-${ARCH} \
    -o /usr/bin/backhaul
  chmod +x /usr/bin/backhaul
}

### ================= BACKHAUL SERVICE =================
setup_backhaul() {
cat >$SERVICE_DIR/backhaul.service <<EOF
[Unit]
After=network.target

[Service]
ExecStart=/usr/bin/backhaul client \
  --remote FOREIGN_IP:$BACKHAUL_REMOTE_PORT \
  --local 127.0.0.1:$BACKHAUL_LOCAL_PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

### ================= CREATE INSTANCE =================
create_instance() {
  local PORT=$1
  local PROFILE=$2
  local CONF="$CONF_DIR/$PORT.json"

  case "$PROFILE" in
    basic) LISTENER="tcp" ;;
    ws) LISTENER="ws" ;;
    wss) LISTENER="wss" ;;
    cdn) LISTENER="tcp" ;;
    reality|ultimate) LISTENER="reality" ;;
  esac

cat >"$CONF" <<EOF
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
        "Nodes": [{ "Addr": "127.0.0.1:$BACKHAUL_LOCAL_PORT" }]
      }
    }
  ]
}
EOF

cat >$SERVICE_DIR/gost@$PORT.service <<EOF
[Unit]
After=network.target backhaul.service
Requires=backhaul.service

[Service]
ExecStart=/usr/bin/gost -C $CONF
Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

### ================= MAIN =================
require_root
install_deps
install_gost
install_backhaul

mkdir -p "$CONF_DIR"
setup_backhaul

read -p "How many gost instances do you want? " COUNT

for ((i=1;i<=COUNT;i++)); do
  echo "---- Instance $i ----"
  while true; do
    read -p "Listen port: " PORT
    if is_port_free "$PORT"; then
      break
    else
      echo "Port $PORT is busy. Choose another."
    fi
  done

  echo "Profiles: ${PROFILES[*]}"
  read -p "Select profile: " PROFILE

  create_instance "$PORT" "$PROFILE"
  systemctl enable gost@$PORT
done

systemctl daemon-reload
systemctl enable backhaul
systemctl restart backhaul

for ((i=1;i<=COUNT;i++)); do
  systemctl restart gost@$(ls $CONF_DIR | sed 's/.json//' | sed -n "${i}p")
done

echo "✅ Multi-instance gost installed successfully"
