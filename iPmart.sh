#!/usr/bin/env bash
set -e

### ===== GLOBAL PATHS =====
BIN="/usr/bin"
CONF="/etc/gost"
SYS="/lib/systemd/system"
BHCONF="/etc/backhaul/config.toml"
SWD="/opt/gost-switchd"
STATE="/var/lib/gost-switchd"

[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1

### ===== DEPENDENCIES =====
install_deps() {
  if command -v jq >/dev/null; then return; fi
  if command -v apt >/dev/null; then
    apt update -y
    apt install -y curl jq tar python3 python3-pip iproute2 openssl netcat-openbsd
  else
    yum install -y curl jq tar python3 python3-pip iproute openssl nc
  fi
}
install_deps

### ===== ARCH =====
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l) ARCH=armv7 ;;
  *) echo "Unsupported arch"; exit 1 ;;
esac

### ===== INSTALL GOST =====
install_gost() {
  URL=$(curl -fsSL https://api.github.com/repos/go-gost/gost/releases/latest |
    jq -r ".assets[]|select(.name|contains(\"linux\") and contains(\"$ARCH\"))|.browser_download_url"|head -n1)
  curl -fL "$URL" -o /tmp/gost.tgz
  tar -xzf /tmp/gost.tgz -C /tmp
  install -m755 /tmp/gost $BIN/gost
}

### ===== INSTALL BACKHAUL =====
install_backhaul() {
  URL=$(curl -fsSL https://api.github.com/repos/Musixal/Backhaul/releases/latest |
    jq -r --arg a "linux_${ARCH}.tar.gz" '.assets[]|select(.name|endswith($a))|.browser_download_url'|head -n1)
  curl -fL "$URL" -o /tmp/bh.tgz
  tar -xzf /tmp/bh.tgz -C /tmp
  install -m755 /tmp/backhaul $BIN/backhaul
}

### ===== ADD PORT (ADVANCED) =====
add_port() {
  mkdir -p "$CONF" "$STATE"

  read -p "Enter ports (comma separated): " PORTS
  IFS=',' read -ra LIST <<< "$PORTS"

  echo "Select profile:"
  echo "1) IRAN"
  echo "2) FOREIGN"
  echo "3) Anti-DPI"
  read -p "Choice: " PF

  case "$PF" in
    1) PROFILE="IRAN"; ORDER='["reality","wss","ws","tcp"]' ;;
    2) PROFILE="FOREIGN"; ORDER='["tcp","ws"]' ;;
    3) PROFILE="ANTIDPI"; ORDER='["reality","quic","wss"]' ;;
    *) echo "Invalid profile"; return ;;
  esac

  for P in "${LIST[@]}"; do
    P=$(echo "$P"|xargs)
    ss -lnt | grep -q ":$P " && echo "Port $P busy, skipped" && continue

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
  "profile":"$PROFILE",
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
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost@$P
    systemctl start gost@$P
    echo "Port $P created ($PROTO / $PROFILE)"
  done
}

### ===== DPI / AUTO-SWITCH DAEMON =====
install_daemon() {
  mkdir -p "$SWD" "$STATE"

cat >"$SWD/gost-switchd.py" <<'EOF'
#!/usr/bin/env python3
import os,json,time,subprocess

STATE="/var/lib/gost-switchd"
CONF="/etc/gost"

def rst(port):
    o=subprocess.getoutput(f"timeout 3 nc -vz 127.0.0.1 {port}")
    return "reset" in o or "refused" in o

while True:
    for f in os.listdir(STATE):
        if not f.endswith(".json"): continue
        port=f.replace(".json","")
        s=json.load(open(f"{STATE}/{f}"))
        cur=s["current"]
        order=s["order"]
        if rst(port):
            idx=order.index(cur)
            if idx+1<len(order):
                nxt=order[idx+1]
                s["current"]=nxt
                json.dump(s,open(f"{STATE}/{f}","w"))
                cfg=f"{CONF}/{port}.json"
                data=json.load(open(cfg))
                data["Services"][0]["Listener"]["Type"]=nxt
                json.dump(data,open(cfg,"w"),indent=2)
                subprocess.call(["systemctl","restart",f"gost@{port}"])
        time.sleep(1)
    time.sleep(20)
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

### ===== MENU =====
while true; do
  clear
  echo "===== Gost + Backhaul Ultimate ====="
  echo "1) Install / Update gost"
  echo "2) Install / Update Backhaul"
  echo "3) Add port (per-port protocol + profile)"
  echo "4) Install / Start DPI daemon"
  echo "0) Exit"
  read -p "Select: " C
  case "$C" in
    1) install_gost ;;
    2) install_backhaul ;;
    3) add_port ;;
    4) install_daemon ;;
    0) exit ;;
  esac
  read -p "Press Enter..."
done
