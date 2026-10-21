#!/bin/sh
# Builds both servers and the controller, runs the suite against each server and prints the comparison.
#   ./run.sh                 # 30 accessories, default iteration counts
#   ./run.sh --accessories 100 --requests 1000
# Results land in results/<name>.json and results/<name>.log.
set -e
cd "$(dirname "$0")"
SCRATCH=${SCRATCH:-$HOME/Library/Caches/homeswift-bench}
OUT=${OUT:-results}

swift build -c release --scratch-path "$SCRATCH"
BIN=$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)
(cd hap-nodejs && npm install --no-audit --no-fund --silent)

"$BIN/hap-bench" run --name homeswift --port 52000 --output "$OUT" "$@" -- "$BIN/hap-bench-server"
"$BIN/hap-bench" run --name hap-nodejs --port 52001 --output "$OUT" "$@" -- node hap-nodejs/server.js
"$BIN/hap-bench" compare "$OUT/homeswift.json" "$OUT/hap-nodejs.json"
