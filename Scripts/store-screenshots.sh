#!/usr/bin/env bash
# Takes the App Store's iPhone and iPad screenshots: the app, in the sizes
# App Store Connect asks for (a 6.9-inch iPhone, a 13-inch iPad), showing a
# demo workspace on a throwaway SSH host.
#
#   Scripts/store-screenshots.sh <folder>               both devices
#   Scripts/store-screenshots.sh <folder> --phone-only  (or --pad-only)
#
# The host is Scripts/ios-ui-tests.sh's: a user-level sshd on 127.0.0.1 whose
# logins get their own home and tmux socket. Here its home holds a few demo
# projects, and its sessions are left showing something (a test run, a
# training log) before App/UITests/StoreScreenshots.swift walks the app
# through its screens. The app is the Debug build (for the dev hooks that
# set it up), told to call itself Relay.
#
# Needs libghostty's iOS slices (Scripts/build-libghostty.sh --universal),
# XcodeGen, and tmux.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

[ $# -ge 1 ] || { echo "usage: $0 <folder> [--phone-only|--pad-only]" >&2; exit 2; }
mkdir -p "$1"
SHOTS="$(cd "$1" && pwd -P)"
DEVICES="phone pad"
case "${2:-}" in
  --phone-only) DEVICES="phone" ;;
  --pad-only) DEVICES="pad" ;;
  "") ;;
  *) echo "usage: $0 <folder> [--phone-only|--pad-only]" >&2; exit 2 ;;
esac

FREE_KB="$(df -k /tmp | tail -1 | awk '{print $4}')"
if [ "$FREE_KB" -lt $((6 * 1024 * 1024)) ]; then
  echo "error: needs about 6 GB free (has $((FREE_KB / 1024)) MB)." >&2
  exit 1
fi

BUNDLE=com.iddogino.Relay.dev
HOOK="$ROOT/Scripts/ios-dev-hook.py"
export RELAY_DATA_DIRECTORY=Relay
# Short: tmux's socket path lives under it (104-byte limit).
WORK="$(cd "$(mktemp -d /tmp/relay-shots.XXXXXX)" && pwd -P)"
DERIVED="$ROOT/.build/store-screenshots"
CREATED_DEVICES=()

cleanup() {
  [ -f "$WORK/sshd.pid" ] && kill "$(cat "$WORK/sshd.pid")" 2>/dev/null || true
  [ -d "$WORK/tmux" ] && TMUX_TMPDIR="$WORK/tmux" tmux kill-server 2>/dev/null || true
  for device in ${CREATED_DEVICES[@]+"${CREATED_DEVICES[@]}"}; do
    xcrun simctl shutdown "$device" 2>/dev/null || true
    xcrun simctl delete "$device" 2>/dev/null || true
  done
  # The host's shells may still be writing as they go (zsh's history).
  rm -rf "$WORK" 2>/dev/null || { sleep 2; rm -rf "$WORK" || true; }
}
trap cleanup EXIT

# 1. The host, and what's on it.
HOME_DIR="$WORK/home"
mkdir -p "$HOME_DIR/.ssh" "$WORK/tmux"
chmod 700 "$WORK/tmux"
ssh-keygen -q -t ed25519 -N '' -C relay-shots-host -f "$WORK/hostkey"
ssh-keygen -q -t ed25519 -N '' -C relay-shots-bootstrap -f "$WORK/bootstrap"
cp "$WORK/bootstrap.pub" "$HOME_DIR/.ssh/authorized_keys"
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
TMUX_BIN="$(command -v tmux)"
cat > "$WORK/wrap.sh" <<EOF
#!/bin/sh
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
# A plain prompt, and each session's title what it's running (the caption
# under its name in the app; tmux's default is this Mac's host name).
cat > "$HOME_DIR/.zshrc" <<'EOF'
PROMPT="%F{cyan}%1~%f %F{green}❯%f "
precmd() { print -n "\e]2;zsh\a" }
preexec() { print -n "\e]2;${1#clear && }\a" }
EOF

# api: a repository with work in progress (the diff), and a test run.
API="$HOME_DIR/code/api"
mkdir -p "$API/src/auth" "$HOME_DIR/code/trainer" "$HOME_DIR/.dotfiles"
cat > "$API/src/auth/session.ts" <<'EOF'
import { sessions, type User } from '../store'

const REFRESH_WINDOW = 5 * 60 * 1000

export async function refresh(user: User) {
  const session = await sessions.find(user.id)
  return session.rotate()
}

export function expiresSoon(expiresAt: number) {
  return expiresAt - Date.now() < REFRESH_WINDOW
}
EOF
cat > "$API/Makefile" <<'EOF'
test:
	@sh scripts/test.sh
EOF
mkdir -p "$API/scripts"
cat > "$API/scripts/test.sh" <<'EOF'
g='\033[32m'; d='\033[2m'; b='\033[1m'; r='\033[0m'
printf "\n ${b}auth/session.test.ts${r}\n"
for t in "rotates the session on refresh:12" "keeps the old token until the new one is used:8" \
         "refuses a refresh after sign-out:5" "refreshes once for concurrent requests:31" \
         "treats a session as expiring 5 minutes early:2"; do
  printf "  ${g}\342\234\223${r} %s ${d}(%s ms)${r}\n" "${t%:*}" "${t#*:}"
done
printf "\n ${b}auth/token.test.ts${r}\n"
for t in "signs with the current key:4" "accepts the previous key during rotation:6" \
         "rejects an expired token:1"; do
  printf "  ${g}\342\234\223${r} %s ${d}(%s ms)${r}\n" "${t%:*}" "${t#*:}"
done
printf "\n ${g}${b}8 passed${r} ${d}in 0.41 s${r}\n\n"
EOF
(cd "$API" && git init -q -b main && git add -A \
  && git -c user.name=Relay -c user.email=relay@example.com commit -qm "Sessions and tokens" \
  && git checkout -q -b auth-refactor)
cat > "$API/src/auth/session.ts" <<'EOF'
import { sessions, type User } from '../store'
import { once } from '../util/once'

const REFRESH_WINDOW = 5 * 60 * 1000

// Concurrent requests share one refresh instead of racing to rotate.
export const refresh = once(async (user: User) => {
  const session = await sessions.find(user.id)
  if (session.revoked) throw new SignedOutError(user.id)
  return session.rotate({ keepPrevious: true })
})

export function expiresSoon(expiresAt: number) {
  return expiresAt - Date.now() < REFRESH_WINDOW
}
EOF
cat > "$HOME_DIR/code/trainer/train.py" <<'EOF'
import math, sys, time
print("\033[1msweep-lr\033[0m  lr=3e-4  batch=256  2x GPU\n")
loss = 2.31
for epoch in range(1, 400):
    loss = 0.18 + (loss - 0.18) * 0.82
    acc = 1 - loss / 2.6
    bar = "█" * min(20, epoch) + "░" * max(0, 20 - epoch)
    print(f"epoch {epoch:>2}/20 {bar} loss {loss:.3f}  acc \033[32m{acc:.1%}\033[0m")
    sys.stdout.flush()
    time.sleep(0.15 if epoch < 12 else 3600)
EOF
/usr/sbin/sshd -f "$WORK/sshd_config" -E "$WORK/sshd.log"

# 2. The app, built once for the Simulator, calling itself Relay.
xcodegen --spec App/project.yml >/dev/null
xcodebuild build-for-testing -project App/Relay.xcodeproj -scheme Relay -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" \
  RELAY_DATA_DIRECTORY=Relay -quiet
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Relay Dev.app"
# iPadOS shows the app's name beside the clock.
plutil -replace CFBundleDisplayName -string Relay "$APP/Info.plist"
codesign --force --sign - --preserve-metadata=entitlements "$APP" 2>/dev/null

pick_device() {
  xcrun simctl list -j runtimes | python3 -c '
import json, re, sys
preferred = sys.argv[1]
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
runtimes.sort(key=lambda r: [int(n) for n in re.findall(r"\d+", r["version"])], reverse=True)
for runtime in runtimes:
    for device in runtime.get("supportedDeviceTypes", []):
        if device["name"] == preferred:
            print(runtime["identifier"], device["identifier"]); sys.exit()
sys.exit("no %s simulator" % preferred)
' "$1"
}

hook() { HOOK_TIMEOUT=90 python3 "$HOOK" "$@"; }
expect_ok() { python3 -c 'import json, sys; r = json.load(sys.stdin); sys.exit(0 if r.get("ok") else "hook failed: %s" % r)'; }
backend() { python3 -c 'import json, sys; r = json.load(sys.stdin); sys.exit("hook failed: %s" % r) if not r.get("ok") else print(r["session"]["backendID"])'; }
# Adds a host under `alias` (the same sshd each time), signing in once with
# the bootstrap key to add this device's Relay key.
add_host() {
  cat "$WORK/bootstrap.pub" >> "$HOME_DIR/.ssh/authorized_keys"
  hook "$device" keys "{\"op\":\"setup\",\"alias\":\"$1\",\"hostname\":\"127.0.0.1\",\"port\":$PORT,\"user\":\"$(id -un)\",\"bootstrap\":\"keyFile\",\"keyFile\":\"$WORK/bootstrap\",\"storage\":\"iCloudKeychain\",\"trust\":true}" | expect_ok
  grep -v relay-shots-bootstrap "$HOME_DIR/.ssh/authorized_keys" > "$HOME_DIR/.ssh/authorized_keys.relay" || true
  mv "$HOME_DIR/.ssh/authorized_keys.relay" "$HOME_DIR/.ssh/authorized_keys"
}
# A session, then what it should be showing, typed into it on the host.
session() {
  local id
  id="$(hook "$device" keys "{\"op\":\"newSession\",\"project\":\"$1\",\"name\":\"$2\"}" | backend)"
  [ -z "${3:-}" ] || TMUX_TMPDIR="$WORK/tmux" tmux send-keys -t "=$id:" "$3" Enter
}

STATUS=0
for kind in $DEVICES; do
  if [ "$kind" = phone ]; then
    read -r runtime type < <(pick_device "iPhone 17 Pro Max")
  else
    read -r runtime type < <(pick_device "iPad Pro 13-inch (M5)")
  fi
  device="$(xcrun simctl create "Relay Screenshots $kind" "$type" "$runtime")"
  CREATED_DEVICES=("$device")
  xcrun simctl boot "$device"
  xcrun simctl ui "$device" appearance dark
  xcrun simctl status_bar "$device" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  echo "$kind: $type on $runtime ($device)"

  xcrun simctl install "$device" "$APP"
  xcrun simctl launch "$device" "$BUNDLE" >/dev/null
  for _ in $(seq 1 30); do
    HOOK_TIMEOUT=3 python3 "$HOOK" "$device" keys '{"op":"status"}' >/dev/null 2>&1 && break
    sleep 1
  done
  add_host mac-mini
  add_host gpu-box
  hook "$device" keys '{"op":"addProject","project":"api","alias":"mac-mini","path":"~/code/api"}' | expect_ok
  hook "$device" keys '{"op":"addProject","project":"trainer","alias":"gpu-box","path":"~/code/trainer"}' | expect_ok
  hook "$device" keys '{"op":"addProject","project":"dotfiles","alias":"mac-mini","path":"~/.dotfiles"}' | expect_ok
  session api auth-refactor "clear && make test"
  session api fix-flaky-tests "clear && git log --oneline"
  session api dev-server ""
  session trainer sweep-lr "clear && python3 train.py"
  session dotfiles scratch ""
  xcrun simctl terminate "$device" "$BUNDLE"

  result="$WORK/$kind.xcresult"
  TEST_RUNNER_RELAY_STORE_SHOTS="$SHOTS" \
    xcodebuild test-without-building -project App/Relay.xcodeproj -scheme Relay -configuration Debug \
      -destination "platform=iOS Simulator,id=$device" -derivedDataPath "$DERIVED" \
      -resultBundlePath "$result" -only-testing:RelayUITests/StoreScreenshots -quiet || STATUS=1
  [ "$STATUS" = 0 ] || cp -R "$result" "$SHOTS/" 2>/dev/null || true
  # The iPad's are taken on its side, and a screenshot is the screen as
  # it's built, portrait: turned to read as the iPad was held.
  if [ "$kind" = pad ]; then
    for shot in "$SHOTS"/ipad-*.png; do
      [ "$(sips -g pixelWidth "$shot" | awk '/pixelWidth/ {print $2}')" -gt 2400 ] || sips -r 270 "$shot" >/dev/null
    done
  fi
  xcrun simctl shutdown "$device" 2>/dev/null || true
  xcrun simctl delete "$device"
  CREATED_DEVICES=()
done
ls -1 "$SHOTS"
exit $STATUS
