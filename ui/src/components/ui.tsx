// Small building blocks the views share: a card, a labelled value, a status badge, an explorer link.
// Their look lives in styles.css under the same class names.
import type { ReactNode } from 'react'
import { EXPLORER } from '../config'
import { shortAddress } from '../lib/format'

export function Card({ title, children, wide }: { title: string; children: ReactNode; wide?: boolean }) {
  return (
    <section className={wide ? 'card wide' : 'card'}>
      <h2>{title}</h2>
      {children}
    </section>
  )
}

export function Stat({ label, children, hint }: { label: string; children: ReactNode; hint?: ReactNode }) {
  return (
    <div className="stat">
      <span className="stat-label">{label}</span>
      <span className="stat-value">{children}</span>
      {hint && <span className="stat-hint">{hint}</span>}
    </div>
  )
}

export type Tone = 'good' | 'bad' | 'warn' | 'plain'

export function Badge({ tone, children }: { tone: Tone; children: ReactNode }) {
  return <span className={`badge ${tone}`}>{children}</span>
}

export function Link({ address, kind = 'address' }: { address: string; kind?: 'address' | 'tx' }) {
  return (
    <a className="mono" href={`${EXPLORER}/${kind}/${address}`} target="_blank" rel="noreferrer">
      {shortAddress(address)}
    </a>
  )
}

export function Notice({ tone, children }: { tone: Tone; children: ReactNode }) {
  return <div className={`notice ${tone}`}>{children}</div>
}
