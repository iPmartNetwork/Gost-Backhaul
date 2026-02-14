#!/usr/bin/env bash
set -e

echo "=== Gost + Backhaul Ultimate Installer ==="

# ---------- SANITY ----------
[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1

# ---------- PATHS ----------
BIN=/usr/bin
CONF=/etc/gost
SWD=/opt/gost-switchd
STATE=/var/lib/gost-switchd
SYS=/lib/systemd/system
BHCONF=/etc/backhaul/config.toml

# ---------- ARCH ----------
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l) ARCH=armv7 ;;
  *) echo "Unsupported arch"; exit 1 ;;
esac

# ---------- DEPS ----------
if command -v apt >/dev/null; then
  apt update -y
  apt install -y curl jq tar python3 python3-pip iproute2 openssl netcat-openbsd
elif command -v yum >/dev/null; then
  yum install -y curl jq tar python3 python3-pip iproute openssl nc
fi
pip3 install --no-cache-dir requests

# ---------- INSTALL GOST ----------
echo "[+] Installing gost"
GOST_URL=$(curl -fsSL https://api.github.com/repos/go-gost/gost/releases/latest \
 | jq -r ".assets[] | select(.name|contains(\"linux\") and contains(\"$ARCH\")) | .browser_download_url" | head -n1)
curl -fL "$GOST_URL" -o /tmp/gost.tar.gz
tar -xzf /tmp/gost.tar.gz -C /tmp
install -m755 /tmp/gost $BIN/gost

# ---------- INSTALL BACKHAUL ----------
echo "[+] Installing Backhaul"
BH_URL=$(curl -fsSL https://api.github.com/repos/Musixal/Backhaul/releases/latest \
 | jq -r --arg a "linux_${ARCH}.tar.gz" '.assets[]|select(.name|endswith($a))|.browser_download_url' | head -n1)
mkdir -p /tmp/bh && curl -fL "$BH_URL" -o /tmp/bh.tgz
tar -xzf /tmp/bh.tgz -C /tmp/bh
install -m755 /tmp/bh/backhaul $BIN/backhaul

# ---------- BACKHAUL CONFIG ----------
read -p "Foreign server IP/domain: " FOREIGN
read -p "Backhaul remote port [9000]: " RPORT
read -p "Backhaul local port [4000]: " LPORT
RPORT=${RPORT:-9000}; LPORT=${LPORT:-4000}

mkdir -p /etc/backhaul
cat >$BHCONF <<EOF
[client]
remote_addr = "$FOREIGN:$RPORT"
local_addr  = "127.0.0.1:$LPORT"
EOF

cat >$SYS/backhaul.service <<EOF
[Unit]
After=network.target
[Service]
ExecStart=$BIN/backhaul -c $BHCONF
Restart=always
[Install]
WantedBy=multi-user.target
EOF

# ---------- GOST MULTI-PORT ----------
mkdir -p $CONF
read -p "Enter gost listen ports (comma separated): " PORTS
IFS=',' read -ra PORT_LIST <<< "$PORTS"

for P in "${PORT_LIST[@]}"; do
  P=$(echo $P | xargs)
  ss -lnt | grep -q ":$P " && echo "Port $P busy" && exit 1

cat >$CONF/$P.json <<EOF
{
  "Services":[{
    "Name":"gost-$P",
    "Addr":":$P",
    "Listener":{"Type":"tcp"},
    "Handler":{"Type":"tcp"},
    "Forwarder":{"Nodes":[{"Addr":"127.0.0.1:$LPORT"}]}
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

systemctl enable gost@$P
done

# ---------- DPI / QUIC DAEMON ----------
mkdir -p $SWD $STATE

cat >$SWD/gost-switchd.py <<'EOF'
#!/usr/bin/env python3
import os, json, time, subprocess

STATE="/var/lib/gost-switchd"
PORTS=[f.replace(".json","") for f in os.listdir("/etc/gost") if f.endswith(".json")]

PROFILES=["basic","ws","wss","reality","h3"]

def tcp_rst(p):
    out=subprocess.getoutput(f"timeout 3 nc -vz 127.0.0.1 {p}")
    return "refused" in out or "reset" in out

def tls_fail():
    o=subprocess.getoutput("timeout 5 openssl s_client -connect google.com:443")
    return "handshake" in o.lower()

while True:
    for p in PORTS:
        st=os.path.join(STATE,f"{p}.json")
        cur=json.load(open(st))["profile"] if os.path.exists(st) else PROFILES[0]

        if tcp_rst(p):
            nxt="reality"
        elif tls_fail():
            nxt="wss"
        else:
            nxt="basic"

        if nxt!=cur:
            json.dump({"profile":nxt,"ts":time.time()},open(st,"w"))
            subprocess.call(["systemctl","restart",f"gost@{p}"])
    time.sleep(30)
EOF
chmod +x $SWD/gost-switchd.py

cat >$SYS/gost-switchd.service <<EOF
[Unit]
After=network.target
[Service]
ExecStart=/usr/bin/python3 $SWD/gost-switchd.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF

# ---------- ENABLE ----------
systemctl daemon-reload
systemctl enable backhaul gost-switchd
systemctl restart backhaul gost-switchd
systemctl start gost@*

echo "=== INSTALL COMPLETE ==="
