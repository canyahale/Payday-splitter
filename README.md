# Payday Splitter

> Every payment landing in the agent vault is automatically split — 70% main wallet, 20% savings, 10% gas reserve — by a Reactive contract. Set it and forget it.

**Track:** Set It and Forget It — Reactive Omni Buildathon (5 Nov – 5 Dec 2026, closes Sat 5 Dec 2026, 20:00 UTC / 21:00 WAT)

**Status:** Live on testnet. The full loop is proven on-chain — payment in, split out, 1 second.

## Demo video

https://youtu.be/dnycFv6sxzs

## Why this exists

Agent wallets are moved by hand, and a hand move goes wrong once too often. On 31 Oct 2026 a manual transfer sent steve54's full 11,250 IAO to the wrong wallet — the whole balance, gone to an address it was never meant for. Payday Splitter removes that mistake class entirely: the destinations are fixed at deploy time, the split ratios are fixed at deploy time, and no human ever types an address or an amount again. Every payment that lands in the vault is split the same way, every time, with no one watching.

The gas share exists for the same reason: agent wallets keep running dry (an empty deployer wallet has blocked work more than once). Ten percent of every payment tops up the gas reserve automatically, so the wallet that pays for the next transaction is never empty.

## How the loop works

```
Payment lands in the vault (Base Sepolia)
        │  Transfer event
        ▼
PaydayReactive (Reactive Lasna) sees the event
        │  react() → requestCallback
        ▼
Callback proxy (Base Sepolia) calls vault.callback()
        │
        ▼
Vault splits: 700 main / 200 savings / 100 gas reserve
```

1. **SplitterVault** lives on Base Sepolia (chain 84532). It holds incoming payments and can only split when its `callback()` is called by the Reactive callback proxy, with the sender equal to the PaydayReactive address fixed at deploy. It cannot trigger itself — without Reactive, nothing splits.
2. **PaydayReactiveOmni** lives on Reactive Lasna (chain 5318007). It subscribes to `Transfer(token, *, vault)` events on Base Sepolia. When one fires, `react()` requests a callback to the vault with the token and amount.
3. The callback proxy on Base Sepolia delivers the call, and the vault sends 70% to the main wallet, 20% to savings, 10% to the gas reserve. Rounding remainder goes to the gas reserve.

Shares are 7000 / 2000 / 1000 basis points and must sum to 10,000. Destinations are set once, at deploy.

## Live contracts (testnet)

| Contract | Chain | Address |
|---|---|---|
| SplitterVault (v3) | Base Sepolia (84532) | `0xB919828FfF2e6b3B6f7a3E5e8033b831e6545e9E` |
| PaydayReactiveOmni (v2) | Lasna (5318007) | `0x4613485BE1C213361BD48F1e34C95E7694E014eD` |
| MockERC20 (MPT, test token) | Base Sepolia (84532) | `0x43a33C4AeC29DB91c655eAB44417545ceCeD21A1` |

Destinations (fixed at deploy):

| Share | Wallet |
|---|---|
| 70% main | `0x77D3bbBAe111399a69a33b9feeC639fC3B155894` |
| 20% savings | `0x6B9eE8C207F3258c023C0863DD8c638DD921cc66` |
| 10% gas reserve | `0x92760589D753E606D3AB6a2FC15be6D9Aa366B3c` |

## Proof: the full loop, on-chain

One payment of 1,000 MPT, 23 Nov 2026:

| Step | Transaction | Block |
|---|---|---|
| Payment: 1,000 MPT sent to the vault | `0xdc88c361bc4ca1f24fab2f030ea55e54ff48b823d418614842bb7e29297fe85d` | 62455932 (Base Sepolia) |
| Reactive: event seen, callback requested | `0xb2fc4b61f0e0c9aba392c944b4c7d2c2d6853cf2e881e5ea3a5dd084e05da6a6` | 9032981 (Lasna) |
| Split: 700 / 200 / 100 MPT sent out | `0x7555e7151980c0b30a0f3b6d6c829f56baf1f46ad754058a307e8a8e84a4e61c` | 62455940 (Base Sepolia) |

**Latency: 1 second** (payment block timestamp → split block timestamp). Vault balance after the split: **0**. The split transaction carries the `Split` event plus three `Transfer` logs — 700 MPT to main, 200 MPT to savings, 100 MPT to the gas reserve.

Second live run (the one in the demo video), 23 Nov 2026:

| Step | Transaction | Block |
|---|---|---|
| Payment: 1,000 MPT sent to the vault | `0x56ec09a0484af0e1ad0f8943ea9c460dc7160f3a534d127be54612a17e22c1b1` | 62502902 (Base Sepolia) |
| Split: 700 / 200 / 100 MPT sent out | `0xd8b3e71081ac4cf1392701db041b68569b7f4badc02e196e7ba733e38d467638` | 62502908 (Base Sepolia) |

Latency again 1 second. Cumulative split so far across all runs: main 2,800 / savings 800 / gas 400 MPT.

Deployment transactions:

| Step | Transaction |
|---|---|
| Deploy SplitterVault v3 | `0x73830d78bb2770c3ea39674b6602e128e340fce2467b5be6f15a6f336108d9fc` |
| Deploy PaydayReactiveOmni v2 | `0xa2a6aaccfd4ab64e08ce7a36a6aa94f2dc3a90a09cbb4ab4ffa493c1dd6502d9` |
| Fund Reactive reserves (0.17 lREACT) | `0x9bc03e4f0da6d051090e741122d7750d244b22a4e39bb62a35136e68aab0020d` |
| Fund vault callback reserves (0.004 ETH) | `0x26cb08d8184fc205aa7c61684a359a4d35f5179bb6076511ebdac97b36e9b15b` |

Verify on the explorers: [Base Sepolia (Basescan)](https://sepolia.basescan.org/address/0xB919828FfF2e6b3B6f7a3E5e8033b831e6545e9E) · [Lasna (Reactscan)](https://lasna.reactscan.net/address/0x4613485BE1C213361BD48F1e34C95E7694E014eD)

## What broke along the way (honest build log)

The first version used Reactive's legacy pattern (`vmOnly`, `service.subscribe`). It deployed fine, the event was picked up, and then `react()` reverted on entry — the RVM no longer exists on Omni, so a legacy reactive contract can never execute. That contract is blacklisted with a small debt and its vault's 1,000 MPT is stranded. The port to the Omni pattern (`onlySystem` + `SYSTEM.subscribe` + `requestCallbackV_1_0`) fixed it — and then the first Omni loop failed on gas: the callback needs 148,700 gas but a 300,000 limit only delivers ~144,776 after proxy overhead, a shortfall of 3,924 gas. Raising the limit to 400,000 and redeploying both contracts produced the working loop above. The old contracts are left in place, not hidden: vault v1 `0x086a674515B4de3A805055C41F9819D8b6E4d686`, legacy reactive `0x7a41A895375394Fd47E973e113EC7aA582f4204a`, Omni v1 `0xBC6D6F936AeB6519d1b7C4Ed9c952B84207Aaf91` + vault v2 `0x2d7A3aEfAc1a1358FB5DE4cDB6FD8666807f4a86`.

## Setup

```bash
forge install foundry-rs/forge-std
forge install Reactive-Network/reactive-lib
forge install Reactive-Network/reactive-lib-omni@3ade0dc
```

## Run the tests

```bash
forge test
```

43/43 pass (28 vault + legacy reactive tests, 15 Omni-port tests). The ported contract was also validated with Reactive's own MCP tools: `check_rc_source` OK_SOURCE with 0 findings, `decode_callback` OK_CALLBACK with no defects.

## What this is not

- **Testnet only.** Base Sepolia + Lasna, a MockERC20 test token (MPT), no real money anywhere.
- **Frontend.** A read-only site in `frontend/` — the story, the loop, live on-chain data and the demo video. No wallet connection, no transactions.
- **No mainnet.** Destinations and shares are fixed at deploy by design — that is the point — but nothing here touches mainnet funds.

## Project layout

```
src/
  SplitterVault.sol        # Base Sepolia vault — splits only via callback()
  PaydayReactiveOmni.sol   # Lasna — Omni pattern, subscribes to Transfer events
  PaydayReactive.sol       # legacy version (superseded, kept for the record)
test/
  SplitterVault.t.sol
  PaydayReactiveOmni.t.sol
  PaydayReactive.t.sol
script/
  DeployVault.s.sol
  DeployReactiveOmni.s.sol
  DeployToken.s.sol
deployments/
  testnet.json             # every address, tx hash and balance, as recorded
DEPLOY-RUNBOOK.md          # the full deploy record, including the failures
```

## Licence

MIT
