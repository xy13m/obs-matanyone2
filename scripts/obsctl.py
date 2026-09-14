#!/usr/bin/env -S uv run --quiet --with websocket-client python
# SPDX-License-Identifier: GPL-3.0-or-later
"""Drive the MatAnyone 2 filter over obs-websocket 5 for manual tests.

Enable the websocket server in OBS (Tools > WebSocket Server Settings); the
script reads the port and password from obs-websocket's config file.

Usage:
  scripts/obsctl.py status                       # the filter's status line
  scripts/obsctl.py press <action>               # capture_clean_plate | capture_props_plate |
                                                 # seed_now | reseed_now | clear_calibration
  scripts/obsctl.py set <key> <json-value>       # change one filter setting
  scripts/obsctl.py screenshot <path.png>        # program output
  scripts/obsctl.py source-screenshot <path.png> # the camera source before filters

Environment: OBS_SOURCE (default "Elgato 4K X"), OBS_FILTER (default
"MatAnyone 2 Matting"), OBS_SCENE (default "Elgato 4K X Camera").
"""
import base64
import hashlib
import json
import os
import sys

import websocket  # websocket-client

SOURCE = os.environ.get("OBS_SOURCE", "Elgato 4K X")
FILTER = os.environ.get("OBS_FILTER", "MatAnyone 2 Matting")
SCENE = os.environ.get("OBS_SCENE", "Elgato 4K X Camera")
CONFIG = os.path.expanduser(
    "~/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json")


def connect():
    cfg = json.load(open(CONFIG))
    ws = websocket.create_connection(f"ws://127.0.0.1:{cfg['server_port']}", timeout=10)
    hello = json.loads(ws.recv())["d"]
    auth = None
    if "authentication" in hello:
        a = hello["authentication"]
        secret = base64.b64encode(hashlib.sha256((cfg["server_password"] + a["salt"]).encode()).digest()).decode()
        auth = base64.b64encode(hashlib.sha256((secret + a["challenge"]).encode()).digest()).decode()
    ws.send(json.dumps({"op": 1, "d": {"rpcVersion": 1, "authentication": auth}}))
    json.loads(ws.recv())
    return ws


def request(ws, name, data=None, rid="1"):
    ws.send(json.dumps({"op": 6, "d": {"requestType": name, "requestId": rid, "requestData": data or {}}}))
    while True:
        msg = json.loads(ws.recv())
        if msg["op"] == 7 and msg["d"]["requestId"] == rid:
            d = msg["d"]
            if not d["requestStatus"]["result"]:
                raise SystemExit(f"{name} failed: {d['requestStatus']}")
            return d.get("responseData", {})


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    cmd = sys.argv[1]
    ws = connect()
    if cmd == "status":
        s = request(ws, "GetSourceFilter", {"sourceName": SOURCE, "filterName": FILTER})
        print(s["filterSettings"].get("status", "(no status yet)"))
    elif cmd == "press":
        request(ws, "TriggerHotkeyByName", {"hotkeyName": "matanyone2." + sys.argv[2]})
    elif cmd == "set":
        request(ws, "SetSourceFilterSettings",
                {"sourceName": SOURCE, "filterName": FILTER, "filterSettings": {sys.argv[2]: json.loads(sys.argv[3])}})
    elif cmd in ("screenshot", "source-screenshot"):
        name = SCENE if cmd == "screenshot" else SOURCE
        r = request(ws, "GetSourceScreenshot", {"sourceName": name, "imageFormat": "png", "imageWidth": 960})
        data = r["imageData"].split(",", 1)[1]
        open(sys.argv[2], "wb").write(base64.b64decode(data))
        print("wrote", sys.argv[2])
    ws.close()


if __name__ == "__main__":
    main()
