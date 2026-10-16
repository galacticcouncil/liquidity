// The console's page: the header, the pool's title, then one of three views: overview, fund, manage.
// It reads the pool from the chain every 15 seconds and again after every transaction.
import { useCallback, useEffect, useRef, useState } from 'react'
import { createPublicClient, http, type Address } from 'viem'
import { Header, type View } from './components/Header'
import { FundPanel } from './components/FundPanel'
import { ManagePanel } from './components/ManagePanel'
import { Overview } from './components/Overview'
import { Link } from './components/ui'
import { POOLS, RPC_URL, robinhood } from './config'
import { explain } from './lib/errors'
import { shortAddress } from './lib/format'
import { readPool, type PoolState } from './lib/poolState'
import { useWallet } from './useWallet'

// batch: each refresh's reads go to the node as one request
const client = createPublicClient({ chain: robinhood, transport: http(RPC_URL, { batch: true }) })

export default function App() {
  const wallet = useWallet()
  const [poolIndex, setPoolIndex] = useState(0)
  const pool = POOLS[poolIndex]
  const [view, setView] = useState<View>('overview')
  const [anchor, setAnchor] = useState<Address>() // deployed from this page, kept until it reloads
  const [state, setState] = useState<PoolState>()
  const [readError, setReadError] = useState<string>()
  const latest = useRef(0) // only the newest read may land, so a slow older one never overwrites it

  const address = wallet.connected?.address
  const refresh = useCallback(async () => {
    const id = ++latest.current
    try {
      const next = await readPool(client, pool, address, anchor)
      if (id === latest.current) {
        setState(next)
        setReadError(undefined)
      }
    } catch (err) {
      if (id === latest.current) setReadError(explain(err))
    }
  }, [pool, address, anchor])

  useEffect(() => {
    refresh()
    const timer = setInterval(refresh, 15_000)
    return () => clearInterval(timer)
  }, [refresh])

  const ctx = { client, wallet: wallet.connected, refresh }
  return (
    <div className="page">
      <Header view={view} onView={setView} wallet={wallet} />
      <main>
        <div className="title">
          <div>
            <h1>{pool.name}</h1>
            <p className="muted">
              BandHook on Robinhood Chain · hook <Link address={pool.hook} />
              {state && <> · pool <span className="mono">{shortAddress(state.id)}</span></>}
            </p>
          </div>
          {POOLS.length > 1 && (
            <select value={poolIndex} onChange={(e) => setPoolIndex(Number(e.target.value))}>
              {POOLS.map((p, i) => <option key={p.hook} value={i}>{p.name}</option>)}
            </select>
          )}
        </div>
        {RPC_URL !== robinhood.rpcUrls.default.http[0] && (
          <p className="banner warn">Reading from {RPC_URL}, not the live chain: point the wallet at the same node.</p>
        )}
        {readError && <p className="banner bad">Could not read the chain: {readError}</p>}
        {!state && !readError && <p className="muted">Reading the chain…</p>}
        {state && view === 'overview' && <Overview pool={pool} s={state} />}
        {state && view === 'fund' && <FundPanel pool={pool} s={state} ctx={ctx} anchor={anchor} onAnchor={setAnchor} />}
        {state && view === 'manage' && <ManagePanel pool={pool} s={state} ctx={ctx} />}
      </main>
      <footer className="muted">Reads from {RPC_URL}. Every transaction is checked against the chain before your wallet sees it.</footer>
    </div>
  )
}
