// Finds the browser wallet (MetaMask, with or without a Ledger behind it), connects it and moves it to
// Robinhood Chain. EIP-6963 lets the page pick MetaMask even when another extension also injects one.
import { createWalletClient, custom, getAddress, numberToHex, type Address, type EIP1193Provider, type WalletClient } from 'viem'
import { EXPLORER, robinhood } from '../config'

export type Announced = { info: { uuid: string; name: string; icon: string; rdns: string }; provider: EIP1193Provider }
export type Connected = { address: Address; chainId: number; provider: EIP1193Provider; client: WalletClient }

/** Collects the wallets that announce themselves, MetaMask first; calls back with the list on each new one. */
export function discoverWallets(onChange: (wallets: Announced[]) => void): () => void {
  const found = new Map<string, Announced>()
  const onAnnounce = (event: Event) => {
    const announced = (event as CustomEvent<Announced>).detail
    found.set(announced.info.uuid, announced)
    const isMetaMask = (w: Announced) => Number(w.info.rdns === 'io.metamask')
    onChange([...found.values()].sort((a, b) => isMetaMask(b) - isMetaMask(a)))
  }
  window.addEventListener('eip6963:announceProvider', onAnnounce)
  window.dispatchEvent(new Event('eip6963:requestProvider'))
  // an older wallet that only sets window.ethereum
  const injected = (window as { ethereum?: EIP1193Provider }).ethereum
  if (injected && found.size === 0) {
    onChange([{ info: { uuid: 'injected', name: 'Browser wallet', icon: '', rdns: '' }, provider: injected }])
  }
  return () => window.removeEventListener('eip6963:announceProvider', onAnnounce)
}

export async function connect(provider: EIP1193Provider): Promise<Connected> {
  const [account] = await provider.request({ method: 'eth_requestAccounts' })
  const chainId = Number(await provider.request({ method: 'eth_chainId' }))
  const client = createWalletClient({ chain: robinhood, transport: custom(provider) })
  return { address: getAddress(account), chainId, provider, client }
}

/** Asks the wallet to switch to Robinhood Chain, adding the network first if the wallet does not know it. */
export async function switchToRobinhood(provider: EIP1193Provider): Promise<void> {
  const chainId = numberToHex(robinhood.id)
  try {
    await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId }] })
  } catch (err) {
    const e = err as { code?: number; data?: { originalError?: { code?: number } } }
    if (e.code !== 4902 && e.data?.originalError?.code !== 4902) throw err // 4902: unknown network
    await provider.request({
      method: 'wallet_addEthereumChain',
      params: [{
        chainId,
        chainName: robinhood.name,
        nativeCurrency: robinhood.nativeCurrency,
        rpcUrls: [...robinhood.rpcUrls.default.http],
        blockExplorerUrls: [EXPLORER],
      }],
    })
  }
}
