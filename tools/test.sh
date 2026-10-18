#!/usr/bin/env bash
# Single-player in-game test via PZTestHarness (pzt): an isolated, unattended client
# (-cachedir=pzt-env/Zomboid) continues tests/save, runs tests/BuildAhead_Test.lua and
# tests/BuildAhead_Test2.lua and quits (the game saves the world on quit). A second run
# (KEEP_SAVE=1) continues that saved world and checks that the planned sites and the
# ban list were kept (BuildAheadTest2.reloadStart).
# Settings: pzt.conf. Extra KEY=VALUE arguments go to pzt (e.g. MEM_WAIT=300 TIMEOUT=1800).
#
#   bash tools/test.sh [KEY=VALUE ...]
#
# Exit 1 on a failed check or when a run did not finish.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PZT="${PZT:-$ROOT/../PZTestHarness/pzt}"
# wait for another test client (e.g. IsoRotate's) to free memory instead of running in parallel
bash "$PZT" -C "$ROOT" run MEM_WAIT="${MEM_WAIT:-600}" "$@"
first=$?
echo "=== reload run (persistence) ==="
PZT_STEPS="lua BuildAheadTest2.reloadStart();lua BuildAheadTest2.poll()" \
  bash "$PZT" -C "$ROOT" run KEEP_SAVE=1 TIMEOUT=600 MEM_WAIT="${MEM_WAIT:-600}" "$@"
second=$?
echo "main run: $([ $first = 0 ] && echo PASS || echo FAIL), reload run: $([ $second = 0 ] && echo PASS || echo FAIL)"
[ $first = 0 ] && [ $second = 0 ]
