#!/usr/bin/env python3
"""ios-dev-hook.py <device> <keys|drive|sync|snapshot> [json]: runs one of
Relay Dev's dev hooks (Sources/RelayUI: HostKeyDevHook, TerminalSnapshots,
SyncDevHook) in an iOS Simulator and prints its result.

The request goes to the app's data folder in its container, a Darwin
notification triggers it (simctl spawn notifyutil), and the result file is
awaited. HOOK_TIMEOUT (seconds, default 60) bounds the wait.
RELAY_DATA_DIRECTORY names the app's data folder when the build was given
another (Scripts/store-screenshots.sh builds one that calls itself Relay)."""
import json, os, subprocess, sys, time

BUNDLE = "com.iddogino.Relay.dev"
HOOKS = {
    "keys": ("keys.json", "keys-result.json", "com.iddogino.Relay.dev.keys"),
    "drive": ("drive.json", "drive-result.json", "com.iddogino.Relay.dev.drive"),
    "sync": ("sync-request.json", "sync-result.json", "com.iddogino.Relay.dev.sync"),
    "snapshot": (None, "snapshots/done", "com.iddogino.Relay.dev.snapshot"),
}


def data_dir(device):
    container = subprocess.check_output(
        ["xcrun", "simctl", "get_app_container", device, BUNDLE, "data"], text=True).strip()
    path = os.path.join(container, "Library", "Application Support",
                        os.environ.get("RELAY_DATA_DIRECTORY", "Relay Dev"))
    os.makedirs(path, exist_ok=True)
    return path


def run(device, hook, request=None, timeout=60):
    request_name, result_name, notification = HOOKS[hook]
    folder = data_dir(device)
    result_path = os.path.join(folder, result_name)
    if os.path.exists(result_path):
        os.remove(result_path)
    if request_name:
        with open(os.path.join(folder, request_name), "w") as f:
            json.dump(request or {}, f)
    subprocess.check_call(["xcrun", "simctl", "spawn", device, "notifyutil", "-p", notification])
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(result_path):
            time.sleep(0.2)
            if hook == "snapshot":
                shots = os.path.join(folder, "snapshots")
                return {name: open(os.path.join(shots, name), errors="replace").read()
                        for name in sorted(os.listdir(shots)) if name.endswith((".txt", ".json"))}
            with open(result_path) as f:
                try:
                    return json.load(f)
                except json.JSONDecodeError:
                    time.sleep(0.5)
                    f.seek(0)
                    return json.load(f)
        time.sleep(0.2)
    raise SystemExit(f"no {result_name} after {timeout}s")


if __name__ == "__main__":
    device, hook = sys.argv[1], sys.argv[2]
    request = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    timeout = float(os.environ.get("HOOK_TIMEOUT", "60"))
    print(json.dumps(run(device, hook, request, timeout), indent=2, ensure_ascii=False))
