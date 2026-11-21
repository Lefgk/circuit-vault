#!/usr/bin/env bash
# Update web/src/deployments.json for one chain. No secrets.
# Usage: write-web-config.sh <chainId> <factoryAddress> [usdcAddress] [poolAddress] [aTokenAddress]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="${DEPLOYMENTS_PATH:-$ROOT/web/src/deployments.json}"
CHAIN_ID=${1:?chain id}
FACTORY=${2:?factory address}
USDC=${3:-}
POOL=${4:-}
ATOKEN=${5:-}
if [ ! -f "$FILE" ]; then
  echo "write-web-config: $FILE not found" >&2
  exit 1
fi
tmp="$(mktemp)"
jq --arg c "$CHAIN_ID" --arg f "$FACTORY" --arg u "$USDC" --arg p "$POOL" --arg a "$ATOKEN" '
  .[$c] = ((.[$c] // {}) | .factory = $f
    | if $u != "" then .usdc = $u else . end
    | if $p != "" then .pool = $p else . end
    | if $a != "" then .aToken = $a else . end)
' "$FILE" > "$tmp"
mv "$tmp" "$FILE"
echo "Wrote factory $FACTORY to web/src/deployments.json (chain $CHAIN_ID)"
