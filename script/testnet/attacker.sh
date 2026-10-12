#!/usr/bin/env bash
# The attacker, the hostile wallet of the testnet rehearsal: what it tries against a pool before the owner funds it.
# Each command acts on the pool whose settings rehearse.sh has exported.
#
#   attacker.sh create-first    initialize the pool 30,000 ticks (~20x) off the market, before the deployer's 01
#   attacker.sh move <ticks>    move the empty pool's price <ticks> above the oracle; costs only gas
#   attacker.sh add-liquidity   put its own liquidity just above the oracle, in the path the owner's anchor must cross
#   attacker.sh owner-calls     try every owner-only call on the hook; each must revert with NotOwner
#
# env: RPC, MANAGER, ATTACKER, ATTACKER_PK, DEPLOYER, OWNER, POOL_ID, the pool's settings;
#      move and add-liquidity also ATTACKER_ANCHOR (its PoolAnchor) and ATTACKER_ROUTER (v4-core's liquidity router)
set -euo pipefail

KEY="($CURRENCY0,$CURRENCY1,8388608,$TICK_SPACING,$HOOK)"
CONFIG_SIG='config(bytes32)(address,uint24,uint24,uint32,uint32,int24,int24,uint16,int24,int24,bool,bool)'
MAX=$(cast max-uint)

send() { cast send "$@" --private-key "$ATTACKER_PK" -r "$RPC" > /dev/null; }
sqrt_at() { python3 -I -c "import math; print(int(math.sqrt(1.0001 ** $1) * 2**96))"; }
oracle_tick() {
  local src px
  src=$(cast call "$HOOK" "$CONFIG_SIG" "$POOL_ID" -r "$RPC" | head -1)
  px=$(cast call "$src" 'priceX18()(uint256,uint256)' -r "$RPC" | head -1 | awk '{print $1}')
  python3 -I -c "import math; print(math.floor(math.log($px / 1e18) / math.log(1.0001)))"
}
pool_tick() { cast call "$MANAGER" 'extsload(bytes32)(bytes32)' "$(slot0_slot)" -r "$RPC" | python3 -I -c "
import sys; w=int(sys.stdin.read().strip(),16); t=(w>>160)&0xffffff; print(t-(1<<24) if t>=1<<23 else t)"; }
# StateLibrary: pools mapping at slot 6; slot0 is the first word of the pool's state
slot0_slot() { cast keccak "$(cast abi-encode 'f(bytes32,uint256)' "$POOL_ID" 6)"; }

case "${1:-}" in
create-first)
  # The deployer's hook exists, so the pool id is known; nothing stops anyone initializing it first.
  tick=$((EXPECTED_TICK + 30000))
  send "$MANAGER" 'initialize((address,address,uint24,int24,address),uint160)(int24)' "$KEY" "$(sqrt_at $tick)"
  echo "  the attacker initialized the pool at tick $(pool_tick) (market ~$EXPECTED_TICK)"
  ;;
move)
  # The price rises, so its anchor sells token1 (never native). On an empty pool nothing trades.
  target=$(( $(oracle_tick) + $2 ))
  send "$CURRENCY1" 'approve(address,uint256)' "$ATTACKER_ANCHOR" 1
  send "$ATTACKER_ANCHOR" 'anchor((address,address,uint24,int24,address),uint160,uint256,uint256)' "$KEY" "$(sqrt_at $target)" 0 1
  echo "  the attacker moved the pool to tick $(pool_tick) (oracle $(oracle_tick))"
  ;;
add-liquidity)
  # Two tick-spacings just above the oracle, below the moved price: all token1. Sized so crossing it
  # takes about 50 HDX of the owner's anchor, under its 100 HDX cap, while the anchor pays the fee cap to it.
  o=$(oracle_tick)
  lower=$(( (o / TICK_SPACING + 1) * TICK_SPACING ))
  upper=$(( lower + 2 * TICK_SPACING ))
  liq=$(python3 -I -c "print(int(50e12 / (1.0001 ** (-$lower / 2) - 1.0001 ** (-$upper / 2))))")
  send "$CURRENCY1" 'approve(address,uint256)' "$ATTACKER_ROUTER" "$MAX"
  send "$ATTACKER_ROUTER" 'modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)' \
    "$KEY" "($lower,$upper,$liq,0x0000000000000000000000000000000000000000000000000000000000000000)" 0x
  echo "  the attacker placed liquidity $liq in ticks [$lower, $upper] (oracle $o, pool $(pool_tick))"
  ;;
owner-calls)
  CFG="(0x0000000000000000000000000000000000000000,0,0,0,0,0,0,0,0,0,false,false)"
  calls=(
    "acceptOwnership()"
    "transferOwnership(address) $ATTACKER"
    "configure((address,address,uint24,int24,address),(address,uint24,uint24,uint32,uint32,int24,int24,uint16,int24,int24,bool,bool)) $KEY $CFG"
    "setParams(bytes32,(address,uint24,uint24,uint32,uint32,int24,int24,uint16,int24,int24,bool,bool)) $POOL_ID $CFG"
    "setSource(bytes32,address,int24,int24) $POOL_ID $ATTACKER 0 0"
    "setAutoRecenter(bytes32,bool) $POOL_ID true"
    "setEnabled(bytes32,bool) $POOL_ID false"
    "fund(bytes32,uint256,uint256) $POOL_ID 0 0"
    "withdraw(bytes32) $POOL_ID"
    "sweep(address,address,uint256) 0x0000000000000000000000000000000000000000 $ATTACKER 0"
  )
  for c in "${calls[@]}"; do
    read -r -a args <<< "$c"
    # the simulation must name NotOwner (0x30cd7471); then the call is sent anyway and must fail on chain
    out=$(cast call "$HOOK" "${args[@]}" --from "$ATTACKER" -r "$RPC" 2>&1 || true)
    echo "$out" | grep -qE "30cd7471|NotOwner" || { echo "  FAIL ${args[0]}: $out"; exit 1; }
    status=$(cast send "$HOOK" "${args[@]}" --gas-limit 300000 --private-key "$ATTACKER_PK" -r "$RPC" --json | python3 -I -c "import json,sys; print(int(json.load(sys.stdin)['status'],16))")
    [ "$status" = 0 ] || { echo "  FAIL ${args[0]} succeeded on chain"; exit 1; }
    echo "  NotOwner, reverted on chain: ${args[0]}"
  done
  owner=$(cast call "$HOOK" 'owner()(address)' -r "$RPC")
  pending=$(cast call "$HOOK" 'pendingOwner()(address)' -r "$RPC")
  [ "$owner" = "$DEPLOYER" ] && [ "$pending" = "$OWNER" ] || { echo "  FAIL owner $owner pending $pending"; exit 1; }
  echo "  hook unchanged: owner the deployer, pending the owner"
  ;;
*)
  sed -n 2,12p "$0"; exit 1 ;;
esac
