// Plain words for what can refuse a transaction: the hook, the anchor, a token, the wallet or the Ledger.
// The hook's meanings follow the README's operator notes.
import { BaseError, decodeErrorResult, UserRejectedRequestError, type Hex } from 'viem'
import { errorsAbi } from '../abi'

const MEANINGS: Record<string, string> = {
  NotOwner: 'only the hook owner can do this (for accept: only the wallet it was offered to). Connect that wallet.',
  NotEnabled: 'the pool is switched off on the hook, or not set up on it.',
  StaleOracle: 'the price feed is stale, so nothing moves. Wait for its next update, or replace the source.',
  DriftBelowTrigger: 'not due: the oracle has not moved far enough from the band\'s center.',
  GuardTripped: 'the pool price is further than the guard from the oracle. On an empty pool, put the price back ' +
    'first (Fund does this); on a funded pool, wait for arbitrage.',
  EmptyBand: 'nothing to place: the hook holds no tokens for this pool.',
  BadValue: 'the ETH sent does not match the ETH amount.',
  BadConfig: 'the hook refused these settings: see the limits in src/BandHook.sol _validate.',
  SourceTickMismatch: 'the new source reports a tick too far from the one you expected.',
  AlreadyConfigured: 'the pool is already set up on this hook.',
  NativeTransferFailed: 'the hook could not send ETH to its owner (a contract owner must accept plain ETH).',
  TransferFailed: 'a token transfer failed: check the balance and the approval.',
  TargetNotReached: 'others\' liquidity sits between the pool price and the oracle, and crossing it costs more ' +
    'than the anchor\'s limits. Raise them under "Anchor limits"; that trade is at a better price than the oracle.',
}

/** The name of the contract error a refusal carries, or its reason string; undefined when it has neither. */
export function revertName(err: unknown): string | undefined {
  if (!(err instanceof BaseError)) return undefined
  // the node's answer sits at the bottom of viem's error chain, as viem's own getRevertErrorData reads it
  const deepest = err.walk() as { data?: Hex | { data?: Hex } }
  const data = typeof deepest.data === 'object' ? deepest.data?.data : deepest.data
  if (!data || data.length < 10) return undefined
  try {
    const decoded = decodeErrorResult({ abi: errorsAbi, data })
    return decoded.errorName === 'Error' ? String(decoded.args?.[0]) : decoded.errorName
  } catch {
    return undefined
  }
}

/** One sentence saying why it failed and what to do. */
export function explain(err: unknown): string {
  if (err instanceof BaseError && err.walk((e) => e instanceof UserRejectedRequestError)) {
    return 'Declined in the wallet: nothing was sent.'
  }
  const name = revertName(err)
  if (name) return MEANINGS[name] ? `${name}: ${MEANINGS[name]}` : `Refused: ${name}`
  const message = err instanceof BaseError ? err.shortMessage : err instanceof Error ? err.message : String(err)
  if (/ledger|blind|0x6a80|0x6985/i.test(message)) {
    return `${message} On the Ledger: unlock it, open the Ethereum app, and turn on Blind signing in its settings.`
  }
  return message
}
