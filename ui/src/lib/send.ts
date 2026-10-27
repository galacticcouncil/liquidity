// Sends one transaction from the connected wallet: a dry run first, so a refusal shows in plain words
// before the Ledger asks anything, then the transaction, then its receipt from the chain.
import type { Address, Hash, PublicClient, TransactionReceipt, WalletClient } from 'viem'
import { robinhood } from '../config'
import type { Tx } from './fundPlan'

export type Stage = { kind: 'checking' } | { kind: 'signing' } | { kind: 'pending'; hash: Hash }

/** Dry run, send, wait. Throws the refusal if the dry run or the chain refuses; returns the receipt. */
export async function runTx(
  client: PublicClient,
  wallet: WalletClient,
  from: Address,
  tx: Tx,
  onStage: (stage: Stage) => void = () => {},
): Promise<TransactionReceipt> {
  onStage({ kind: 'checking' })
  await client.call({ account: from, to: tx.to, data: tx.data, value: tx.value })
  onStage({ kind: 'signing' })
  const hash = await wallet.sendTransaction({ account: from, chain: robinhood, to: tx.to, data: tx.data, value: tx.value })
  onStage({ kind: 'pending', hash })
  // no timeout: a deposit that lands late must never look failed, or the owner sends it twice
  const receipt = await client.waitForTransactionReceipt({ hash, timeout: 0 })
  if (receipt.status !== 'success') {
    throw new Error('It reverted on chain: nothing changed, only gas was spent. The state is read again; try again.')
  }
  return receipt
}
