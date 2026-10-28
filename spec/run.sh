#!/bin/sh
# Runs the behavior, exporter and translation harnesses. Override Lua with:
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

echo
echo "== harness_i18n.lua"
$LUA harness_i18n.lua ../*.lua
