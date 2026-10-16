#!/usr/bin/env bash
# Funds one pool from the owner's plain wallet, after the deployer has offered it the hook (00, 01, 03).
# Put the wallet's key in .env as PRIVATE_KEY=0x..., then:
#
#   script/fund.sh check     reads only: every check, then a dry run of the funding transaction
#   script/fund.sh send      deploys an anchor, sends the one EIP-7702 transaction (accept, put the price
#                            back on the oracle, deposit), clears the borrowed code, checks the result
#
# A second argument names another settings file (default script/mainnet/eth-hollar.env).
set -euo pipefail
cd "$(dirname "$0")/.."
MODE=${1:-}
SETTINGS=${2:-script/mainnet/eth-hollar.env}
case $MODE in
check | send) ;;
*) sed -n 2,9p "$0"; exit 1 ;;
esac

# the key from .env unless one is set already; the settings file last, so its values win
if [ -z "${PRIVATE_KEY:-}" ] && [ -f .env ]; then set -a; source .env; set +a; fi
[ -n "${PRIVATE_KEY:-}" ] || { echo "put the wallet's key in .env as PRIVATE_KEY=0x..."; exit 1; }
set -a; source "$SETTINGS"; set +a
for v in RPC CHAIN_ID HOOK NEW_OWNER FUND_ETH SIMPLE7702; do
  [ -n "${!v:-}" ] || { echo "$v is empty in $SETTINGS"; exit 1; }
done
FUND_AMOUNT0=$(cast to-wei "$FUND_ETH")
export FUND_AMOUNT0
WALLET=$(cast wallet address --private-key "$PRIVATE_KEY")
STATE=broadcast/wallet-fund/$CHAIN_ID
mkdir -p "$STATE"

# WalletFund with its output in a log: on success the script's own lines, on failure the reason.
walletfund() {
  local log=$STATE/$1.log; shift
  if forge script script/WalletFund.s.sol --rpc-url "$RPC" "$@" > "$log" 2>&1; then
    sed -n '/== Logs ==/,/^$/p' "$log" | sed '1d;/^$/d'
  else
    grep -E "Error|revert" "$log" | head -3
    echo "nothing was sent (full output: $log)"
    exit 1
  fi
}

# the status of a transaction from cast's JSON receipt
status() { grep -o '"status":"0x[01]"' "$1" | grep -o '0x[01]'; }

echo "== check: wallet $WALLET, hook $HOOK, $FUND_ETH ETH"
walletfund check
if [ "$MODE" = check ]; then
  echo "check passed: nothing was sent. Next: script/fund.sh send"
  exit 0
fi

echo "== send: deploy the anchor from the wallet"
MANAGER=$(cast call "$HOOK" 'manager()(address)' --rpc-url "$RPC")
ANCHOR=$(forge create script/PoolAnchor.sol:PoolAnchor --rpc-url "$RPC" --private-key "$PRIVATE_KEY" \
  --broadcast --constructor-args "$MANAGER" | awk '/Deployed to:/ {print $3}')
[ -n "$ANCHOR" ] || { echo "the anchor was not deployed: nothing else was sent"; exit 1; }
echo "anchor $ANCHOR"
walletfund prepare --sig 'prepare(address,string)' "$ANCHOR" "$STATE/batch.calldata"

echo "== send: the one transaction"
sent=yes
cast send "$WALLET" "$(cat "$STATE/batch.calldata")" --auth "$SIMPLE7702" \
  --private-key "$PRIVATE_KEY" --rpc-url "$RPC" --json > "$STATE/batch.json" || sent=no

# the borrowed code stays even when the batch fails, so clear it whatever happened
if [ "$(cast code "$WALLET" --rpc-url "$RPC")" != "0x" ]; then
  cast send "$WALLET" --auth 0x0000000000000000000000000000000000000000 \
    --private-key "$PRIVATE_KEY" --rpc-url "$RPC" --json > "$STATE/clear.json"
fi
[ "$(cast code "$WALLET" --rpc-url "$RPC")" = "0x" ] || {
  echo "the wallet still has borrowed code; clear it with:"
  echo "  cast send $WALLET --auth 0x0000000000000000000000000000000000000000 --private-key <key> --rpc-url $RPC"
  exit 1
}
[ "$sent" = yes ] || {
  echo "cast send did not confirm the batch: the node refused it (nothing sent) or it timed out (it may still go through)"
  echo "run script/fund.sh check before anything else: it says if the wallet still has borrowed code or the pool is funded"
  exit 1
}
[ "$(status "$STATE/batch.json")" = 0x1 ] || {
  echo "the batch reverted on chain: nothing was funded, only gas was spent; the borrowed code is cleared"
  exit 1
}
echo "batch $(grep -o '"transactionHash":"0x[0-9a-f]*"' "$STATE/batch.json" | head -1 | cut -d'"' -f4)"

echo "== result"
walletfund verify --sig 'verify()'
