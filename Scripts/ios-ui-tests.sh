#!/usr/bin/env bash
# Runs the iPhone and iPad UI tests (App/UITests) the way a person uses the
# app — software keyboard and key bar, a hardware keyboard on iPad, touch,
# rotation, the background — against a throwaway SSH host, on fresh
# simulators that are deleted afterwards.
#
#   Scripts/ios-ui-tests.sh               both devices
#   Scripts/ios-ui-tests.sh --phone-only  (or --pad-only)
#
# The host: a user-level sshd on 127.0.0.1 whose logins get their own home
# and tmux socket (nothing of this Mac's is touched). Each simulator signs
# in to it with a Relay key, set up through the app's own flow (the dev
# hook, Scripts/ios-dev-hook.py), then gets the projects and sessions the
# tests expect.
#
# Needs libghostty's iOS slices (Scripts/build-libghostty.sh --universal),
# XcodeGen, and tmux. RELAY_UITEST_SHOTS=<folder> keeps the tests'
# screenshots.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

DEVICES="phone pad"
case "${1:-}" in
  --phone-only) DEVICES="phone" ;;
  --pad-only) DEVICES="pad" ;;
  "") ;;
  *) echo "usage: $0 [--phone-only|--pad-only]" >&2; exit 2 ;;
esac

# A simulator and the build take several GB; stop before the disk does.
FREE_KB="$(df -k /tmp | tail -1 | awk '{print $4}')"
if [ "$FREE_KB" -lt $((6 * 1024 * 1024)) ]; then
  echo "error: needs about 6 GB free (has $((FREE_KB / 1024)) MB)." >&2
  exit 1
fi

BUNDLE=com.iddogino.Relay.dev
HOOK="$ROOT/Scripts/ios-dev-hook.py"
# Short: tmux's socket path lives under it (104-byte limit).
WORK="$(cd "$(mktemp -d /tmp/relay-ui.XXXXXX)" && pwd -P)"
# RELAY_UITEST_DERIVED: an Xcode derived data folder to build in (reuse).
DERIVED="${RELAY_UITEST_DERIVED:-$ROOT/.build/ios-ui-tests}"
SHOTS="${RELAY_UITEST_SHOTS:-$WORK/shots}"
mkdir -p "$SHOTS"
CREATED_DEVICES=()

cleanup() {
  [ -f "$WORK/sshd.pid" ] && kill "$(cat "$WORK/sshd.pid")" 2>/dev/null || true
  [ -d "$WORK/tmux" ] && TMUX_TMPDIR="$WORK/tmux" tmux kill-server 2>/dev/null || true
  for device in ${CREATED_DEVICES[@]+"${CREATED_DEVICES[@]}"}; do
    xcrun simctl shutdown "$device" 2>/dev/null || true
    xcrun simctl delete "$device" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1. The host.
HOME_DIR="$WORK/home"
mkdir -p "$HOME_DIR/.ssh" "$WORK/tmux"
chmod 700 "$WORK/tmux"
ssh-keygen -q -t ed25519 -N '' -C relay-ui-host -f "$WORK/hostkey"
ssh-keygen -q -t ed25519 -N '' -C relay-ui-bootstrap -f "$WORK/bootstrap"
cp "$WORK/bootstrap.pub" "$HOME_DIR/.ssh/authorized_keys"
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
TMUX_BIN="$(command -v tmux)"
cat > "$WORK/wrap.sh" <<EOF
#!/bin/sh
# Every login: the throwaway home and tmux directory (which must exist, or
# tmux would fall back to the user's default socket).
[ -d "$WORK/tmux" ] || exit 70
export HOME="$HOME_DIR" TMUX_TMPDIR="$WORK/tmux" PATH="$(dirname "$TMUX_BIN"):/usr/bin:/bin:/usr/sbin:/sbin" SHELL=/bin/zsh
cd "\$HOME"
if [ -n "\$SSH_ORIGINAL_COMMAND" ]; then exec /bin/sh -c "\$SSH_ORIGINAL_COMMAND"; else exec /bin/zsh -l; fi
EOF
chmod +x "$WORK/wrap.sh"
cat > "$WORK/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $WORK/hostkey
PidFile $WORK/sshd.pid
AuthorizedKeysFile $HOME_DIR/.ssh/authorized_keys
AllowUsers $(id -un)
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
ForceCommand $WORK/wrap.sh
AcceptEnv LANG LC_*
EOF
printf 'PROMPT="rig %%~ %%# "\n' > "$HOME_DIR/.zshrc"
# A repo with changes, for the diff tray.
mkdir -p "$HOME_DIR/repo"
(cd "$HOME_DIR/repo" && git init -q && echo hello > README.md && git add README.md \
  && git -c user.name=Relay -c user.email=relay@example.com commit -qm init \
  && printf 'hello\nworld\n' > README.md)
/usr/sbin/sshd -f "$WORK/sshd_config" -E "$WORK/sshd.log"

# 2. The app, built once for the Simulator (every device runs it).
xcodegen --spec App/project.yml >/dev/null
xcodebuild build-for-testing -project App/Relay.xcodeproj -scheme Relay -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" -quiet
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Relay Dev.app"

# The preferred device on the newest iOS runtime that has it — else the
# newest runtime's newest device of the kind — as "<runtime> <device type>".
pick_device() {
  xcrun simctl list -j runtimes | python3 -c '
import json, re, sys
kind, preferred = sys.argv[1], sys.argv[2]
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
runtimes.sort(key=lambda r: [int(n) for n in re.findall(r"\d+", r["version"])], reverse=True)
for runtime in runtimes:
    for device in runtime.get("supportedDeviceTypes", []):
        if device["name"] == preferred:
            print(runtime["identifier"], device["identifier"]); sys.exit()
for runtime in runtimes:
    devices = [t for t in runtime.get("supportedDeviceTypes", []) if t["name"].startswith(kind)]
    if devices:
        print(runtime["identifier"], devices[-1]["identifier"]); sys.exit()
sys.exit("no %s simulator" % kind)
' "$1" "$2"
}

# 3. Each device in turn — a fresh simulator, deleted before the next (a
# simulator takes a few GB): the app, its Relay key on the host, projects,
# sessions, then the tests.
hook() { HOOK_TIMEOUT=90 python3 "$HOOK" "$@"; }
expect_ok() { python3 -c 'import json, sys; r = json.load(sys.stdin); sys.exit(0 if r.get("ok") else "hook failed: %s" % r)'; }
delete_device() {
  xcrun simctl shutdown "$1" 2>/dev/null || true
  xcrun simctl delete "$1"
  CREATED_DEVICES=()
}

STATUS=0
for kind in $DEVICES; do
  if [ "$kind" = phone ]; then
    read -r runtime type < <(pick_device iPhone "iPhone 17 Pro")
    sessions="first second"
    tests=(TerminalUITests NavigationUITests GestureUITests LifecycleUITests ScreensUITests TraysUITests)
  else
    read -r runtime type < <(pick_device iPad "iPad Pro 13-inch (M5)")
    sessions="alpha beta"
    tests=(PadUITests ScreensUITests TraysUITests)
  fi
  device="$(xcrun simctl create "Relay UI Tests $kind" "$type" "$runtime")"
  CREATED_DEVICES=("$device")
  xcrun simctl boot "$device"
  echo "$kind: $type on $runtime ($device)"

  xcrun simctl install "$device" "$APP"
  xcrun simctl launch "$device" "$BUNDLE" >/dev/null
  # Ready once the dev hooks answer.
  for _ in $(seq 1 30); do
    HOOK_TIMEOUT=3 python3 "$HOOK" "$device" keys '{"op":"status"}' >/dev/null 2>&1 && break
    sleep 1
  done
  # The one-time sign-in that adds this device's Relay key; afterwards
  # only Relay keys sign in.
  cp "$WORK/bootstrap.pub" "$HOME_DIR/.ssh/authorized_keys.bootstrap"
  cat "$HOME_DIR/.ssh/authorized_keys" >> "$HOME_DIR/.ssh/authorized_keys.bootstrap"
  mv "$HOME_DIR/.ssh/authorized_keys.bootstrap" "$HOME_DIR/.ssh/authorized_keys"
  hook "$device" keys "{\"op\":\"setup\",\"alias\":\"rig\",\"hostname\":\"127.0.0.1\",\"port\":$PORT,\"user\":\"$(id -un)\",\"bootstrap\":\"keyFile\",\"keyFile\":\"$WORK/bootstrap\",\"storage\":\"iCloudKeychain\",\"trust\":true}" | expect_ok
  grep -v relay-ui-bootstrap "$HOME_DIR/.ssh/authorized_keys" > "$HOME_DIR/.ssh/authorized_keys.relay" || true
  mv "$HOME_DIR/.ssh/authorized_keys.relay" "$HOME_DIR/.ssh/authorized_keys"
  hook "$device" keys '{"op":"addProject","project":"Rig Repo","alias":"rig","path":"~/repo"}' | expect_ok
  if [ "$kind" = pad ]; then
    hook "$device" keys '{"op":"addProject","project":"Second Project","alias":"rig","path":"~"}' | expect_ok
    hook "$device" keys '{"op":"newSession","project":"Second Project","name":"gamma"}' | expect_ok
    clang -fobjc-arc -framework Foundation Scripts/ios-sim-keyboard.m -o "$WORK/ios-sim-keyboard"
    "$WORK/ios-sim-keyboard" "$device" 1 "$(xcode-select -p)"
  fi
  for name in $sessions; do
    hook "$device" keys "{\"op\":\"newSession\",\"project\":\"Rig Repo\",\"name\":\"$name\"}" | expect_ok
  done
  xcrun simctl terminate "$device" "$BUNDLE"

  only=()
  for test in "${tests[@]}"; do only+=("-only-testing:RelayUITests/$test"); done
  result="$WORK/$kind.xcresult"
  TEST_RUNNER_RELAY_UITEST_SHOTS="$SHOTS" \
    xcodebuild test-without-building -project App/Relay.xcodeproj -scheme Relay -configuration Debug \
      -destination "platform=iOS Simulator,id=$device" -derivedDataPath "$DERIVED" \
      -resultBundlePath "$result" "${only[@]}" -quiet || STATUS=1
  # -quiet hides the results, and a run with no tests passes too.
  xcrun xcresulttool get test-results summary --path "$result" --compact | python3 -c '
import json, sys
summary = json.load(sys.stdin)
print("%s %s: %d passed, %d failed, %d skipped" % (sys.argv[1], summary["result"], summary["passedTests"],
      summary["failedTests"], summary["skippedTests"]))
sys.exit(0 if summary["result"] == "Passed" and summary["passedTests"] > 0 else 1)
' "$kind" || STATUS=1
  [ -n "${RELAY_UITEST_SHOTS:-}" ] && cp -R "$result" "$SHOTS/" 2>/dev/null || true
  delete_device "$device"
done
exit $STATUS
