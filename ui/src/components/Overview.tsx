// The pool at a glance: prices, ownership, what the hook has placed, its settings against the agreed
// ones, and whether a recenter is due. Reads only; the page refreshes it from the chain.
import { isAddressEqual, zeroAddress } from 'viem'
import type { HookConfig, Pool } from '../config'
import { recenterStatus, settingsDiffer } from '../lib/checks'
import { formatAge, formatAmount, formatPpm, formatPrice } from '../lib/format'
import { feePpm, positionAmounts, priceAtTick, type Pos } from '../lib/math'
import type { PoolState } from '../lib/poolState'
import { Badge, Card, Link, Stat } from './ui'

export function Overview({ pool, s }: { pool: Pool; s: PoolState }) {
  const { token0: t0, token1: t1 } = pool
  const distance = Math.abs(s.poolTick - s.oracle.tick)
  const oraclePrice = (Number(s.oracle.priceX18) / 1e18) * 10 ** (t0.decimals - t1.decimals)
  const recenter = recenterStatus(s)
  return (
    <div className="grid">
      <Card title="Prices">
        <Stat label="Pool price" hint={`tick ${s.poolTick}`}>
          {s.sqrtPriceX96 === 0n ? 'not initialized' : `1 ${t0.symbol} = ${formatPrice(priceAtTick(s.poolTick, t0.decimals, t1.decimals))} ${t1.symbol}`}
        </Stat>
        <Stat label="Oracle price" hint={`tick ${s.oracle.tick} · updated ${formatAge(Number(s.now - s.oracle.updatedAt))} ago`}>
          1 {t0.symbol} = {formatPrice(oraclePrice)} {t1.symbol}{' '}
          <Badge tone={s.oracle.fresh ? 'good' : 'bad'}>{s.oracle.fresh ? 'fresh' : 'stale'}</Badge>
        </Stat>
        <Stat label="Pool to oracle" hint={`the hook refuses to place past the guard, ${s.cfg.guardTicks} ticks`}>
          {distance} ticks <Badge tone={distance > s.cfg.guardTicks ? 'bad' : 'good'}>{distance > s.cfg.guardTicks ? 'past the guard' : 'within the guard'}</Badge>
        </Stat>
        <Stat label="Fee a swap pays now">{formatPpm(feePpm(s.cfg, s.poolTick, s.oracle.tick, s.oracle.fresh))}</Stat>
      </Card>
      <Card title="Ownership">
        <Stat label="Owner"><Link address={s.owner} /></Stat>
        <Stat label="Offered to">{s.pendingOwner === zeroAddress ? 'nobody' : <Link address={s.pendingOwner} />}</Stat>
        <Stat label="This wallet">{role(s)}</Stat>
      </Card>
      <Card title="Liquidity placed" wide>
        <Position name="Core band" p={s.core} pool={pool} s={s} />
        <Position name="Backstop" p={s.backstop} pool={pool} s={s} />
        <Position name="Limit" p={s.limit} pool={pool} s={s} />
        <Stat label="Idle in the hook">
          {formatAmount(s.idle0, t0.decimals)} {t0.symbol} · {formatAmount(s.idle1, t1.decimals)} {t1.symbol}
        </Stat>
      </Card>
      <Card title="Recenter">
        <p className="lead">{recenter.reason}</p>
        <Badge tone={recenter.due ? 'warn' : 'plain'}>{recenter.due ? 'due' : 'not due'}</Badge>
      </Card>
      <Settings pool={pool} s={s} />
    </div>
  )
}

function role(s: PoolState) {
  const w = s.wallet?.address
  if (!w) return <Badge tone="plain">not connected</Badge>
  if (isAddressEqual(w, s.owner)) return <Badge tone="good">owner</Badge>
  if (isAddressEqual(w, s.pendingOwner)) return <Badge tone="warn">offered the hook: accept it under Fund</Badge>
  return <Badge tone="plain">neither: owner actions will be refused</Badge>
}

function Position({ name, p, pool, s }: { name: string; p: Pos; pool: Pool; s: PoolState }) {
  const { token0: t0, token1: t1 } = pool
  if (p.liquidity === 0n) return <Stat label={name}>empty</Stat>
  const { amount0, amount1 } = positionAmounts(p, s.sqrtPriceX96)
  const range = `${formatPrice(priceAtTick(p.lower, t0.decimals, t1.decimals))} – ${formatPrice(priceAtTick(p.upper, t0.decimals, t1.decimals))}`
  return (
    <Stat label={name} hint={`${range} ${t1.symbol} per ${t0.symbol} · ticks ${p.lower} to ${p.upper}`}>
      {formatAmount(amount0, t0.decimals)} {t0.symbol} + {formatAmount(amount1, t1.decimals)} {t1.symbol}
    </Stat>
  )
}

const LABELS: Record<keyof HookConfig, string> = {
  source: 'Price source',
  feeFloor: 'Fee floor',
  feeCap: 'Fee cap',
  feeSlopePpm: 'Fee slope',
  staleAfter: 'Stale after',
  halfBandTicks: 'Core half width',
  backstopHalfTicks: 'Backstop half width',
  backstopBps: 'Backstop share',
  triggerTicks: 'Recenter trigger',
  guardTicks: 'Guard',
  enabled: 'Switched on',
  autoRecenter: 'Recenter inside swaps',
}

/** One setting as a person reads it: fees as percentages, times as durations, widths in ticks. */
function showSetting(k: keyof HookConfig, cfg: HookConfig): string {
  const v = cfg[k]
  if (typeof v === 'boolean') return v ? 'yes' : 'no'
  if (typeof v === 'string') return v
  if (k === 'feeFloor' || k === 'feeCap') return formatPpm(v)
  if (k === 'feeSlopePpm') return `${formatPpm(v)} per 100% apart`
  if (k === 'staleAfter') return formatAge(v)
  if (k === 'backstopBps') return `${v / 100}%`
  return `${v} ticks`
}

function Settings({ pool, s }: { pool: Pool; s: PoolState }) {
  const differ = settingsDiffer(pool, s)
  return (
    <Card title="Hook settings" wide>
      <p className="lead">
        {differ.length === 0
          ? <Badge tone="good">match {pool.settingsFile}</Badge>
          : <Badge tone="bad">{differ.length} differ from {pool.settingsFile}</Badge>}
      </p>
      <div className="settings">
        {(Object.keys(LABELS) as (keyof HookConfig)[]).map((k) => (
          <Stat key={k} label={LABELS[k]} hint={differ.includes(k) ? `agreed: ${showSetting(k, pool.expected)}` : undefined}>
            {k === 'source' ? <Link address={s.cfg.source} /> : showSetting(k, s.cfg)}{' '}
            {differ.includes(k) && <Badge tone="bad">differs</Badge>}
          </Stat>
        ))}
      </div>
    </Card>
  )
}
