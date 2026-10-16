// The two settings calls: setParams (fees, band widths, trigger, guard; the source and switches stay) and
// setSource (replace a dead price feed, checked by the hook against the tick you expect it to report).
import { useState } from 'react'
import { encodeFunctionData, isAddress, type Hex } from 'viem'
import { bandHookAbi } from '../abi'
import type { HookConfig, Pool } from '../config'
import type { Tx } from '../lib/fundPlan'
import type { PoolState } from '../lib/poolState'
import { TxButton, type TxContext } from './TxButton'
import { Card } from './ui'

type Props = { pool: Pool; s: PoolState; ctx: TxContext }
type NumberKey = Exclude<keyof HookConfig, 'source' | 'enabled' | 'autoRecenter'>

const FIELDS: [NumberKey, string][] = [
  ['feeFloor', 'Fee floor (ppm, 800 = 0.08%)'],
  ['feeCap', 'Fee cap (ppm)'],
  ['feeSlopePpm', 'Fee slope (ppm per 100% apart)'],
  ['staleAfter', 'Stale after (seconds)'],
  ['halfBandTicks', 'Core half width (ticks)'],
  ['backstopHalfTicks', 'Backstop half width (ticks)'],
  ['backstopBps', 'Backstop share (bps)'],
  ['triggerTicks', 'Recenter trigger (ticks)'],
  ['guardTicks', 'Guard (ticks)'],
]

/** The call to the hook, or nothing when a typed number does not fit its type (a negative fee, a tick past int24). */
function hookTx(pool: Pool, encode: () => Hex): Tx | undefined {
  try {
    return { to: pool.hook, value: 0n, data: encode() }
  } catch {
    return undefined
  }
}

export function SettingsForms(props: Props) {
  return (
    <>
      <ParamsForm {...props} />
      <SourceForm {...props} />
    </>
  )
}

function ParamsForm({ pool, s, ctx }: Props) {
  const current = () => Object.fromEntries(FIELDS.map(([k]) => [k, String(s.cfg[k])]))
  const [text, setText] = useState<Record<string, string>>(current)
  const cfg: HookConfig = { ...s.cfg }
  for (const [k] of FIELDS) cfg[k] = Number(text[k])
  const valid = FIELDS.every(([k]) => text[k].trim() !== '' && Number.isInteger(cfg[k]))
  const changed = FIELDS.filter(([k]) => cfg[k] !== s.cfg[k]).map(([k]) => k)
  const tx = valid && changed.length > 0
    ? hookTx(pool, () => encodeFunctionData({ abi: bandHookAbi, functionName: 'setParams', args: [s.id, cfg] }))
    : undefined
  return (
    <Card title="Settings" wide>
      <p className="muted">Owner only. The hook checks the limits (src/BandHook.sol, _validate) and refuses what breaks them. The band moves to new widths at the next recenter; Force recenter does it now.</p>
      <div className="settings">
        {FIELDS.map(([k, label]) => (
          <label className="field" key={k}>
            <span>{label}</span>
            <input inputMode="numeric" value={text[k]} onChange={(e) => setText({ ...text, [k]: e.target.value })} />
          </label>
        ))}
      </div>
      <div className="row">
        <TxButton label="Save settings" ctx={ctx} tx={tx} confirm={`Changes ${changed.join(', ')} on the live pool.`} />
        <button className="btn quiet" onClick={() => setText(current())}>Reset to the live values</button>
      </div>
    </Card>
  )
}

function SourceForm({ pool, s, ctx }: Props) {
  const [source, setSource] = useState('')
  const [tick, setTick] = useState(String(s.oracle.tick))
  const [tolerance, setTolerance] = useState('100')
  const valid = isAddress(source) && [tick, tolerance].every((t) => t.trim() !== '' && Number.isInteger(Number(t)))
  const args = [s.id, source as `0x${string}`, Number(tick), Number(tolerance)] as const
  const tx = valid ? hookTx(pool, () => encodeFunctionData({ abi: bandHookAbi, functionName: 'setSource', args })) : undefined
  return (
    <Card title="Price source">
      <p className="muted">Owner only: the way to replace a feed that stopped answering. The hook reads the new source and refuses it unless it reports a tick within the tolerance of the one you expect.</p>
      <label className="field"><span>New source address</span><input className="mono" value={source} onChange={(e) => setSource(e.target.value.trim())} /></label>
      <label className="field"><span>Tick you expect it to report (current oracle: {s.oracle.tick})</span><input inputMode="numeric" value={tick} onChange={(e) => setTick(e.target.value)} /></label>
      <label className="field"><span>Tolerance (ticks)</span><input inputMode="numeric" value={tolerance} onChange={(e) => setTolerance(e.target.value)} /></label>
      <TxButton label="Replace the source" ctx={ctx} tx={tx} confirm={`Every swap and recenter will read ${source} from now on.`} />
    </Card>
  )
}
