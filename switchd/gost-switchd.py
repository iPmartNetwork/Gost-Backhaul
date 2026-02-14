#!/usr/bin/env python3
import os, time, json, subprocess, socket, requests

CONF_DIR = "/etc/gost"
STATE_DIR = "/var/lib/gost-switchd"
PROFILE_CFG = "/etc/gost/profiles.json"

INTERVAL = 30
COOLDOWN = 60

LOSS_UP = 20
LOSS_DOWN = 5

FAIL_TH = 2
SUCCESS_TH = 5

os.makedirs(STATE_DIR, exist_ok=True)

# ---------- load profiles ----------
profiles = json.load(open(PROFILE_CFG))
ORDER = profiles["order"]

# ---------- GEO ----------
def geo():
    try:
        c = requests.get("https://ipinfo.io/country", timeout=3).text.strip()
        return "IR" if c == "IR" else "FOREIGN"
    except:
        return "IR"

GEO = geo()
START = profiles["geo"][GEO]["start"]
MAX = profiles["geo"][GEO]["max"]
ALLOW_H3 = profiles["geo"][GEO]["allow_h3"]

# ---------- checks ----------
def packet_loss(proto="icmp"):
    cmd = "ping -c 5 -W 2 8.8.8.8" if proto == "icmp" else "ping -c 5 -W 2 -U 8.8.8.8"
    out = subprocess.getoutput(cmd)
    for l in out.splitlines():
        if "packet loss" in l:
            return int(l.split("%")[0].split()[-1])
    return 100

def tcp_ok(port):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=3)
        s.close()
        return True
    except:
        return False

def tls_fail():
    out = subprocess.getoutput("timeout 5 openssl s_client -connect google.com:443")
    return "handshake failure" in out.lower()

# ---------- state ----------
def load_state(port):
    p = f"{STATE_DIR}/{port}.json"
    if not os.path.exists(p):
        return {"profile": START, "fail": 0, "success": 0, "last": 0}
    return json.load(open(p))

def save_state(port, st):
    json.dump(st, open(f"{STATE_DIR}/{port}.json", "w"))

# ---------- main loop ----------
while True:
    tcp_loss = packet_loss("icmp")
    udp_loss = packet_loss("udp")
    tls_block = tls_fail()

    for f in os.listdir(CONF_DIR):
        if not f.endswith(".json"):
            continue

        port = int(f.replace(".json", ""))
        st = load_state(port)
        now = time.time()

        if now - st["last"] < COOLDOWN:
            continue

        ok_tcp = tcp_ok(port)
        cur = st["profile"]

        # --- DPI-aware decisions ---
        target = None

        if not ok_tcp and udp_loss < LOSS_DOWN and ALLOW_H3:
            target = "h3"                # TCP DPI → QUIC
        elif tls_block:
            target = "wss"
        elif tcp_loss > LOSS_UP:
            target = "cdn"

        # --- switch up ---
        if target and target != cur:
            st["profile"] = target
            st["last"] = now
            st["fail"] = 0
            subprocess.call(["systemctl", "restart", f"gost@{port}"])

        # --- classic fail ---
        elif tcp_loss > LOSS_UP or not ok_tcp:
            st["fail"] += 1
            st["success"] = 0
            if st["fail"] >= FAIL_TH:
                idx = ORDER.index(cur)
                if ORDER[idx] != MAX:
                    st["profile"] = ORDER[idx + 1]
                    st["last"] = now
                    st["fail"] = 0
                    subprocess.call(["systemctl", "restart", f"gost@{port}"])

        # --- rollback ---
        elif tcp_loss < LOSS_DOWN and ok_tcp:
            st["success"] += 1
            st["fail"] = 0
            if st["success"] >= SUCCESS_TH:
                idx = ORDER.index(cur)
                if ORDER[idx] != START:
                    st["profile"] = ORDER[idx - 1]
                    st["last"] = now
                    st["success"] = 0
                    subprocess.call(["systemctl", "restart", f"gost@{port}"])
        else:
            st["fail"] = 0
            st["success"] = 0

        save_state(port, st)

    time.sleep(INTERVAL)
