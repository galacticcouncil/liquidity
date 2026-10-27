#!/usr/bin/env bash
# The launch rehearsed on Robinhood testnet, in the order the real day runs, with a hostile wallet:
# stand-ins for what testnet lacks, the deployer's three hooks, the attacker creating ETH/HDX first, the
# deployer setting up each pool and offering its hook to the owner, the attacker hitting the empty pools,
# the owner accepting and funding
# each in one 7702 transaction, then the check per pool.
#
#   script/testnet/rehearse.sh all       # every step, in order
#   script/testnet/rehearse.sh <step>    # one step: preflight standins hooks first setup attack owner check
#
# Wallets and keys: .env.testnet (DEPLOYER, OWNER, ATTACKER and their _PK). RPC defaults to robinhood_testnet;
# RPC=http://127.0.0.1:8545 runs it against a local fork. Addresses and logs: broadcast/testnet/<chain id>/.
# The check reads the feeds, which count as stale 2 h after their last push: run it within 2 h of owner.
set -euo pipefail
cd "$(dirname "$0")/../.."
set -a; source .env.testnet; set +a
# addresses as cast prints them, so they compare equal to what the chain returns
DEPLOYER=$(cast to-check-sum-address "$DEPLOYER"); OWNER=$(cast to-check-sum-address "$OWNER")
ATTACKER=$(cast to-check-sum-address "$ATTACKER")

RPC=${RPC:-robinhood_testnet}
CHAIN=$(cast chain-id -r "$RPC")
case $CHAIN in
46630 | 31337) ;;
*) echo "refusing chain $CHAIN: this runs only on Robinhood testnet (46630) or a local fork (31337)"; exit 1 ;;
esac
MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951
POOLS="eth-hollar hdx-hollar eth-hdx"
STATE=broadcast/testnet/$CHAIN
mkdir -p "$STATE"
export RPC MANAGER STATE

# mainnet sources the stand-ins copy: Chainlink ETH/USD, HDX/USD, Simple7702Account
MAIN_ETH_USD=0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9
MAIN_HDX_USD=0xD1a2198CBbC7cbfB602DF581D8614eD31682901D
MAIN_SIMPLE7702=0x4Cd241E8d1510e30b2076397afc7508Ae59C66c9

answer() { cast call "$1" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' -r robinhood | sed -n 2p | awk '{print $1}'; }
upper() { echo "$1" | tr 'a-z-' 'A-Z_'; }
has() { grep -q "^$2=" "$STATE/$1.env" 2>/dev/null; }

# Everything deployed so far, then (optionally) one pool's settings and its pool id.
load() {
  set -a
  for f in ticks standins hooks people; do
    if [ -f "$STATE/$f.env" ]; then source "$STATE/$f.env"; fi
  done
  if [ -n "${1:-}" ]; then source "script/testnet/$1.env"; fi
  set +a
  if [ -n "${1:-}" ]; then
    POOL_ID=$(cast keccak "$(cast abi-encode 'f(address,address,uint24,int24,address)' \
      "$CURRENCY0" "$CURRENCY1" 8388608 "$TICK_SPACING" "${HOOK:-0x0000000000000000000000000000000000000000}")")
    export POOL_ID
  fi
}

# forge script, one transaction at a time, output to a log. Retries only a fork that would not
# start (a lagging public RPC node), which fails before anything is sent.
forge_run() {
  local log=$STATE/$1.log try; shift
  for try in 1 2 3; do
    forge script "$@" --rpc-url "$RPC" --broadcast --slow > "$log" 2>&1 && return 0
    grep -q "could not instantiate forked environment" "$log" || break
    sleep 5
  done
  tail -30 "$log"; exit 1
}

# forge create, printing only the new address; fails when nothing was deployed. Callers assign
# its output first (addr=$(create ...)), so set -e stops the run instead of saving an empty address.
create() {
  local pk=$1 addr; shift
  addr=$(forge create "$@" --rpc-url "$RPC" --private-key "$pk" --broadcast --constructor-args "$MANAGER" \
    | awk '/Deployed to:/ {print $3}')
  [ -n "$addr" ] || { echo "  forge create $1 failed" >&2; return 1; }
  echo "$addr"
}

preflight() {
  echo "== preflight: wallets hold testnet ETH"
  for who in DEPLOYER:2000000000000000 OWNER:6000000000000000 ATTACKER:1000000000000000; do
    name=${who%%:*}; need=${who#*:}; addr=$(eval echo "\$$name")
    bal=$(cast balance "$addr" -r "$RPC")
    echo "  $name $addr $(cast from-wei "$bal") ETH"
    python3 -I -c "import sys; sys.exit($bal < $need)" || { echo "  $name needs at least $(cast from-wei "$need") ETH"; exit 1; }
  done
}

standins() {
  echo "== stand-ins: HDX, HOLLAR, ETH/USD and HDX/USD feeds at today's mainnet prices, Simple7702Account"
  if [ -f "$STATE/standins.env" ]; then echo "  already deployed"; return; fi
  local eth hdx
  eth=$(answer $MAIN_ETH_USD); hdx=$(answer $MAIN_HDX_USD)
  # the ticks the market implies, worked out apart from the sources (raw token1 per raw token0)
  python3 -I -c "
import math
e, h, t = $eth / 1e8, $hdx / 1e8, lambda p: round(math.log(p) / math.log(1.0001))
print(f'EXPECTED_TICK_ETH_HOLLAR={t(e)}')
print(f'EXPECTED_TICK_HDX_HOLLAR={t(h * 1e18 / 1e12)}')
print(f'EXPECTED_TICK_ETH_HDX={t(e / h * 1e12 / 1e18)}')" > "$STATE/ticks.env"
  PRIVATE_KEY=$DEPLOYER_PK ETH_USD_ANSWER=$eth HDX_USD_ANSWER=$hdx \
    SIMPLE7702_CODE=$(cast code $MAIN_SIMPLE7702 -r robinhood) \
    forge_run standins script/testnet/DeployStandIns.s.sol
  sed 's/^/  /' "$STATE/standins.env" "$STATE/ticks.env"
}

hooks() {
  echo "== deployer: 00 deploys one hook per pool"
  for p in $POOLS; do
    name=HOOK_$(upper $p)
    if has hooks "$name"; then echo "  $name exists"; continue; fi
    PRIVATE_KEY=$DEPLOYER_PK forge_run "00-$p" script/00_DeployBandHook.s.sol
    addr=$(awk '/BandHook deployed:/ {print $3}' "$STATE/00-$p.log")
    [ -n "$addr" ] || { echo "  no hook address in $STATE/00-$p.log"; exit 1; }
    echo "$name=$addr" >> "$STATE/hooks.env"
    tail -1 "$STATE/hooks.env" | sed 's/^/  /'
  done
}

first() {
  echo "== attacker: creates ETH/HDX before the deployer sets it up"
  (load eth-hdx; script/testnet/attacker.sh create-first)
}

setup() {
  echo "== deployer: 01 sets up each pool, 03 offers its hook to the owner"
  for p in $POOLS; do (
    load "$p"
    PRIVATE_KEY=$DEPLOYER_PK forge_run "01-$p" script/01_SetupPool.s.sol
    PRIVATE_KEY=$DEPLOYER_PK NEW_OWNER=$OWNER forge_run "03-$p" script/03_HandOff.s.sol
    echo "  $p: $(grep -E 'initialized|OFF THE ORACLE' "$STATE/01-$p.log" | sed 's/^ *//' | paste -sd ';' -)"
    echo "  $p: pending owner $(cast call "$HOOK" 'pendingOwner()(address)' -r "$RPC")"
  ); done
}

attack() {
  echo "== attacker: attacks the empty pools"
  if ! has people ATTACKER_ANCHOR; then
    anchor=$(create "$ATTACKER_PK" script/PoolAnchor.sol:PoolAnchor)
    router=$(create "$ATTACKER_PK" lib/v4-core/src/test/PoolModifyLiquidityTest.sol:PoolModifyLiquidityTest)
    printf 'ATTACKER_ANCHOR=%s\nATTACKER_ROUTER=%s\n' "$anchor" "$router" >> "$STATE/people.env"
  fi
  echo " ETH/HOLLAR: moves the price"
  (load eth-hollar; script/testnet/attacker.sh move 2000)
  echo " HDX/HOLLAR: moves the price, then adds liquidity in the anchor's path"
  (load hdx-hollar; script/testnet/attacker.sh move 2000; script/testnet/attacker.sh add-liquidity)
  for p in $POOLS; do
    echo " $p: owner-only calls"
    (load "$p"; script/testnet/attacker.sh owner-calls)
  done
}

owner() {
  echo "== the feeds update, as Chainlink and the HDX relay would: today's mainnet prices"
  load
  cast send "$ETH_USD_FEED" 'push(int256)' "$(answer $MAIN_ETH_USD)" --private-key "$DEPLOYER_PK" -r "$RPC" > /dev/null
  cast send "$HDX_USD_FEED" 'push(int256)' "$(answer $MAIN_HDX_USD)" --private-key "$DEPLOYER_PK" -r "$RPC" > /dev/null
  echo "== owner: accepts each hook, then funds each pool in one transaction"
  for p in $POOLS; do (
    load "$p"
    if [ "$(cast call "$HOOK" 'owner()(address)' -r "$RPC")" != "$OWNER" ]; then
      cast send "$HOOK" 'acceptOwnership()' --private-key "$OWNER_PK" -r "$RPC" > /dev/null
    fi
    echo "  $p: owner $(cast call "$HOOK" 'owner()(address)' -r "$RPC")"
  ); done
  if ! has people OWNER_ANCHOR; then
    anchor=$(create "$OWNER_PK" script/PoolAnchor.sol:PoolAnchor)
    echo "OWNER_ANCHOR=$anchor" >> "$STATE/people.env"
  fi
  for p in $POOLS; do
    echo " $p"
    (load "$p"; script/testnet/owner_fund.sh "$p")
  done
}

check() {
  echo "== check: each pool on the oracle, the owner's liquidity placed, the owner lost nothing but gas"
  for p in $POOLS; do (
    load "$p"
    set -a; source "$STATE/owner-$p.env"; set +a
    forge script script/testnet/Check.s.sol --rpc-url "$RPC" > "$STATE/check-$p.log" 2>&1 \
      || { tail -30 "$STATE/check-$p.log"; exit 1; }
    echo " $p"
    sed -n '/== Logs ==/,$p' "$STATE/check-$p.log" | sed '1d;/^$/d'
  ); done
}

case "${1:-}" in
all) preflight; standins; hooks; first; setup; attack; owner; check ;;
preflight | standins | hooks | first | setup | attack | owner | check) "$1" ;;
*) sed -n 2,11p "$0"; exit 1 ;;
esac
