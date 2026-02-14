#!/usr/bin/env python3
import os, time, json, subprocess, socket, requests

CONF_DIR = "/etc/gost"
STATE_DIR = "/var/lib/gost-switchd"
CHECK_INTERVAL = 30
COOLDOWN = 60

PROFILES = ["basic", "ws", "wss", "cdn", "reality", "ultimate"]

os.makedirs(STATE_DIR, exist_ok=True)

def geo_detect():
    try:
        r = requests.get("https://ipinfo.io/country", timeout=3)
        return r.text.strip()
    except:
        return "IR"

GEO = geo_detect()

def tcp_check(port):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=3)
        s.close()
        return True
    except:
        return False

def packet_loss():
    p = subprocess.getoutput("ping -c 5 -W 2 8.8.8.8")
    for line in p.splitlines():
        if "packet loss" in line:
            return int(line.split("%")[0].split()[-1])
    return 100

def load_state(port, start):
    path = f"{STATE_DIR}/{port}.json"
    if not os.path.exists(path):
        return {
            "profile": start,
            "fail": 0,
            "last": 0
        }
    return json.load(open(path))

def save_state(port, state):
    json.dump(state, open(f"{STATE_DIR}/{port}.json", "w"))

START_PROFILE = "reality" if GEO == "IR" else "ws"
MAX_PROFILE   = "ultimate" if GEO == "IR" else "wss"

while True:
    loss = packet_loss()
    for f in os.listdir(CONF_DIR):
        if not f.endswith(".json"):
            continue

        port = int(f.replace(".json", ""))
        state = load_state(port, START_PROFILE)

        now = time.time()
        if now - state["last"] < COOLDOWN:
            continue

        if loss > 20 or not tcp_check(port):
            idx = PROFILES.index(state["profile"])
            if PROFILES[idx] == MAX_PROFILE:
                continue

            state["profile"] = PROFILES[idx + 1]
            state["last"] = now
            save_state(port, state)

            subprocess.call(["systemctl", "restart", f"gost@{port}"])

    time.sleep(CHECK_INTERVAL)
