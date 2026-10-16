// One transaction behind one button: a dry run, then MetaMask and the Ledger ask to confirm, then the
// receipt. Each stage shows in plain words, with the transaction linked on the explorer.
import { useState } from 'react'
import type { PublicClient, TransactionReceipt } from 'viem'
import { robinhood } from '../config'
import { explain } from '../lib/errors'
import type { Tx } from '../lib/fundPlan'
import { runTx, type Stage } from '../lib/send'
import type { Connected } from '../lib/wallet'
import { Link } from './ui'

export type TxContext = { client: PublicClient; wallet: Connected | null; refresh: () => void }

type Status = Stage | { kind: 'idle' } | { kind: 'confirming' } | { kind: 'done'; hash: string } | { kind: 'failed'; message: string }

type Props = {
  label: string
  tx?: Tx
  ctx: TxContext
  confirm?: string // asked first, for actions that are hard to undo
  tone?: 'primary' | 'pink' | 'danger' | 'quiet'
  onStart?: () => void
  onDone?: (receipt: TransactionReceipt) => void
  onFail?: (message: string) => void
}

export function TxButton({ label, tx, ctx, confirm, tone = 'primary', onStart, onDone, onFail }: Props) {
  const [status, setStatus] = useState<Status>({ kind: 'idle' })
  const { wallet } = ctx
  const wrongChain = wallet !== null && wallet.chainId !== robinhood.id
  const busy = status.kind === 'checking' || status.kind === 'signing' || status.kind === 'pending'

  async function send() {
    if (!wallet || !tx) return
    onStart?.()
    try {
      const receipt = await runTx(ctx.client, wallet.client, wallet.address, tx, setStatus)
      setStatus({ kind: 'done', hash: receipt.transactionHash })
      onDone?.(receipt)
    } catch (err) {
      const message = explain(err)
      setStatus({ kind: 'failed', message })
      onFail?.(message)
    }
    ctx.refresh()
  }

  if (status.kind === 'confirming') {
    return (
      <div className="tx">
        <p className="tx-confirm">{confirm}</p>
        <div className="row">
          <button className="btn danger" onClick={send}>Yes, send it</button>
          <button className="btn quiet" onClick={() => setStatus({ kind: 'idle' })}>Cancel</button>
        </div>
      </div>
    )
  }
  return (
    <div className="tx">
      <button
        className={`btn ${tone}`}
        disabled={!wallet || !tx || wrongChain || busy}
        onClick={() => (confirm ? setStatus({ kind: 'confirming' }) : send())}
      >
        {busy && <span className="spinner" />}
        {label}
      </button>
      <StatusLine status={status} wrongChain={wrongChain} />
    </div>
  )
}

function StatusLine({ status, wrongChain }: { status: Status; wrongChain: boolean }) {
  if (wrongChain) return <p className="tx-line warn">Switch the wallet to Robinhood Chain first (top right).</p>
  switch (status.kind) {
    case 'checking':
      return <p className="tx-line">Checking it would go through…</p>
    case 'signing':
      return <p className="tx-line">Confirm in MetaMask, then on your Ledger.</p>
    case 'pending':
      return <p className="tx-line">Sent, waiting for the chain… <Link address={status.hash} kind="tx" /></p>
    case 'done':
      return <p className="tx-line good">Done. <Link address={status.hash} kind="tx" /></p>
    case 'failed':
      return <p className="tx-line bad">{status.message}</p>
    default:
      return null
  }
}
