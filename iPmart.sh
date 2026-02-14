#!/usr/bin/env bash
set -e

### ================= PATHS =================
BIN="/usr/bin"
CONF="/etc/gost"
SYS="/lib/systemd/system"
BHCONF="/etc/backhaul/config.toml"
ROLE_FILE="/etc/gost/ROLE"
SWD="/opt/gost-switchd"
STATE="/var/lib/gost-switchd"

[[ $EUID -ne 0 ]] && echo "[ERROR] Run as root" && exit 1

### ================= DEPENDENCIES =================
install_deps() {
  if command -v jq >/dev/null 2>&1; then return; fi
  if command -v apt >/dev/null 2>&1; then
    apt update -y
    apt install -y curl jq tar python3 iproute2 netcat-openbsd openssl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl jq tar python3 iproute nc openssl
  else
    echo "[ERROR] Unsupported OS"
    exit 1
  fi
}
install_deps

### ================= ARCH =================
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l) ARCH=armv7 ;;
  *) echo "[ERROR] Unsupported arch"; exit 1 ;;
esac

### ================= INSTALL GOST =================
install_gost() {
  echo "[INFO] Installing gost..."
  URL=$(curl -fsSL https://api.github.com/repos/go-gost/gost/releases/latest \
    | jq -r ".assets[] | select(.name|contains(\"linux\") and contains(\"$ARCH\")) | .browser_download_url" | head -n1)
  [[ -z "$URL" ]] && { echo "[ERROR] gost binary not found"; return; }
  curl -fL "$URL" -o /tmp/gost.tgz
  tar -xzf /tmp/gost.tgz -C /tmp
  install -m755 /tmp/gost $BIN/gost
  gost -V
}

### ================= INSTALL BACKHAUL =================
install_backhaul() {
  echo "[INFO] Installing Backhaul..."
  URL=$(curl -fsSL https://api.github.com/repos/Musixal/Backhaul/releases/latest \
    | jq -r --arg a "linux_${ARCH}.tar.gz" '.assets[] | select(.name | endswith($a)) | .browser_download_url' | head -n1)
  [[ -z "$URL" ]] && { echo "[ERROR] Backhaul binary not found"; return; }
  curl -fL "$URL" -o /tmp/bh.tgz
  tar -xzf /tmp/bh.tgz -C /tmp
  install -m755 /tmp/backhaul $BIN/backhaul
}

### ================= CONFIGURE BACKHAUL (FIXED) =================
configure_backhaul() {
  mkdir -p /etc/backhaul /etc/gost

  echo "1) IRAN (client)"
  echo "2) FOREIGN (server)"
  read -p "Select role: " R

  if [[ "$R" == "1" ]]; then
    echo "IRAN" > "$ROLE_FILE"
    read -p "Foreign server IP/domain: " F
    read -p "Remote port [9000]: " RP
    read -p "Local port [4000]: " LP
    RP=${RP:-9000}
    LP=${LP:-4000}

cat >"$BHCONF" <<EOF
[client]
remote = "$F:$RP"
local  = "127.0.0.1:$LP"
EOF

  elif [[ "$R" == "2" ]]; then
    echo "FOREIGN" > "$ROLE_FILE"
    read -p "Listen port [9000]: " SP
    SP=${SP:-9000}

cat >"$BHCONF" <<EOF
[server]
listen = "0.0.0.0:$SP"
EOF

  else
    echo "[ERROR] Invalid role"
    return
  fi

cat >"$SYS/backhaul.service" <<EOF
[Unit]
After=network.target
[Service]
ExecStart=$BIN/backhaul -c $BHCONF
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable backhaul
  systemctl restart backhaul
}

### ================= ADD GOST TUNNEL =================
add_tunnel() {
  ROLE=$(cat "$ROLE_FILE" 2>/dev/null || echo "IRAN")
  mkdir -p "$CONF" "$STATE"

  read -p "Enter ports (comma separated): " PORTS
  IFS=',' read -ra LIST <<< "$PORTS"

  echo "Profile:"
  echo "1) IRAN"
  echo "2) FOREIGN"
  echo "3) Anti-DPI"
  read -p "Choice: " PF

  case "$PF" in
    1) ORDER='["reality","wss","ws","tcp"]' ;;
    2) ORDER='["tcp","ws"]' ;;
    3) ORDER='["reality","quic","wss"]' ;;
    *) echo "Invalid profile"; return ;;
  esac

  for P in "${LIST[@]}"; do
    P=$(echo "$P" | xargs)

    if [[ "$ROLE" == "IRAN" ]]; then
      ss -lnt | grep -q ":$P " && { echo "[ERROR] Port $P busy on IRAN"; continue; }
    fi

    read -p "Protocol for port $P (tcp/ws/wss/reality/quic): " PROTO

cat >"$CONF/$P.json" <<EOF
{
  "Services":[{
    "Name":"gost-$P",
    "Addr":":$P",
    "Listener":{"Type":"$PROTO"},
    "Handler":{"Type":"tcp"},
    "Forwarder":{"Nodes":[{"Addr":"127.0.0.1:4000"}]}
  }]
}
EOF

cat >"$STATE/$P.json" <<EOF
{
  "order":$ORDER,
  "current":"$PROTO"
}
EOF

cat >"$SYS/gost@$P.service" <<EOF
[Unit]
After=network.target backhaul.service
Requires=backhaul.service
[Service]
ExecStart=$BIN/gost -C $CONF/$P.json
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost@$P
    systemctl start gost@$P
    echo "[OK] gost@$P created ($PROTO)"
  done
}

### ================= DPI / AUTO-SWITCH DAEMON =================
install_daemon() {
  mkdir -p "$SWD" "$STATE"

cat >"$SWD/gost-switchd.py" <<'EOF'
#!/usr/bin/env python3
import os,json,time,subprocess

STATE="/var/lib/gost-switchd"
CONF="/etc/gost"

def bad(port):
    o=subprocess.getoutput(f"timeout 3 nc -vz 127.0.0.1 {port}")
    return ("reset" in o) or ("refused" in o)

while True:
    for f in os.listdir(STATE):
        if not f.endswith(".json"): continue
        p=f[:-5]
        s=json.load(open(f"{STATE}/{f}"))
        order=s["order"]; cur=s["current"]
        if bad(p):
            i=order.index(cur)
            if i+1 < len(order):
                nxt=order[i+1]
                s["current"]=nxt
                json.dump(s,open(f"{STATE}/{f}","w"))
                cfg=json.load(open(f"{CONF}/{p}.json"))
                cfg["Services"][0]["Listener"]["Type"]=nxt
                json.dump(cfg,open(f"{CONF}/{p}.json","w"),indent=2)
                subprocess.call(["systemctl","restart",f"gost@{p}"])
    time.sleep(15)
EOF

chmod +x "$SWD/gost-switchd.py"

cat >"$SYS/gost-switchd.service" <<EOF
[Unit]
After=network.target
[Service]
ExecStart=/usr/bin/python3 $SWD/gost-switchd.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gost-switchd
systemctl start gost-switchd
}

### ================= UTIL =================
list_tunnels() { ls $CONF/*.json 2>/dev/null | sed 's#.*/##;s#.json##'; }

remove_tunnel() {
  list_tunnels
  read -p "Port to remove: " P
  systemctl stop gost@$P 2>/dev/null || true
  systemctl disable gost@$P 2>/dev/null || true
  rm -f "$CONF/$P.json" "$SYS/gost@$P.service" "$STATE/$P.json"
  systemctl daemon-reload
}

remove_all() {
  for P in $(list_tunnels); do
    systemctl stop gost@$P 2>/dev/null || true
    systemctl disable gost@$P 2>/dev/null || true
    rm -f "$CONF/$P.json" "$SYS/gost@$P.service" "$STATE/$P.json"
  done
  systemctl daemon-reload
}

status_all() {
  systemctl status backhaul --no-pager
  for P in $(list_tunnels); do systemctl status gost@$P --no-pager; done
}

### ================= MENU =================
while true; do
  clear
  echo "========= Gost + Backhaul Manager ========="
  echo "1) Install / Update gost"
  echo "2) Install / Update Backhaul"
  echo "3) Configure Backhaul (IRAN / FOREIGN)"
  echo "4) Add gost tunnel"
  echo "5) Remove gost tunnel"
  echo "6) List tunnels"
  echo "7) Service status"
  echo "8) Restart services"
  echo "9) Remove ALL tunnels"
  echo "10) Install / Start DPI daemon"
  echo "0) Exit"
  read -p "Select: " C
  case "$C" in
    1) install_gost ;;
    2) install_backhaul ;;
    3) configure_backhaul ;;
    4) add_tunnel ;;
    5) remove_tunnel ;;
    6) list_tunnels ;;
    7) status_all ;;
    8) systemctl restart backhaul; for p in $(list_tunnels); do systemctl restart gost@$p; done ;;
    9) remove_all ;;
    10) install_daemon ;;
    0) exit ;;
  esac
  read -p "Press Enter..."
done
