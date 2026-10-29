#!/bin/sh
# Runs a throwaway bridge with one platform block and asks its MCP server what the plugin put on it, then stops
# it. From the repository root, after a build:
#
#   .claude/skills/homeswift-plugin/scripts/check-on-bridge.sh <block.json> [<homeswift binary>]
#
# <block.json> holds the platform block, e.g. {"platform": "Example", "name": "Example"}. The bridge runs in a
# temporary directory (never ~/.homeswift) and advertises a new, unpaired identity while it runs. It prints the
# MCP answers (list_accessories), then the plugin's log lines. HOMESWIFT_CHECK_SETTLE (seconds, 5) is how long the
# plugin gets to add its accessories; HOMESWIFT_CHECK_MCP_PORT (18582) where the MCP server listens.
set -eu

[ $# -ge 1 ] || { echo "usage: $0 <block.json> [<homeswift binary>]" >&2; exit 2; }
block=$1
if [ $# -ge 2 ]; then
    binary=$2
elif [ -x .build/debug/homeswift ]; then
    binary=.build/debug/homeswift
else
    binary=$HOME/Library/Caches/homeswift-build/debug/homeswift
fi
[ -x "$binary" ] || { echo "no homeswift binary at $binary: build first, or pass its path" >&2; exit 1; }

port=${HOMESWIFT_CHECK_MCP_PORT:-18582}
settle=${HOMESWIFT_CHECK_SETTLE:-5}
directory=$(mktemp -d "${TMPDIR:-/tmp}/homeswift-check.XXXXXX")
token=$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')

cat > "$directory/config.json" <<EOF
{
  "bridge": { "name": "Homeswift Check" },
  "platforms": [
    $(cat "$block"),
    { "platform": "HomeswiftAiKit", "mcp": { "http": { "enabled": true, "port": $port, "token": "$token", "auditLog": false } } }
  ]
}
EOF

"$binary" -U "$directory" -D > "$directory/bridge.log" 2>&1 &
bridge=$!
trap 'kill $bridge 2>/dev/null; wait $bridge 2>/dev/null; rm -rf "$directory"' EXIT INT TERM

# The token goes in a file rather than on a command line other processes can read.
printf 'Authorization: Bearer %s\n' "$token" > "$directory/authorization"
tries=0
until curl -s -o /dev/null -H "@$directory/authorization" "http://127.0.0.1:$port/mcp"; do
    tries=$((tries + 1))
    if [ $tries -gt 150 ] || ! kill -0 $bridge 2>/dev/null; then
        echo "the bridge did not start; its log:" >&2
        cat "$directory/bridge.log" >&2
        exit 1
    fi
    sleep 0.2
done
sleep "$settle"

echo "== list_accessories"
HOMESWIFT_MCP_TOKEN=$token "$binary" -U "$directory" mcp --url "http://127.0.0.1:$port/mcp" <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check-on-bridge","version":"1"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_accessories","arguments":{}}}
EOF

platform=$(sed -n 's/.*"platform"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$block" | head -1)
echo
echo "== the log (${platform:-all})"
if [ -n "$platform" ]; then grep -i -e "$platform" -e "error" -e "warning" -e "Adaptive Lighting" "$directory/bridge.log" || true; else cat "$directory/bridge.log"; fi
