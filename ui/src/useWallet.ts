// The connected wallet as React state: discovery on load, connect on click, and following the
// account and network the person picks in MetaMask afterwards.
import { useEffect, useState } from 'react'
import { getAddress } from 'viem'
import { explain } from './lib/errors'
import { connect, discoverWallets, switchToRobinhood, type Announced, type Connected } from './lib/wallet'

export function useWallet() {
  const [wallets, setWallets] = useState<Announced[]>([])
  const [connected, setConnected] = useState<Connected | null>(null)
  const [error, setError] = useState<string>()

  useEffect(() => discoverWallets(setWallets), [])

  const provider = connected?.provider
  useEffect(() => {
    if (!provider) return
    const onAccounts = (accounts: string[]) =>
      setConnected((c) => (c && accounts.length ? { ...c, address: getAddress(accounts[0]) } : null))
    const onChain = (chainId: string) => setConnected((c) => c && { ...c, chainId: Number(chainId) })
    provider.on('accountsChanged', onAccounts)
    provider.on('chainChanged', onChain)
    return () => {
      provider.removeListener('accountsChanged', onAccounts)
      provider.removeListener('chainChanged', onChain)
    }
  }, [provider])

  async function connectTo(wallet: Announced) {
    setError(undefined)
    try {
      setConnected(await connect(wallet.provider))
    } catch (err) {
      setError(explain(err))
    }
  }

  async function switchChain() {
    setError(undefined)
    try {
      if (connected) await switchToRobinhood(connected.provider)
    } catch (err) {
      setError(explain(err))
    }
  }

  return { wallets, connected, error, connectTo, switchChain, disconnect: () => setConnected(null) }
}
