// Every other BandHook call: hand the hook on, switch the pool or its in-swap recenter, recenter, take
// everything out, sweep, and the settings forms. Each is dry-run first, so a refusal shows its reason.
import { useState } from 'react'
import { encodeFunctionData, isAddress, isAddressEqual, zeroAddress, type Address, type Hex } from 'viem'
import { bandHookAbi } from '../abi'
import type { Pool } from '../config'
import { recenterStatus } from '../lib/checks'
import { formatAmount, parseAmount } from '../lib/format'
import type { Tx } from '../lib/fundPlan'
import { positionAmounts } from '../lib/math'
import type { PoolState } from '../lib/poolState'
import { SettingsForms } from './SettingsForms'
import { TxButton, type TxContext } from './TxButton'
import { Card, Notice } from './ui'

type Props = { pool: Pool; s: PoolState; ctx: TxContext }

export function ManagePanel({ pool, s, ctx }: Props) {
  const hook = (data: Hex): Tx => ({ to: pool.hook, data, value: 0n })
  const isOwner = !!s.wallet && isAddressEqual(s.wallet.address, s.owner)
  const recenter = recenterStatus(s)
  return (
    <div className="grid">
      {s.wallet && !isOwner && <Notice tone="warn">This wallet is not the owner: only recenter and fee sync will go through.</Notice>}
      <Ownership pool={pool} s={s} ctx={ctx} />
      <Card title="Switches">
        <p className="muted">Off stops fund and recenter. Swaps keep trading what is placed; to stop that, take everything out.</p>
        <TxButton label={`Switch the pool ${s.cfg.enabled ? 'off' : 'on'}`} ctx={ctx}
          tx={hook(encodeFunctionData({ abi: bandHookAbi, functionName: 'setEnabled', args: [s.id, !s.cfg.enabled] }))} />
        <p className="muted">In-swap recenter: the swap that makes a recenter due also does it, paid by that trader.</p>
        <TxButton label={`Turn in-swap recenter ${s.cfg.autoRecenter ? 'off' : 'on'}`} ctx={ctx}
          tx={hook(encodeFunctionData({ abi: bandHookAbi, functionName: 'setAutoRecenter', args: [s.id, !s.cfg.autoRecenter] }))} />
      </Card>
      <Card title="Recenter">
        <p className="lead">{recenter.reason}</p>
        <TxButton label="Recenter" ctx={ctx} tx={hook(encodeFunctionData({ abi: bandHookAbi, functionName: 'recenter', args: [s.id] }))} />
        <p className="muted">Owner only: place the band again around the oracle now, adding nothing and skipping the drift trigger. Useful after changing the settings.</p>
        <TxButton label="Force recenter" tone="quiet" ctx={ctx}
          tx={hook(encodeFunctionData({ abi: bandHookAbi, functionName: 'fund', args: [s.id, 0n, 0n] }))} />
        <p className="muted">Anyone: set the resting fee to the floor, only needed when the pool was set up after it was initialized.</p>
        <TxButton label="Sync fee" tone="quiet" ctx={ctx} tx={hook(encodeFunctionData({ abi: bandHookAbi, functionName: 'syncFee', args: [s.id] }))} />
      </Card>
      <Withdraw pool={pool} s={s} ctx={ctx} />
      <Sweep pool={pool} s={s} ctx={ctx} />
      <SettingsForms pool={pool} s={s} ctx={ctx} />
    </div>
  )
}

function Ownership({ pool, s, ctx }: Props) {
  const [to, setTo] = useState('')
  const offeredToYou = !!s.wallet && isAddressEqual(s.wallet.address, s.pendingOwner)
  const transfer = (who: Address): Tx => ({
    to: pool.hook, value: 0n, data: encodeFunctionData({ abi: bandHookAbi, functionName: 'transferOwnership', args: [who] }),
  })
  return (
    <Card title="Ownership">
      {offeredToYou && (
        <TxButton label="Accept ownership" ctx={ctx}
          tx={{ to: pool.hook, value: 0n, data: encodeFunctionData({ abi: bandHookAbi, functionName: 'acceptOwnership' }) }} />
      )}
      <label className="field">
        <span>Hand the hook to (for example governance)</span>
        <input className="mono" placeholder="0x…" value={to} onChange={(e) => setTo(e.target.value.trim())} />
      </label>
      <TxButton label="Offer the hook" ctx={ctx} tx={isAddress(to) && to !== zeroAddress ? transfer(to) : undefined}
        confirm={`Offers the hook to ${to}. It must accept; until then this wallet stays the owner. A contract owner must accept plain ETH, or withdraw fails.`} />
      {s.pendingOwner !== zeroAddress && (
        <TxButton label="Cancel the open offer" tone="quiet" ctx={ctx} tx={transfer(zeroAddress)} />
      )}
    </Card>
  )
}

function Withdraw({ pool, s, ctx }: Props) {
  const { token0: t0, token1: t1 } = pool
  const placed = [s.core, s.backstop, s.limit].map((p) => positionAmounts(p, s.sqrtPriceX96))
  const total0 = placed.reduce((sum, a) => sum + a.amount0, Number(s.idle0))
  const total1 = placed.reduce((sum, a) => sum + a.amount1, Number(s.idle1))
  return (
    <Card title="Take everything out">
      <p className="muted">
        Burns every position and sends both tokens to the owner: about {formatAmount(total0, t0.decimals)} {t0.symbol} and{' '}
        {formatAmount(total1, t1.decimals)} {t1.symbol} now. Afterwards the pool is empty, and its price can be moved for free until the next deposit.
      </p>
      <TxButton label="Withdraw" tone="danger" ctx={ctx}
        tx={{ to: pool.hook, value: 0n, data: encodeFunctionData({ abi: bandHookAbi, functionName: 'withdraw', args: [s.id] }) }}
        confirm="Takes all of this pool's liquidity out of the hook and sends it to the owner." />
    </Card>
  )
}

function Sweep({ pool, s, ctx }: Props) {
  const [which, setWhich] = useState<'0' | '1' | 'other'>('1')
  const [other, setOther] = useState('')
  const [to, setTo] = useState('')
  const [amount, setAmount] = useState('')
  const token = which === '0' ? pool.token0 : which === '1' ? pool.token1 : undefined
  const currency = token ? token.address : other
  const raw = token ? parseAmount(amount, token.decimals) : 0n // another token: always its whole balance
  const ok = isAddress(currency) && (to === '' || isAddress(to))
  const tx: Tx | undefined = ok ? {
    to: pool.hook, value: 0n,
    data: encodeFunctionData({ abi: bandHookAbi, functionName: 'sweep', args: [currency, (to || zeroAddress) as Address, raw] }),
  } : undefined
  return (
    <Card title="Sweep">
      <p className="muted">Sends what sits idle in the hook (idle now: {formatAmount(s.idle0, pool.token0.decimals)} {pool.token0.symbol}, {formatAmount(s.idle1, pool.token1.decimals)} {pool.token1.symbol}), or a token sent to it by mistake. Positions are never touched.</p>
      <label className="field">
        <span>Token</span>
        <select value={which} onChange={(e) => setWhich(e.target.value as '0' | '1' | 'other')}>
          <option value="0">{pool.token0.symbol}</option>
          <option value="1">{pool.token1.symbol}</option>
          <option value="other">another token (its whole balance)</option>
        </select>
      </label>
      {which === 'other' && <label className="field"><span>Token address</span><input className="mono" value={other} onChange={(e) => setOther(e.target.value.trim())} /></label>}
      {token && <label className="field"><span>Amount (empty: all of it)</span><input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></label>}
      <label className="field"><span>To (empty: the owner)</span><input className="mono" value={to} onChange={(e) => setTo(e.target.value.trim())} /></label>
      <TxButton label="Sweep" tone="quiet" ctx={ctx} tx={tx} />
    </Card>
  )
}
