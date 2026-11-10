// Every chain call the keeper makes: ask the hook whether a recenter would go through, read the two
// prices a recenter depends on, and send the recenter. The hook decides what is due; nothing here copies its rules.
import {
  BaseError, ContractFunctionRevertedError, encodeAbiParameters, keccak256, parseAbi,
  type Account, type Chain, type Hex, type PublicClient, type Transport, type WalletClient,
} from 'viem'
import type { PoolRef } from './config.js'

export const hookAbi = parseAbi([
  'function recenter(bytes32 id)',
  'function manager() view returns (address)',
  'function config(bytes32 id) view returns (address source, uint24 feeFloor, uint24 feeCap, uint32 feeSlopePpm, uint32 staleAfter, int24 halfBandTicks, int24 backstopHalfTicks, uint16 backstopBps, int24 triggerTicks, int24 guardTicks, bool enabled, bool autoRecenter)',
  'event Recentered(bytes32 indexed id, int24 oracleTick, int24 lower, int24 upper, uint128 liquidity)',
  'error NotEnabled()',
  'error StaleOracle()',
  'error DriftBelowTrigger()',
  'error GuardTripped()',
  'error EmptyBand()',
  'error Unsettled()',
])
const sourceAbi = parseAbi(['function priceX18() view returns (uint256 priceX18, uint256 updatedAt)'])
const managerAbi = parseAbi(['function extsload(bytes32 slot) view returns (bytes32)'])
const POOLS_SLOT = 6n // where the PoolManager keeps its pools, as StateLibrary reads it

export type Signer = WalletClient<Transport, Chain, Account>

/** The two inputs a recenter places around; while both stay the same, another recenter places the same bands. */
export type Prices = { oraclePriceX18: bigint; sqrtPriceX96: bigint }

/** Undefined when the hook would accept a recenter now, otherwise the name of the error it refuses with. */
export async function refusal(client: PublicClient, signer: Signer, pool: PoolRef): Promise<string | undefined> {
  try {
    await client.simulateContract({
      address: pool.hook, abi: hookAbi, functionName: 'recenter', args: [pool.poolId], account: signer.account,
    })
    return undefined
  } catch (err) {
    const reverted = err instanceof BaseError ? err.walk((e) => e instanceof ContractFunctionRevertedError) : null
    // viem also reports a node's internal error (-32603) as a revert, but with no error data to decode
    if (reverted instanceof ContractFunctionRevertedError && (reverted.data || reverted.signature)) {
      if (reverted.data?.errorName === 'Error') return reverted.reason ?? 'Error' // a require message
      return reverted.data?.errorName ?? reverted.signature ?? 'reverted'
    }
    throw err // not the hook saying no: the node or the network failed
  }
}

export async function readPrices(client: PublicClient, pool: PoolRef): Promise<Prices> {
  const hook = { address: pool.hook, abi: hookAbi } as const
  const [manager, cfg] = await Promise.all([
    client.readContract({ ...hook, functionName: 'manager' }),
    client.readContract({ ...hook, functionName: 'config', args: [pool.poolId] }),
  ])
  const slot = keccak256(encodeAbiParameters([{ type: 'bytes32' }, { type: 'uint256' }], [pool.poolId, POOLS_SLOT]))
  const [[oraclePriceX18], slot0] = await Promise.all([
    client.readContract({ address: cfg[0], abi: sourceAbi, functionName: 'priceX18' }),
    client.readContract({ address: manager, abi: managerAbi, functionName: 'extsload', args: [slot] }),
  ])
  return { oraclePriceX18, sqrtPriceX96: BigInt(slot0) & ((1n << 160n) - 1n) } // slot0's low 160 bits
}

export async function sendRecenter(client: PublicClient, signer: Signer, pool: PoolRef) {
  const hash: Hex = await signer.writeContract({
    address: pool.hook, abi: hookAbi, functionName: 'recenter', args: [pool.poolId],
  })
  const receipt = await client.waitForTransactionReceipt({ hash, timeout: 120_000 })
  return { hash, ok: receipt.status === 'success', gasUsed: receipt.gasUsed }
}
