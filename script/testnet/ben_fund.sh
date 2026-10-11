#!/usr/bin/env bash
# Ben funds one pool in one EIP-7702 transaction: his wallet borrows Simple7702Account's code and
# runs SafeFund's call list (approve, anchor the price onto the oracle, approve, fund) as one batch,
# so nobody can move the price between the anchor and the fund. A second transaction clears the
# borrowed code, so his wallet is plain again.
#
#   ben_fund.sh <pool>        e.g. ben_fund.sh hdx-hollar
#
# env (rehearse.sh exports it): RPC, BEN, BEN_PK, SIMPLE7702, BEN_ANCHOR, POOL_ID, STATE, the pool's settings.
# Writes Ben's balances around the batch and what both transactions cost to $STATE/ben-<pool>.env.
set -euo pipefail
POOL=$1

owner=$(cast call "$HOOK" 'owner()(address)' -r "$RPC")
[ "$owner" = "$BEN" ] || { echo "  Ben does not own $HOOK yet (owner $owner): acceptOwnership first"; exit 1; }

KEY="($CURRENCY0,$CURRENCY1,8388608,$TICK_SPACING,$HOOK)"
SRC=$(cast call "$HOOK" 'config(bytes32)(address,uint24,uint24,uint32,uint32,int24,int24,uint16,int24,int24,bool,bool)' "$POOL_ID" -r "$RPC" | head -1)
PX=$(cast call "$SRC" 'priceX18()(uint256,uint256)' -r "$RPC" | head -1 | awk '{print $1}')
# the oracle price as a pool price, the same sum as PoolScript._sqrtPriceX96
TARGET=$(python3 -I -c "import math; print(math.isqrt($PX * 2**128 // 10**18) << 32)")

H=$BEN_ANCHOR
ap() { cast calldata 'approve(address,uint256)' "$1" "$2"; }
ANCHOR=$(cast calldata 'anchor((address,address,uint24,int24,address),uint160,uint256,uint256)' "$KEY" "$TARGET" "$ANCHOR_MAX0" "$ANCHOR_MAX1")
FUND=$(cast calldata 'fund(bytes32,uint256,uint256)' "$POOL_ID" "$FUND_AMOUNT0" "$FUND_AMOUNT1")
if [ "$CURRENCY0" = "0x0000000000000000000000000000000000000000" ]; then
  CALLS="[($CURRENCY1,0,$(ap $H $ANCHOR_MAX1)),($H,$ANCHOR_MAX0,$ANCHOR),($CURRENCY1,0,$(ap $HOOK $FUND_AMOUNT1)),($HOOK,$FUND_AMOUNT0,$FUND)]"
  bal0() { cast balance "$BEN" -r "$RPC"; }
else
  CALLS="[($CURRENCY0,0,$(ap $H $ANCHOR_MAX0)),($CURRENCY1,0,$(ap $H $ANCHOR_MAX1)),($H,0,$ANCHOR),($CURRENCY0,0,$(ap $HOOK $FUND_AMOUNT0)),($CURRENCY1,0,$(ap $HOOK $FUND_AMOUNT1)),($HOOK,0,$FUND)]"
  bal0() { cast call "$CURRENCY0" 'balanceOf(address)(uint256)' "$BEN" -r "$RPC" | awk '{print $1}'; }
fi
bal1() { cast call "$CURRENCY1" 'balanceOf(address)(uint256)' "$BEN" -r "$RPC" | awk '{print $1}'; }
fee() { python3 -I -c "import json; r=json.load(open('$1')); assert int(r['status'],16)==1, 'transaction failed'; print(int(r['gasUsed'],16)*int(r['effectiveGasPrice'],16))"; }

B0=$(bal0); B1=$(bal1)
sent=yes
cast send "$BEN" 'executeBatch((address,uint256,bytes)[])' "$CALLS" --auth "$SIMPLE7702" \
  --private-key "$BEN_PK" -r "$RPC" --json > "$STATE/ben-$POOL-batch.json" || sent=no
# The borrowed code stays even when the batch itself fails, so clear it whatever happened.
G2=0
if [ "$(cast code "$BEN" -r "$RPC")" != "0x" ]; then
  cast send "$BEN" --auth 0x0000000000000000000000000000000000000000 \
    --private-key "$BEN_PK" -r "$RPC" --json > "$STATE/ben-$POOL-clear.json"
  G2=$(fee "$STATE/ben-$POOL-clear.json")
fi
[ "$(cast code "$BEN" -r "$RPC")" = "0x" ] || { echo "  Ben's wallet still carries code"; exit 1; }
[ "$sent" = yes ] || { echo "  the batch was refused before sending: nothing funded, nothing spent"; exit 1; }
G1=$(fee "$STATE/ben-$POOL-batch.json")
A0=$(bal0); A1=$(bal1)

printf 'BEN_BEFORE_0=%s\nBEN_BEFORE_1=%s\nBEN_AFTER_0=%s\nBEN_AFTER_1=%s\nBEN_GAS_WEI=%s\n' \
  "$B0" "$B1" "$A0" "$A1" "$((G1 + G2))" > "$STATE/ben-$POOL.env"
echo "  funded in one transaction (gas $G1 + $G2 wei), delegation cleared: Ben's wallet is plain again"
