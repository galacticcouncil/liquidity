// The contract functions and errors the console uses, written as Solidity signatures.
// They mirror src/BandHook.sol and script/PoolAnchor.sol; only what the console calls is listed.
import { parseAbi } from 'viem'

export const bandHookAbi = parseAbi([
  'struct PoolConfig { address source; uint24 feeFloor; uint24 feeCap; uint32 feeSlopePpm; uint32 staleAfter; int24 halfBandTicks; int24 backstopHalfTicks; uint16 backstopBps; int24 triggerTicks; int24 guardTicks; bool enabled; bool autoRecenter; }',
  'function owner() view returns (address)',
  'function pendingOwner() view returns (address)',
  'function config(bytes32 id) view returns (address source, uint24 feeFloor, uint24 feeCap, uint32 feeSlopePpm, uint32 staleAfter, int24 halfBandTicks, int24 backstopHalfTicks, uint16 backstopBps, int24 triggerTicks, int24 guardTicks, bool enabled, bool autoRecenter)',
  'function core(bytes32 id) view returns (int24 lower, int24 upper, int24 center, uint128 liquidity)',
  'function backstop(bytes32 id) view returns (int24 lower, int24 upper, int24 center, uint128 liquidity)',
  'function limit(bytes32 id) view returns (int24 lower, int24 upper, int24 center, uint128 liquidity)',
  'function transferOwnership(address to)',
  'function acceptOwnership()',
  'function fund(bytes32 id, uint256 amount0, uint256 amount1) payable',
  'function recenter(bytes32 id)',
  'function withdraw(bytes32 id)',
  'function sweep(address currency, address to, uint256 amount)',
  'function setEnabled(bytes32 id, bool on)',
  'function setAutoRecenter(bytes32 id, bool on)',
  'function setParams(bytes32 id, PoolConfig cfg)',
  'function setSource(bytes32 id, address newSource, int24 expectedTick, int24 tolerance)',
  'function syncFee(bytes32 id)',
  'error NotOwner()',
  'error NotManager()',
  'error NotEnabled()',
  'error AlreadyConfigured()',
  'error StaleOracle()',
  'error DriftBelowTrigger()',
  'error GuardTripped()',
  'error BadConfig()',
  'error BadValue()',
  'error NativeTransferFailed()',
  'error TransferFailed()',
  'error SourceTickMismatch(int24 expected, int24 actual)',
  'error EmptyBand()',
  'error NotSelf()',
  'error Unsettled()',
])

export const poolAnchorAbi = parseAbi([
  'constructor(address manager)',
  'struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }',
  'function anchor(PoolKey key, uint160 target, uint256 max0, uint256 max1) payable',
  'error TargetNotReached()',
  'error TransferFailed()',
])

export const erc20Abi = parseAbi([
  'function balanceOf(address who) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
])

export const priceSourceAbi = parseAbi(['function priceX18() view returns (uint256 priceX18, uint256 updatedAt)'])

export const managerAbi = parseAbi(['function extsload(bytes32 slot) view returns (bytes32)'])

/** Every custom error above, and a plain require's reason, for turning a refusal into its name. */
export const errorsAbi = [...bandHookAbi, ...poolAnchorAbi, ...parseAbi(['error Error(string reason)'])].filter(
  (item) => item.type === 'error',
)
