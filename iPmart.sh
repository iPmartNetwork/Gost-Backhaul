#!/usr/bin/env bash
set -e

BIN=/usr/bin
CONF=/etc/gost
SYS=/lib/systemd/system
BHCONF=/etc/backhaul/config.toml
SWD=/opt/gost-switchd

[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1

detect_arch() {
  case "$(uname -m)" in
    x86_64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7l) ARCH=armv7 ;;
    *) echo "Unsupported arch"; exit 1 ;;
  esac
}

install_deps() {
  if command -v apt >/dev/null; then
    apt update -y
    apt install -y curl jq tar python3 python3-pip iproute2 openssl netcat-openbsd
  else
    yum install -y curl jq tar python3 python3-pip iproute openssl nc
  fi
}

install_gost() {
  detect_arch
  URL=$(curl -fsSL https://api.github.com/repos/go-gost/gost/releases/latest |
    jq -r ".assets[]|select(.name|contains(\"linux\") and contains(\"$ARCH\"))|.browser_download_url"|head -n1)
  curl -fL "$URL" -o /tmp/gost.tgz
  tar -xzf /tmp/gost.tgz -C /tmp
  install -m755 /tmp/gost $BIN/gost
}

install_backhaul() {
  detect_arch
  URL=$(curl -fsSL https://api.github.com/repos/Musixal/Backhaul/releases/latest |
    jq -r --arg a "linux_${ARCH}.tar.gz" '.assets[]|select(.name|endswith($a))|.browser_download_url'|head -n1)
  curl -fL "$URL" -o /tmp/bh.tgz
  tar -xzf /tmp/bh.tgz -C /tmp
  install -m755 /tmp/backhaul $BIN/backhaul
}

create_gost_port() {
  read -p "Listen port: " P
  ss -lnt | grep -q ":$P " && echo "Port busy" && return

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

remove_gost_port() {
  read -p "Port to remove: " P
  systemctl stop gost@$P 2>/dev/null || true
  systemctl disable gost@$P 2>/dev/null || true
  rm -f $SYS/gost@$P.service $CONF/$P.json
  systemctl daemon-reload
}

list_ports() {
  ls $CONF/*.json 2>/dev/null | sed 's#.*/##;s#.json##'
}

backhaul_config() {
  echo "1) IRAN (client)"
  echo "2) FOREIGN (server)"
  read -p "Role: " R

  mkdir -p /etc/backhaul

  if [[ $R == 1 ]]; then
    read -p "Foreign IP: " F
    read -p "Remote port [9000]: " RP
    read -p "Local port [4000]: " LP
    RP=${RP:-9000}; LP=${LP:-4000}
cat >$BHCONF <<EOF
mode="client"
[client]
remote="$F:$RP"
bind="127.0.0.1:$LP"
EOF
  else
    read -p "Listen port [9000]: " SP
    SP=${SP:-9000}
cat >$BHCONF <<EOF
mode="server"
[server]
bind="0.0.0.0:$SP"
EOF
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
  systemctl restart backhaul
}

status_all() {
  systemctl status backhaul --no-pager
  systemctl status gost-switchd --no-pager
  for p in $(list_ports); do
    systemctl status gost@$p --no-pager
  done
}

menu() {
  clear
  echo "========= Gost + Backhaul Manager ========="
  echo "1) Install / Update gost"
  echo "2) Install / Update Backhaul"
  echo "3) Configure Backhaul (IRAN / FOREIGN)"
  echo "4) Add new gost port"
  echo "5) Remove gost port"
  echo "6) List ports"
  echo "7) Service status"
  echo "8) Restart all"
  echo "9) Remove ALL gost tunnels"
  echo "0) Exit"
  echo "=========================================="
}

mkdir -p $CONF

while true; do
  menu
  read -p "Select: " C
  case $C in
    1) install_gost ;;
    2) install_backhaul ;;
    3) backhaul_config ;;
    4) create_gost_port ;;
    5) remove_gost_port ;;
    6) list_ports ;;
    7) status_all ;;
    8) systemctl restart backhaul gost-switchd ;;
    9)
       for p in $(list_ports); do remove_gost_port; done ;;
    0) exit ;;
  esac
  read -p "Press Enter..."
done
