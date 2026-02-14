#!/usr/bin/env bash
set -e

### ========= GLOBAL =========
BIN="/usr/bin"
CONF="/etc/gost"
SYS="/lib/systemd/system"
BHCONF="/etc/backhaul/config.toml"
SWD="/opt/gost-switchd"
STATE="/var/lib/gost-switchd"

[[ $EUID -ne 0 ]] && echo "[ERROR] Run as root" && exit 1

### ========= DEPENDENCIES =========
install_deps() {
  if command -v jq >/dev/null 2>&1; then
    return
  fi

  echo "[INFO] Installing dependencies..."
  if command -v apt >/dev/null; then
    apt update -y
    apt install -y curl jq tar python3 python3-pip iproute2 openssl netcat-openbsd
  elif command -v yum >/dev/null; then
    yum install -y curl jq tar python3 python3-pip iproute openssl nc
  else
    echo "[ERROR] Unsupported OS"
    exit 1
  fi
}

install_deps

### ========= ARCH =========
detect_arch() {
  case "$(uname -m)" in
    x86_64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7l) ARCH=armv7 ;;
    *) echo "[ERROR] Unsupported architecture"; exit 1 ;;
  esac
}

### ========= INSTALL / UPDATE GOST =========
install_gost() {
  detect_arch
  echo "[INFO] Installing / Updating gost..."
  URL=$(curl -fsSL https://api.github.com/repos/go-gost/gost/releases/latest |
    jq -r ".assets[] | select(.name|contains(\"linux\") and contains(\"$ARCH\")) | .browser_download_url" | head -n1)

  [[ -z "$URL" ]] && { echo "[ERROR] gost binary not found"; return; }

  curl -fL "$URL" -o /tmp/gost.tgz
  tar -xzf /tmp/gost.tgz -C /tmp
  install -m755 /tmp/gost $BIN/gost
  gost -V
}

### ========= INSTALL / UPDATE BACKHAUL =========
install_backhaul() {
  detect_arch
  echo "[INFO] Installing / Updating Backhaul..."
  URL=$(curl -fsSL https://api.github.com/repos/Musixal/Backhaul/releases/latest |
    jq -r --arg a "linux_${ARCH}.tar.gz" '.assets[] | select(.name | endswith($a)) | .browser_download_url' | head -n1)

  [[ -z "$URL" ]] && { echo "[ERROR] Backhaul binary not found"; return; }

  mkdir -p /tmp/bh
  curl -fL "$URL" -o /tmp/bh.tgz
  tar -xzf /tmp/bh.tgz -C /tmp/bh
  install -m755 /tmp/bh/backhaul $BIN/backhaul
}

### ========= CONFIGURE BACKHAUL =========
configure_backhaul() {
  mkdir -p /etc/backhaul

  echo "1) IRAN (client)"
  echo "2) FOREIGN (server)"
  read -p "Select role: " R

  if [[ "$R" == "1" ]]; then
    read -p "Foreign server IP/domain: " F
    read -p "Remote port [9000]: " RP
    read -p "Local port [4000]: " LP
    RP=${RP:-9000}; LP=${LP:-4000}

cat >$BHCONF <<EOF
mode = "client"

[client]
remote = "$F:$RP"
bind   = "127.0.0.1:$LP"
EOF

  elif [[ "$R" == "2" ]]; then
    read -p "Listen port [9000]: " SP
    SP=${SP:-9000}

cat >$BHCONF <<EOF
mode = "server"

[server]
bind = "0.0.0.0:$SP"
EOF

  else
    echo "[ERROR] Invalid selection"
    return
  fi

cat >$SYS/backhaul.service <<EOF
[Unit]
After=network.target
[Service]
ExecStart=$BIN/backhaul -c $BHCONF
Restart=always
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable backhaul
  systemctl restart backhaul
}

### ========= GOST PORT MANAGEMENT =========
add_port() {
  mkdir -p $CONF
  read -p "Listen port: " P
  ss -lnt | grep -q ":$P " && echo "[ERROR] Port busy" && return

cat >$CONF/$P.json <<EOF
{
  "Services":[{
    "Name":"gost-$P",
    "Addr":":$P",
    "Listener":{"Type":"tcp"},
    "Handler":{"Type":"tcp"},
    "Forwarder":{"Nodes":[{"Addr":"127.0.0.1:4000"}]}
  }]
}
EOF

cat >$SYS/gost@$P.service <<EOF
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
}

remove_port() {
  read -p "Port to remove: " P
  systemctl stop gost@$P 2>/dev/null || true
  systemctl disable gost@$P 2>/dev/null || true
  rm -f $CONF/$P.json $SYS/gost@$P.service
  systemctl daemon-reload
}

list_ports() {
  ls $CONF/*.json 2>/dev/null | sed 's#.*/##;s#.json##'
}

remove_all_ports() {
  for p in $(list_ports); do
    systemctl stop gost@$p 2>/dev/null || true
    systemctl disable gost@$p 2>/dev/null || true
    rm -f $CONF/$p.json $SYS/gost@$p.service
  done
  systemctl daemon-reload
}

### ========= STATUS =========
status_all() {
  systemctl status backhaul --no-pager
  for p in $(list_ports); do
    systemctl status gost@$p --no-pager
  done
}

### ========= MENU =========
while true; do
  clear
  echo "========= Gost + Backhaul Manager ========="
  echo "1) Install / Update gost"
  echo "2) Install / Update Backhaul"
  echo "3) Configure Backhaul (IRAN / FOREIGN)"
  echo "4) Add new gost port"
  echo "5) Remove gost port"
  echo "6) List ports"
  echo "7) Service status"
  echo "8) Restart all services"
  echo "9) Remove ALL gost tunnels"
  echo "0) Exit"
  echo "=========================================="
  read -p "Select: " C

  case "$C" in
    1) install_gost ;;
    2) install_backhaul ;;
    3) configure_backhaul ;;
    4) add_port ;;
    5) remove_port ;;
    6) list_ports ;;
    7) status_all ;;
    8) systemctl restart backhaul; for p in $(list_ports); do systemctl restart gost@$p; done ;;
    9) remove_all_ports ;;
    0) exit ;;
  esac

  read -p "Press Enter to continue..."
done
