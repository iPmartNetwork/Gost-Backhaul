#!/usr/bin/env python3
import os, time, json, subprocess, socket, requests

CONF_DIR = "/etc/gost"
STATE_DIR = "/var/lib/gost-switchd"
INTERVAL = 30
COOLDOWN = 60

LOSS_UP = 20
LOSS_DOWN = 5

FAIL_THRESHOLD = 2
SUCCESS_THRESHOLD = 5

PROFILES = ["basic", "ws", "wss", "cdn", "reality", "ultimate"]

os.makedirs(STATE_DIR, exist_ok=True)

# ---------------- GEO ----------------
def geo():
    try:
        return requests.get("https://ipinfo.io/country", timeout=3).text.strip()
    except:
        return "IR"

GEO = geo()

START_PROFILE = "reality" if GEO == "IR" else "ws"
MAX_PROFILE   = "ultimate" if GEO == "IR" else "wss"

# ---------------- CHECKS ----------------
def packet_loss():
    out = subprocess.getoutput("ping -c 5 -W 2 8.8.8.8")
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

# ---------------- STATE ----------------
def load_state(port):
    path = f"{STATE_DIR}/{port}.json"
    if not os.path.exists(path):
        return {
            "profile": START_PROFILE,
            "fail": 0,
            "success": 0,
            "last": 0
        }
    return json.load(open(path))

def save_state(port, state):
    json.dump(state, open(f"{STATE_DIR}/{port}.json", "w"))

# ---------------- SWITCH ----------------
def switch_up(state):
    idx = PROFILES.index(state["profile"])
    if PROFILES[idx] == MAX_PROFILE:
        return False
    state["profile"] = PROFILES[idx + 1]
    return True

def switch_down(state):
    idx = PROFILES.index(state["profile"])
    if PROFILES[idx] == START_PROFILE:
        return False
    state["profile"] = PROFILES[idx - 1]
    return True

# ---------------- LOOP ----------------
while True:
    loss = packet_loss()

    for f in os.listdir(CONF_DIR):
        if not f.endswith(".json"):
            continue

        port = int(f.replace(".json", ""))
        state = load_state(port)
        now = time.time()

        if now - state["last"] < COOLDOWN:
            continue

        ok = tcp_ok(port)

        # FAIL path
        if loss > LOSS_UP or not ok:
            state["fail"] += 1
            state["success"] = 0

            if state["fail"] >= FAIL_THRESHOLD:
                if switch_up(state):
                    state["last"] = now
                    state["fail"] = 0
                    subprocess.call(["systemctl", "restart", f"gost@{port}"])
        # SUCCESS path (Rollback)
        elif loss < LOSS_DOWN and ok:
            state["success"] += 1
            state["fail"] = 0

            if state["success"] >= SUCCESS_THRESHOLD:
                if switch_down(state):
                    state["last"] = now
                    state["success"] = 0
                    subprocess.call(["systemctl", "restart", f"gost@{port}"])
        else:
            state["fail"] = 0
            state["success"] = 0

        save_state(port, state)

    time.sleep(INTERVAL)
