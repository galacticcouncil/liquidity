// The owner's funding, step by step: how much to deposit, what stands in the way, and the transactions still
// to send, worked out again from the chain after each one. What script/fund.sh does, for a wallet on a Ledger.
import { useRef, useState } from 'react'
import { formatUnits, type Address, type TransactionReceipt } from 'viem'
import type { Pool } from '../config'
import { fundingProblems, maxAmount0 } from '../lib/checks'
import { fundingSteps, type Step } from '../lib/fundPlan'
import { formatAmount, parseAmount } from '../lib/format'
import { amount1For } from '../lib/math'
import type { PoolState } from '../lib/poolState'
import { TxButton, type TxContext } from './TxButton'
import { Card, Link, Notice } from './ui'

type Props = { pool: Pool; s: PoolState; ctx: TxContext; anchor?: Address; onAnchor: (anchor: Address) => void }

export function FundPanel({ pool, s, ctx, anchor, onAnchor }: Props) {
  const { token0: t0, token1: t1 } = pool
  const [input, setInput] = useState('')
  const [capText, setCapText] = useState([formatUnits(pool.anchorMax0, t0.decimals), formatUnits(pool.anchorMax1, t1.decimals)])
  const caps = { max0: parseAmount(capText[0], t0.decimals), max1: parseAmount(capText[1], t1.decimals) }
  const amount0 = parseAmount(input, t0.decimals)
  const problems = fundingProblems(pool, s, amount0, caps)
  const steps = problems.length ? [] : fundingSteps(pool, s, amount0, caps, anchor)
  const funded = s.core.liquidity + s.backstop.liquidity + s.limit.liquidity > 0n
  return (
    <div className="grid">
      <Card title="Deposit" wide>
        {funded && <Notice tone="good">The hook already holds liquidity here: a deposit adds to it, around the oracle price.</Notice>}
        <label className="field">
          <span>{t0.symbol} to deposit</span>
          <div className="amount">
            <input inputMode="decimal" placeholder="0.0" value={input} onChange={(e) => setInput(e.target.value)} />
            <button className="btn quiet small" onClick={() => setInput(formatUnits(maxAmount0(pool, s, caps), t0.decimals))}>
              Max
            </button>
          </div>
        </label>
        <p className="lead">
          and {formatAmount(amount1For(amount0, s.oracle.priceX18), t1.decimals)} {t1.symbol}, the same value at the oracle price.
        </p>
        {s.wallet && (
          <p className="muted">
            Wallet holds {formatAmount(s.wallet.balance0, t0.decimals)} {t0.symbol} and {formatAmount(s.wallet.balance1, t1.decimals)} {t1.symbol}.
          </p>
        )}
        {problems.map((p) => <Notice tone="bad" key={p}>{p}</Notice>)}
      </Card>
      <StepList steps={steps} s={s} ctx={ctx} hint={amount0 === 0n ? 'Enter an amount to see them.' : 'None until the points above are fixed.'}
        onAnchor={onAnchor} onFunded={() => setInput('')} />
      <LedgerNotes />
      <AnchorLimits pool={pool} capText={capText} onChange={setCapText} />
    </div>
  )
}

type StepListProps = {
  steps: Step[]; s: PoolState; ctx: TxContext; hint: string; onAnchor: (anchor: Address) => void; onFunded: () => void
}

/** Only the first step gets a button. The list holds still while a step is in flight, and after one lands it waits
 * for a read of the chain taken after it, so a step that has just gone through is never offered again. */
function StepList({ steps, s, ctx, hint, onAnchor, onFunded }: StepListProps) {
  const [held, setHeld] = useState<Step[]>()
  const [landedBefore, setLandedBefore] = useState<PoolState>() // the newest read when the last step landed
  const [log, setLog] = useState<{ title: string; hash: string }[]>([])
  const [failure, setFailure] = useState<string>()
  const [attempts, setAttempts] = useState(0) // a fresh button after each finished attempt; its outcome shows above
  const latest = useRef(s)
  latest.current = s
  const shown = held ?? (landedBefore === s ? [] : steps)

  function failed(step: Step, message: string) {
    setHeld(undefined)
    setAttempts((n) => n + 1)
    setFailure(`${step.title}: ${message}`)
  }

  function done(step: Step, receipt: TransactionReceipt) {
    setLandedBefore(latest.current)
    setHeld(undefined)
    setFailure(undefined)
    setAttempts((n) => n + 1)
    setLog((list) => [...list, { title: step.title, hash: receipt.transactionHash }])
    if (step.key === 'deployAnchor' && receipt.contractAddress) onAnchor(receipt.contractAddress)
    if (step.key === 'fund') onFunded()
  }

  return (
    <Card title="Transactions to send" wide>
      {failure && <Notice tone="bad">{failure}</Notice>}
      {landedBefore === s && !held && <p className="muted">Reading the chain again…</p>}
      {steps.length === 0 && !held && <p className="muted">{hint}</p>}
      <ol className="steps">
        {shown.map((step, i) => (
          <li key={step.key} className={i === 0 ? 'step current' : 'step'}>
            <strong>{step.title}</strong>
            <p>{step.why}</p>
            {i === 0 && (
              <TxButton key={attempts} label={step.key === 'fund' ? 'Deposit' : 'Send'} tx={step.tx} ctx={ctx}
                tone={step.key === 'fund' ? 'pink' : 'primary'} onStart={() => { setHeld(steps); setFailure(undefined) }}
                onDone={(r) => done(step, r)} onFail={(m) => failed(step, m)} />
            )}
          </li>
        ))}
      </ol>
      {log.length > 0 && (
        <div className="sent">
          <span className="stat-label">Sent from this page</span>
          {log.map((t) => <p key={t.hash}>{t.title} · <Link address={t.hash} kind="tx" /></p>)}
        </div>
      )}
    </Card>
  )
}

function AnchorLimits({ pool, capText, onChange }: { pool: Pool; capText: string[]; onChange: (caps: string[]) => void }) {
  return (
    <Card title="Anchor limits">
      <p className="muted">
        The most the anchor may spend if others' liquidity sits between the pool price and the oracle. On an empty pool it
        spends nothing. If it refuses with TargetNotReached, raise them (for example 0.01 ETH and 25 HOLLAR).
      </p>
      {[pool.token0, pool.token1].map((t, i) => (
        <label className="field" key={t.symbol}>
          <span>{t.symbol}</span>
          <input inputMode="decimal" value={capText[i]} onChange={(e) => onChange(capText.map((c, j) => (j === i ? e.target.value : c)))} />
        </label>
      ))}
    </Card>
  )
}

function LedgerNotes() {
  return (
    <Card title="Before you start">
      <ul className="notes">
        <li>In MetaMask, pick the Ledger account the hook was offered to. Close Ledger Live, which holds on to the device.</li>
        <li>On the Ledger: unlock it, open the Ethereum app, and turn on Blind signing in its settings. Contract calls need it.</li>
        <li>Each step is one confirm in MetaMask, then one on the Ledger. A first funding is usually five: accept, approve, deploy the anchor, anchor, deposit.</li>
        <li>
          Why not one transaction like fund.sh: a Ledger in MetaMask cannot sign that kind (EIP-7702), so the anchor goes
          right before the deposit. If someone moves the price past the guard in between, the deposit is refused, only gas is
          lost, and the anchor is offered again. A smaller move can cost a few hundredths of a percent of the deposit.
        </li>
      </ul>
    </Card>
  )
}
