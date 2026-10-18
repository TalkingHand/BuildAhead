#!/usr/bin/env bash
# Multiplayer test: a local dedicated server and one client, both -nosteam with their own
# data folders (mpenv/server, mpenv/client), on port 16361 so a normal server on 16261 is not touched.
# The client runs tests/BuildAhead_MPTest.lua: connects as admin, skips character creation, tests.
# IsoRotate's Java part (via ZombieBuddy) only passes the "click to start" screen on the client.
#
#   bash tools/mptest.sh
#
# The first client run ends by asking the server to save and quit (/quit); the server and a
# second client run ("persist") are then started again to check that the site list was kept.
# Results: "[BuildAheadMP]" lines in mpenv/client/console_on.txt and console_persist.txt,
# "[BuildAhead] server" in mpenv/server.log and server2.log; exit 1 on a failed check.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PZ_DIR="${PZ_DIR:-/c/Program Files (x86)/Steam/steamapps/common/ProjectZomboid}"
SRC_ENV="$ROOT/pzt-env/Zomboid"   # options and mods for a new client folder, from the pzt test folder
SRV="$ROOT/mpenv/server"
CLI="$ROOT/mpenv/client"
TIMEOUT="${TIMEOUT:-1200}"   # per client run
NAME=buildahead

install_mod() {
  rm -rf "$1/mods/BuildAhead"
  mkdir -p "$1/mods"
  cp -r "$ROOT/Contents/mods/BuildAhead" "$1/mods/BuildAhead"
  # same files on both sides; the test only runs where its trigger file exists
  cp "$ROOT/tests/BuildAhead_MPTest.lua" "$1/mods/BuildAhead/42/media/lua/client/"
}

# ---- server: fresh world every run
rm -rf "$SRV/Saves" "$SRV/db" "$ROOT/mpenv/server.log" "$ROOT/mpenv/server2.log"
mkdir -p "$SRV/Server"
install_mod "$SRV"
# a fixed spawn (where the test squares around the player are reachable): a random spawn
# may put them behind a fence
cat > "$SRV/Server/$NAME.ini" <<EOF
Mods=BuildAhead
WorkshopItems=
Map=Muldraugh, KY
Open=true
Public=false
PauseEmpty=false
DoLuaChecksum=false
DefaultPort=16361
SpawnPoint=10997,9699,0
UDPPort=16362
EOF

# no zombies: their hits interrupt the walks and builds under test
# (the server writes this file on its first start; later runs edit it)
SANDBOX="$SRV/Server/${NAME}_SandboxVars.lua"
if [ -f "$SANDBOX" ]; then
  sed -i -E 's/^(\s*Zombies = )[0-9]+,/\16,/; s/^(\s*Population(Start|Peak)?Multiplier = )[0-9.]+,/\10.0,/' "$SANDBOX"
fi

# ---- client
if [ ! -d "$CLI" ]; then
  mkdir -p "$CLI"
  for f in "$SRC_ENV"/*; do
    case "$(basename "$f")" in
      Saves|Screenshots|Logs|logs.zip|console.txt|latestSave.ini|isorotate_autotest.txt) ;;
      *) cp -r "$f" "$CLI/" ;;
    esac
  done
fi
install_mod "$CLI"
printf 'VERSION = 1,\n\nmods\n{\n    mod = ZombieBuddy,\n    mod = IsoRotate,\n    mod = BuildAhead,\n}\n\nmaps\n{\n}\n' > "$CLI/mods/default.txt"
rm -f "$CLI/Lua/buildahead_test.txt" "$CLI/Lua/buildahead_mppersist.txt" "$CLI"/console*.txt
mkdir -p "$CLI/Lua"

pids() {
  powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { \$_.CommandLine -like '*BuildAhead*mpenv*' -and (\$_.Name -eq '$1' -or ('$1' -eq '' -and (\$_.Name -eq 'java.exe' -or \$_.Name -eq 'ProjectZomboid64.exe'))) } | ForEach-Object { \$_.ProcessId }" 2>/dev/null | tr -d '\r'
}
stop_all() {
  for pid in $(pids ""); do taskkill //PID "$pid" //F > /dev/null 2>&1 || true; done
}
trap stop_all EXIT


# $1 = server log file
start_server() {
  echo "starting server..."
  ( cd "$PZ_DIR" && ./jre64/bin/java.exe --enable-native-access=ALL-UNNAMED --add-exports=java.base/jdk.internal.misc=ALL-UNNAMED \
      -XX:+UseZGC -XX:-CreateCoredumpOnCrash -XX:-OmitStackTraceInFastThrow -Xmx2048m \
      "-Djava.library.path=./natives/;./natives/win64/;./" -cp "./;projectzomboid.jar" zombie.network.GameServer \
      -nosteam "-cachedir=$(cygpath -w "$SRV")" -servername $NAME -adminusername admin -adminpassword buildahead \
      > "$1" 2>&1 ) &
  local t0=$SECONDS
  until grep -q "SERVER STARTED" "$1" 2>/dev/null; do
    sleep 3
    if [ $((SECONDS - t0)) -gt 600 ]; then echo "server did not start"; tail -20 "$1"; exit 1; fi
  done
  echo "server started after $((SECONDS - t0))s"
}

# $1 = test mode for the client ("on": the main test, "persist": the check after the restart)
run_client() {
  echo "$1" > "$CLI/Lua/buildahead_mptest.txt"
  # "autoload" makes IsoRotate pass "click to start"; with no single-player save it has nothing to continue
  echo autoload > "$CLI/isorotate_autotest.txt"
  rm -f "$CLI/console.txt"
  echo "starting client ($1)..."
  ( cd "$PZ_DIR" && ./ProjectZomboid64.exe "-agentlib:zbNative=policy=allow-all" -- \
      -nosteam -debug -nosound "-cachedir=$(cygpath -w "$CLI")" > "$ROOT/mpenv/client.log" 2>&1 ) &
  local done=0 t0=$SECONDS
  while [ $((SECONDS - t0)) -lt "$TIMEOUT" ]; do
    sleep 3
    # IsoRotate's own autotest would start at game start if the trigger file were still there
    if [ -f "$CLI/isorotate_autotest.txt" ] && grep -q "\[BuildAheadMP\] connecting" "$CLI/console.txt" 2>/dev/null; then
      sleep 5
      rm -f "$CLI/isorotate_autotest.txt"
    fi
    grep -q "\[BuildAheadMP\] test done" "$CLI/console.txt" 2>/dev/null && { done=1; sleep 5; break; }
  done
  rm -f "$CLI/isorotate_autotest.txt"
  cp "$CLI/console.txt" "$CLI/console_$1.txt" 2>/dev/null || true
  [ "$done" = 1 ] || echo "client ($1) did not finish"
}

start_server "$ROOT/mpenv/server.log"
run_client on

# the test asked the server to save and quit (/quit): wait for it, then restart both
if grep -q "asking the server to save and quit" "$CLI/console_on.txt" 2>/dev/null; then
  t0=$SECONDS
  while [ -n "$(pids java.exe)" ] && [ $((SECONDS - t0)) -lt 120 ]; do sleep 3; done
  if [ -n "$(pids java.exe)" ]; then echo "server did not quit after /quit"; else echo "server quit after $((SECONDS - t0))s"; fi
  stop_all
  sleep 3
  start_server "$ROOT/mpenv/server2.log"
  run_client persist
fi

echo "--- client ---"
grep -hE "\[BuildAhead(MP)?\]|MOD:Build Ahead|STACK TRACE|attempted index" "$CLI/console_on.txt" "$CLI/console_persist.txt" 2>/dev/null | tail -80 || echo "(no client console)"
echo "--- server ---"
grep -hE "\[BuildAhead\]|MOD:Build Ahead|attempted index" "$ROOT/mpenv/server.log" "$ROOT/mpenv/server2.log" 2>/dev/null | tail -30 || echo "(no server console)"
pass=$(cat "$CLI"/console_on.txt "$CLI"/console_persist.txt 2>/dev/null | grep -ac "\[BuildAheadMP\] PASS" || true)
fail=$(cat "$CLI"/console_on.txt "$CLI"/console_persist.txt 2>/dev/null | grep -aEc "\[BuildAheadMP\] (FAIL|ERROR)" || true)
runs=$(cat "$CLI"/console_on.txt "$CLI"/console_persist.txt 2>/dev/null | grep -ac "\[BuildAheadMP\] test done" || true)
echo "MP total: pass ${pass:-0} fail ${fail:-0} (finished runs ${runs:-0} of 2)"
[ "${fail:-0}" = 0 ] && [ "${runs:-0}" = 2 ]
