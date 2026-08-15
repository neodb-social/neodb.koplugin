#!/bin/sh
# Runs both harnesses. Give it a lua if the default is not luajit:
#
#     ./run.sh            # luajit
#     LUA=lua5.1 ./run.sh
#
# The exporter harness is run in a DST-observing zone on purpose: its clock cases
# turn on a wall-clock time that does not exist locally, and a zone without a gap
# skips them.
set -e
cd "$(dirname "$0")"
LUA=${LUA:-luajit}

echo "== harness.lua"
$LUA harness.lua

echo
echo "== harness_exporter.lua (TZ=America/New_York)"
TZ=America/New_York $LUA harness_exporter.lua
