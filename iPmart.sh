#!/usr/bin/env bash

echo "=============================================="
echo " Gost + Backhaul Ultimate Installer (FINAL)"
echo "=============================================="

################ SANITY ################
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Run as root"
  exit 1
fi

set -e

################ PATHS ################
CONF_DIR="/etc/gost"
BIN_DIR="/usr/bin"
SERVICE_DIR="/lib/systemd/system"
SWITCHD_DIR="/opt/gost-switchd"

################ UTILS ################
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

################ DEPENDENCIES ################
install_deps() {
  echo "[INFO] Installing dependencies..."
  if command -v apt >/dev/null; then
    apt update -y
    apt install -y curl jq tar ca-certificates iproute2 python3 python3-pip
  elif command -v yum >/dev/null; then
    yum install -y curl jq tar ca-certificates iproute python3 python3-pip
  else
    echo "[ERROR] Unsupported OSOS"
    exit 1
  fi

  pip3 install --no-cache-dir requests
}

################ GOST ################
install_gost() {
  echo "[INFO] Installing gost..."
  detect_arch

  API="https://api.github.com/repos/go-gost/gost/releases/latest"
  URL=$(curl -fsSL "$API" | jq -r ".assets[] | select(.name | test(\"linux.*${ARCH}\")) | .browser_download_url" | head -n1)

  [[ -z "$URL" ]] && { echo "[ERROR] gost binary not found"; exit 1; }

  curl -fL "$URL" -o /tmp/gost.tar.gz
  tar -xzf /tmp/gost.tar.gz -C /tmp
  install -m 755 /tmp/gost $BIN_DIR/gost

  gost -V
}

################ BACKHAUL ################
install_backhaul() {
  echo "[INFO] Installing Backhaul..."
  detect_arch

  API="https://api.github.com/repos/Musixal/Backhaul/releases/latest"
  URL=$(curl -fsSL "$API" | jq -r ".assets[] | select(.name | test(\"linux.*${ARCH}\")) | .browser_download_url" | head -n1)

  [[ -z "$URL" ]] && { echo "[ERROR] Backhaul binary not found"; exit 1; }

  curl -fL "$URL" -o $BIN_DIR/backhaul
  chmod +x $BIN_DIR/backhaul

  backhaul version || true
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
ExecStart=$BIN_DIR/backhaul client \
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

cat >"$SERVICE_DIR/gost@$PORT.service" <<EOF
[Unit]
After=network.target backhaul.service
Requires=backhaul.service

[Service]
ExecStart=$BIN_DIR/gost -C $CONF_DIR/$PORT.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

################ SWITCH DAEMON ################
install_switchd() {
  echo "[INFO] Installing gost-switchd..."
  mkdir -p "$SWITCHD_DIR"

cat >"$SWITCHD_DIR/gost-switchd.py" <<'EOF'
#!/usr/bin/env python3
import os, time, json, subprocess, socket, requests

CONF_DIR = "/etc/gost"
STATE_DIR = "/var/lib/gost-switchd"
INTERVAL = 30
COOLDOWN = 60
PROFILES = ["basic","ws","wss","cdn","reality","ultimate"]

os.makedirs(STATE_DIR, exist_ok=True)

def geo():
    try:
        return requests.get("https://ipinfo.io/country", timeout=3).text.strip()
    except:
        return "IR"

GEO = geo()
START = "reality" if GEO == "IR" else "ws"
MAX = "ultimate" if GEO == "IR" else "wss"

def loss():
    out = subprocess.getoutput("ping -c 5 -W 2 8.8.8.8")
    for l in out.splitlines():
        if "packet loss" in l:
            return int(l.split("%")[0].split()[-1])
    return 100

def tcp(port):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=3)
        s.close()
        return True
    except:
        return False

while True:
    l = loss()
    for f in os.listdir(CONF_DIR):
        if not f.endswith(".json"): continue
        port = f.replace(".json","")
        sp = f"{STATE_DIR}/{port}.json"
        now = time.time()

        if os.path.exists(sp):
            st = json.load(open(sp))
        else:
            st = {"profile":START,"last":0}

        if now - st["last"] < COOLDOWN:
            continue

        if l > 20 or not tcp(int(port)):
            cur = st["profile"]
            idx = PROFILES.index(cur)
            if PROFILES[idx] == MAX: continue
            st["profile"] = PROFILES[idx+1]
            st["last"] = now
            json.dump(st, open(sp,"w"))
            subprocess.call(["systemctl","restart",f"gost@{port}"])
    time.sleep(INTERVAL)
EOF

chmod +x "$SWITCHD_DIR/gost-switchd.py"

cat >"$SERVICE_DIR/gost-switchd.service" <<EOF
[Unit]
After=network.target

[Service]
ExecStart=/usr/bin/python3 $SWITCHD_DIR/gost-switchd.py
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
  read -p "Profile (basic/ws/wss/cdn/reality/ultimate): " PROFILE
  create_instance "$PORT" "$PROFILE"
  systemctl enable gost@"$PORT"
done

install_switchd

systemctl daemon-reload
systemctl enable backhaul gost-switchd
systemctl restart backhaul gost-switchd

for f in "$CONF_DIR"/*.json; do
  systemctl restart gost@"$(basename "$f" .json)"
done

echo "=============================================="
echo " Installation completed successfully"
echo " Auto-Switch + Geo-Preset ACTIVE"
echo "=============================================="
