#!/usr/bin/env bash
# The ETH/HOLLAR launch rehearsed on a local fork of Robinhood Chain, with the exact commands of the real
# day: the deployer's 00, 01 and 03 from a copy of script/mainnet/eth-hollar.env, an attacker moving the
# empty pool, then the owner's fund.sh check and send. Throwaway keys; nothing reaches the live chain.
#
#   script/mainnet/rehearse-fork.sh [ETH to deposit, default 5]
#
# Needs anvil, cast, forge and python3. Output and logs: broadcast/fork-rehearsal/.
set -euo pipefail
cd "$(dirname "$0")/../.."
FUND_ETH=${1:-5}
PORT=${PORT:-8547}
RPC=http://127.0.0.1:$PORT
DIR=broadcast/fork-rehearsal
FILE=$DIR/eth-hollar.env
rm -rf "$DIR"
mkdir -p "$DIR"

# a separate chain id keeps forge's records apart from the real chain's
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 31337 --hardfork prague --port "$PORT" \
  > "$DIR/anvil.log" 2>&1 &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true' EXIT
for _ in $(seq 60); do cast chain-id --rpc-url "$RPC" > /dev/null 2>&1 && break; sleep 1; done

# throwaway keys nobody else uses: well-known test keys carry sweeper code on live chains
key() { cast keccak "eth-hollar fork rehearsal $1"; }
DEPLOYER_PK=$(key deployer); OWNER_PK=$(key owner); ATTACKER_PK=$(key attacker)
OWNER=$(cast wallet address --private-key "$OWNER_PK")
ATTACKER=$(cast wallet address --private-key "$ATTACKER_PK")
for pk in "$DEPLOYER_PK" "$OWNER_PK" "$ATTACKER_PK"; do
  cast rpc anvil_setBalance "$(cast wallet address --private-key "$pk")" 0x56BC75E2D63100000 --rpc-url "$RPC" > /dev/null # 100 ETH
done

setting() { sed "s|^$1=.*|$1=$2|" "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"; }
load() { set -a; source "$FILE"; set +a; }
cp script/mainnet/eth-hollar.env "$FILE"
setting CHAIN_ID 31337
setting RPC "$RPC"
setting NEW_OWNER "$OWNER"
setting FUND_ETH "$FUND_ETH"
load

echo "== the owner's wallet holds HOLLAR, minted as the bridge mints it"
MINTER=$(cast call "$CURRENCY1" 'minter()(address)' --rpc-url "$RPC")
cast rpc anvil_impersonateAccount "$MINTER" --rpc-url "$RPC" > /dev/null
cast rpc anvil_setBalance "$MINTER" 0x56BC75E2D63100000 --rpc-url "$RPC" > /dev/null
cast send "$CURRENCY1" 'mint(address,uint256)' "$OWNER" 50000000000000000000000 \
  --from "$MINTER" --unlocked --rpc-url "$RPC" > /dev/null
echo "  $OWNER: 50,000 HOLLAR, 100 ETH"

echo "== deployer: the tick the market implies, worked out apart from the scripts"
ANSWER=$(cast call "$FEED" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$RPC" | sed -n 2p | awk '{print $1}')
setting EXPECTED_TICK "$(python3 -I -c "import math; print(round(math.log($ANSWER / 1e8) / math.log(1.0001)))")"
load
echo "  ETH/USD $ANSWER (8 dec) -> EXPECTED_TICK $EXPECTED_TICK"

deployer() {
  local log=$DIR/$1.log
  PRIVATE_KEY=$DEPLOYER_PK forge script "script/$1.s.sol" --rpc-url "$RPC" --broadcast --slow > "$log" 2>&1 \
    || { tail -20 "$log"; exit 1; }
}
echo "== deployer: 00 deploys the hook"
deployer 00_DeployBandHook
setting HOOK "$(awk '/BandHook deployed:/ {print $3}' "$DIR/00_DeployBandHook.log")"
load
echo "  HOOK $HOOK"
echo "== deployer: 01 sets up the pool, 03 offers the hook to the owner"
deployer 01_SetupPool
grep -E "initialized|OFF THE ORACLE" "$DIR/01_SetupPool.log" | sed 's/^ */  /'
deployer 03_HandOff
echo "  pending owner $(cast call "$HOOK" 'pendingOwner()(address)' --rpc-url "$RPC")"

echo "== attacker: moves the empty pool 2,000 ticks up, for free"
ATTACKER_ANCHOR=$(forge create script/PoolAnchor.sol:PoolAnchor --rpc-url "$RPC" --private-key "$ATTACKER_PK" \
  --broadcast --constructor-args 0x8366a39CC670B4001A1121B8F6A443A643e40951 | awk '/Deployed to:/ {print $3}')
TARGET=$(python3 -I -c "import math; print(int(math.sqrt(1.0001 ** ($EXPECTED_TICK + 2000)) * 2**96))")
cast send "$ATTACKER_ANCHOR" 'anchor((address,address,uint24,int24,address),uint160,uint256,uint256)' \
  "($CURRENCY0,$CURRENCY1,8388608,$TICK_SPACING,$HOOK)" "$TARGET" 0 1 \
  --private-key "$ATTACKER_PK" --rpc-url "$RPC" > /dev/null
POOL_ID=$(cast keccak "$(cast abi-encode 'f(address,address,uint24,int24,address)' "$CURRENCY0" "$CURRENCY1" 8388608 "$TICK_SPACING" "$HOOK")")
# the pool's tick from its slot0 (StateLibrary: the pools mapping sits at slot 6)
pool_tick() {
  cast call 0x8366a39CC670B4001A1121B8F6A443A643e40951 'extsload(bytes32)(bytes32)' \
    "$(cast keccak "$(cast abi-encode 'f(bytes32,uint256)' "$POOL_ID" 6)")" --rpc-url "$RPC" \
    | python3 -I -c "import sys; t = (int(sys.stdin.read().strip(), 16) >> 160) & 0xffffff; print(t - (1 << 24) if t >= 1 << 23 else t)"
}
echo "  pool tick $(pool_tick) (oracle $EXPECTED_TICK)"

echo "== owner: script/fund.sh check, then send"
HOLLAR_BEFORE=$(cast call "$CURRENCY1" 'balanceOf(address)(uint256)' "$OWNER" --rpc-url "$RPC" | awk '{print $1}')
PRIVATE_KEY=$OWNER_PK script/fund.sh check "$FILE"
PRIVATE_KEY=$OWNER_PK script/fund.sh send "$FILE"
HOLLAR_AFTER=$(cast call "$CURRENCY1" 'balanceOf(address)(uint256)' "$OWNER" --rpc-url "$RPC" | awk '{print $1}')
echo "== rehearsal passed: pool tick $(pool_tick); the owner deposited $FUND_ETH ETH and $(cast from-wei "$(python3 -I -c "print($HOLLAR_BEFORE - $HOLLAR_AFTER)")") HOLLAR"
