// The top bar in Hydration's layout: the name on the left, the network and the wallet on the right,
// and below it the three views as pills.
import { useState } from 'react'
import { robinhood } from '../config'
import { shortAddress } from '../lib/format'
import type { useWallet } from '../useWallet'

export type View = 'overview' | 'fund' | 'manage'
const VIEWS: [View, string][] = [['overview', 'Overview'], ['fund', 'Fund'], ['manage', 'Manage']]

type Props = { view: View; onView: (view: View) => void; wallet: ReturnType<typeof useWallet> }

export function Header({ view, onView, wallet }: Props) {
  const c = wallet.connected
  return (
    <>
      <header className="top">
        <div className="brand">
          <span className="logo" aria-hidden>◈</span>
          <span>BandHook</span>
          <span className="brand-sub">liquidity console</span>
        </div>
        <div className="row">
          {c && c.chainId !== robinhood.id && <button className="btn pink" onClick={wallet.switchChain}>Switch to Robinhood Chain</button>}
          {c && c.chainId === robinhood.id && <span className="pill"><span className="dot" />Robinhood Chain</span>}
          {c ? (
            <button className="btn primary" onClick={wallet.disconnect} title="Disconnect">{shortAddress(c.address)}</button>
          ) : (
            <ConnectButton wallet={wallet} />
          )}
        </div>
      </header>
      {wallet.error && <p className="banner bad">{wallet.error}</p>}
      <nav className="subbar">
        {VIEWS.map(([key, label]) => (
          <button key={key} className={view === key ? 'tab active' : 'tab'} onClick={() => onView(key)}>{label}</button>
        ))}
      </nav>
    </>
  )
}

/** One wallet: connect straight away. Several: let the person pick, MetaMask first. */
function ConnectButton({ wallet }: { wallet: Props['wallet'] }) {
  const [open, setOpen] = useState(false)
  if (wallet.wallets.length === 0) return <button className="btn primary" disabled>No wallet found: install MetaMask</button>
  if (wallet.wallets.length === 1) {
    return <button className="btn primary" onClick={() => wallet.connectTo(wallet.wallets[0])}>Connect wallet</button>
  }
  return (
    <div className="menu">
      <button className="btn primary" onClick={() => setOpen(!open)}>Connect wallet</button>
      {open && (
        <div className="menu-list">
          {wallet.wallets.map((w) => (
            <button key={w.info.uuid} onClick={() => { setOpen(false); wallet.connectTo(w) }}>
              {w.info.icon && <img src={w.info.icon} alt="" />}
              {w.info.name}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
