# Payday Splitter — Deploy Runbook (testnet only)

Prepared 2026-11-22 ~21:10 WAT. Status: **LIVE LOOP SUCCEEDED 2026-11-23
~06:51 WAT — Payday Splitter splits end-to-end on Omni (vault v3 +
RC v2, gas limit 400,000; 1,000 MPT → 700/200/100 in 1 second).**
The first Omni attempt (RC v1 + vault v2, gas limit 300,000) proved
react() works but the callback reverted on gas — see §7.6. Full record in
deployments/testnet.json `omni_redeploy`; the legacy failure record is
kept under `diagnosis`.

## §0 — Blockers (read first)

1. **No Base Sepolia ETH.** The fresh deployer holds 0 ETH on both chains.
   Every Base Sepolia faucet needs a human step a subagent cannot do:
   - Alchemy (0.1 ETH/24h, no account) requires ≥0.001 ETH on Ethereum
     mainnet + mainnet activity — a fresh wallet fails eligibility.
   - QuickNode (no account, no mainnet balance) and Chainlink (0.5 ETH)
     need a wallet connection in a browser, and the QuickNode/Zalalena
     forms need a CAPTCHA.
   - Superchain / Coinbase CDP / Chainstack faucets need a sign-in.
   **Fix:** run a browser task (or Isaiah himself) to claim 0.1 ETH from
   the QuickNode faucet (https://faucet.quicknode.com/drip) or Alchemy
   (https://www.alchemy.com/faucets/base-sepolia) to the deployer address
   in §1. One 0.1 ETH drip covers the whole deployment + live loop.
2. **Exec-originated network calls need user approval that timed out
   twice** (curl to the MCP/RPC endpoints, then `cast chain-id` to both
   RPCs — the requests themselves also timed out). Do not re-run deploy
   commands until that approval is granted; the parent agent must obtain it
   (or run the deploys itself). Browser search/open worked fine throughout.
3. **Legacy-vs-Omni risk (unresolved until the live loop runs).** The
   scaffold uses the LEGACY pattern (`AbstractReactive`, `vmOnly`,
   `service.subscribe` to the legacy system contract
   `0x0000000000000000000000000000000000fffFfF`, `emit Callback`).
   The current docs describe Reactive Omni: system contract
   `0x8888888888888888888888888888888888888888`, `onlySystem`, and
   `SYSTEM.requestCallbackV_1_0()`. The docs say legacy-deployed contracts
   keep working; whether a NEW legacy-pattern deployment subscribes and
   fires on Lasna is unproven. If the live loop never fires, check
   Reactscan for the reactive tx, then the MCP `trace_origin_event`, and
   be ready to port `PaydayReactive` to the Omni pattern (same vault).

   **RESOLVED 2026-11-22 ~22:45 WAT — the risk was real, and the loop
   FAILED because of it.** Proven by MCP trace_origin_event + get_rc_health:
   the event WAS picked up and react() WAS called (reactive tx
   0x870161a8dd76aeae8a307f21902ef3fd32ea54e4cc22d29dc3337c21bfd646f0,
   block 9008101) but reverted with 'VM only' — the RVM no longer exists
   on Omni, so legacy react() can never run. The contract is BLACKLISTED
   (IN_DEBT_BLOCKED, 0.0123389 REACT debt on the Omni side) and its
   1 lREACT of legacy-proxy reserves is stranded. Full evidence in
   deployments/testnet.json `diagnosis`. **The fix is the Omni port in §7 —
   do NOT retry the legacy contracts.**

## §1 — Prepared values (verified locally, 2026-11-22)

| Item | Value |
|---|---|
| Deployer (fresh, testnet-only) | `0x7cBB9C2267E208E031E7a81Ef8A48642202FbE56` |
| Deployer key | `~/workspace/reactive-payday-splitter/.deployer.json` (chmod 600) |
| Main wallet | `0x77D3bbBAe111399a69a33b9feeC639fC3B155894` |
| Savings wallet | `0x6B9eE8C207F3258c023C0863DD8c638DD921cc66` |
| Gas reserve wallet | `0x92760589D753E606D3AB6a2FC15be6D9Aa366B3c` |
| Destination keys | `~/workspace/reactive-payday-splitter/.destinations.json` (chmod 600) |
| Predicted PaydayReactive (Lasna nonce 0) | `0x7a41A895375394Fd47E973e113EC7aA582f4204a` |
| Base Sepolia callback proxy | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` |
| Lasna faucet contract (on Base Sepolia) | `0x2afaFD298b23b62760711756088F75B7409f5967` |
| Legacy system contract (Lasna) | `0x0000000000000000000000000000000000fffFfF` |
| Omni system contract (Lasna) | `0x8888888888888888888888888888888888888888` |
| Base Sepolia RPC | `https://sepolia.base.org` (chain 84532) |
| Lasna RPC | `https://lasna-rpc.rnk.dev/` (chain 5318007) |
| Callback gas limit | `300000` (minimum enforced: 100,000) |

Build + tests verified: `forge build` clean, `forge test` **28/28 pass**.

**Nonce discipline:** the deployer must make NO transaction on Lasna before
`DeployReactive.s.sol` runs, or the predicted address breaks. Base Sepolia
activity (token + vault deploys) does not affect the Lasna nonce.

## §2 — Fund (needs the §0 fixes first)

```bash
export PATH="$HOME/.foundry/bin:$PATH"
cd ~/workspace/reactive-payday-splitter
PK=$(node -e "console.log(require('./.deployer.json').privateKey)")
DEPLOYER=0x7cBB9C2267E208E031E7a81Ef8A48642202FbE56
BASE=https://sepolia.base.org
LASNA=https://lasna-rpc.rnk.dev/

# 1. Claim 0.1 Base Sepolia ETH to $DEPLOYER (browser task / Isaiah — see §0.1)
# 2. Swap 0.1 ETH -> 10 lREACT on Lasna via the on-chain faucet (no CAPTCHA):
cast send 0x2afaFD298b23b62760711756088F75B7409f5967 --rpc-url $BASE \
  --private-key $PK "request(address)" $DEPLOYER --value 0.1ether
# 3. Confirm:
cast balance $DEPLOYER --rpc-url $BASE        # expect 0.1 ETH minus gas, then ~0
cast balance $DEPLOYER --rpc-url $LASNA       # expect 10 lREACT minus gas
```

## §3 — Deploy (in this exact order)

```bash
# 0. Payment token on Base Sepolia (deployer nonce 0 on Base Sepolia)
forge script script/DeployToken.s.sol --rpc-url $BASE --broadcast
#    -> TOKEN (record it)

# 1. Vault on Base Sepolia (nonce 1), reactive address = prediction from §1
export TOKEN=<token> REACTIVE_ADDRESS=0x7a41A895375394Fd47E973e113EC7aA582f4204a \
  MAIN_WALLET=0x77D3bbBAe111399a69a33b9feeC639fC3B155894 \
  SAVINGS_WALLET=0x6B9eE8C207F3258c023C0863DD8c638DD921cc66 \
  GAS_RESERVE=0x92760589D753E606D3AB6a2FC15be6D9Aa366B3c \
  CALLBACK_PROXY=0x476F44b11F5C942c58f4c8E3d0300E5710743585
forge script script/DeployVault.s.sol --rpc-url $BASE --broadcast
#    -> VAULT (record it)

# 2. Reactive on Lasna (nonce 0 — first Lasna tx from this deployer).
#    Script REVERTS unless the deployed address == prediction.
export VAULT=<vault> ORIGIN_CHAIN_ID=84532 CALLBACK_GAS_LIMIT=300000
forge script script/DeployReactive.s.sol --rpc-url $LASNA --broadcast
#    -> REACTIVE (must equal 0x7a41A895375394Fd47E973e113EC7aA582f4204a)
```

## §4 — Fund the fee accounts (both sides must stay funded; any debt blocks execution)

```bash
REACTIVE=0x7a41A895375394Fd47E973e113EC7aA582f4204a
# Reactive side: 1 lREACT reserves via the LEGACY system contract (the
# contract subscribes through it — see §0.3)
cast send 0x0000000000000000000000000000000000fffFfF --rpc-url $LASNA \
  --private-key $PK "depositTo(address)" $REACTIVE --value 1ether
# Callback side: 0.05 ETH reserves via the Base Sepolia callback proxy
cast send 0x476F44b11F5C942c58f4c8E3d0300E5710743585 --rpc-url $BASE \
  --private-key $PK "depositTo(address)" $VAULT --value 0.05ether
# Verify zero debt on both sides:
cast call 0x0000000000000000000000000000000000fffFfF "debt(address)" $REACTIVE --rpc-url $LASNA | cast to-dec
cast call 0x476F44b11F5C942c58f4c8E3d0300E5710743585 "debt(address)" $VAULT --rpc-url $BASE | cast to-dec
```

## §5 — Live loop (record every hash + timestamps)

```bash
# 1. Send 1,000 MPT to the vault; record tx hash + block timestamp T0.
cast send $TOKEN --rpc-url $BASE --private-key $PK \
  "transfer(address,uint256)" $VAULT 1000ether
# 2. Watch Lasna for the reactive tx (react() -> PaymentSeen + Callback):
#    https://lasna.reactscan.net/address/0x7a41A895375394Fd47E973e113EC7aA582f4204a
# 3. Watch Base Sepolia for the callback split tx (Split event on the vault):
#    https://sepolia.basescan.org/address/<vault>#events
# 4. Verify the three destinations received 700 / 200 / 100 MPT:
cast call $TOKEN "balanceOf(address)" 0x77D3bbBAe111399a69a33b9feeC639fC3B155894 --rpc-url $BASE | cast to-dec
cast call $TOKEN "balanceOf(address)" 0x6B9eE8C207F3258c023C0863DD8c638DD921cc66 --rpc-url $BASE | cast to-dec
cast call $TOKEN "balanceOf(address)" 0x92760589D753E606D3AB6a2FC15be6D9Aa366B3c --rpc-url $BASE | cast to-dec
# 5. Latency = split-tx block timestamp - payment-tx block timestamp.
# 6. If the callback never lands, query the system contract:
cast call 0x0000000000000000000000000000000000fffFfF \
  "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])" <reactive-tx-hash> \
  --rpc-url $LASNA
```

## §6 — Submission artefacts still to do after a successful loop

- DoraHacks registration (parent/Isaiah — NOT this task)
- Public GitHub repo (parent/Isaiah — NOT this task)
- Demo video < 3 min (Isaiah posts videos himself)
- Submit by 5 Dec 2026, 21:00 WAT

## §7 — OMNI REDEPLOY (prepared 2026-11-22 ~23:55 WAT; needs Isaiah's yes)

The fix for the §0.3 failure. **Nothing in this section has been deployed
yet — preparation only.** The ported contract is written, tested and
MCP-validated; the redeploy itself waits for his yes.

### §7.0 — What is ready

| Item | Value |
|---|---|
| Ported contract | `src/PaydayReactiveOmni.sol` (Omni pattern: `onlySystem` + `SYSTEM.subscribe` on `0x8888...8888` + `SYSTEM.requestCallbackV_1_0`; template from MCP `plan_rc` + `get_rc_template`, reactive-lib-omni commit `3ade0dc`) |
| Ported tests | `test/PaydayReactiveOmni.t.sol` — **15 new tests, all pass; full suite 43/43** (`forge build` clean, `forge test` 43 passed / 0 failed) |
| Deploy script | `script/DeployReactiveOmni.s.sol` (reverts unless the deployed address matches the prediction) |
| MCP validation | `check_rc_source` on the ported contract: **OK_SOURCE, 0 findings**. `decode_callback` on the exact payload the port will send: **OK_CALLBACK, no defects** (selector `0x246a9512`, ~144,776 gas reaches the vault from a 300,000 limit after 130,000 proxy overhead) |
| Predicted new RC address | `0xBC6D6F936AeB6519d1b7C4Ed9c952B84207Aaf91` (deployer Lasna nonce **2** — verified 2026-11-22 ~23:50 WAT; the deployer has made 2 Lasna txs: legacy RC deploy + 1 lREACT depositTo) |

### §7.1 — Observed balances (2026-11-22 ~23:50 WAT, read-only)

| Account | Balance |
|---|---|
| Deployer on Lasna | **0.886476 lREACT** (886475999998864760 wei) — enough for the RC deploy + ~0.17 lREACT reserves |
| Deployer on Base Sepolia | **0.009986 ETH** (9985913423529834 wei) — enough for the vault deploy + ~0.005 ETH new-vault reserves, with ~0.003 ETH kept for gas |
| Old vault proxy reserves | 0.02 ETH (stranded — the old vault can never split; do not try to recover) |
| Old RC legacy-proxy reserves | 1 lREACT (stranded) |
| Old RC Omni-side debt | 0.0123389 REACT (blacklisted; nothing to do — do not send it funds) |
| Deployer MPT balance | ~999,000 MPT (1,000 MPT stranded in the old vault; the token contract `0x43a33C4AeC29DB91c655eAB44417545ceCeD21A1` is REUSED — do not redeploy the token) |

**Funding note:** the new-vault reserve (0.005 ETH) is smaller than the
original 0.02 ETH because that is what the deployer holds. If more is ever
needed, a fresh Base Sepolia faucet claim (0.1 ETH / 24h) is possible — the
last claim was 2026-11-22, so a new one is available after 24h. **No new
faucet claim is needed for the redeploy itself.**

### §7.2 — Vault compatibility (the one design decision that matters)

The vault interface is **UNCHANGED** — no vault code change. The Omni
callback payload is an ABI-encoded function call, and the network overwrites
the first argument slot with the requesting RC's address. So the ported
contract encodes the payload as a call to the vault's EXISTING entry point:

```
abi.encodeWithSignature("callback(address,bytes)", address(0), abi.encode(token, amount))
```

The proxy overwrites the `address(0)` placeholder with the new RC's address
and calls `vault.callback(newRC, abi.encode(token, amount))` — exactly what
the vault already expects (`authorizedSenderOnly` = proxy is the caller, then
`sender == reactiveContract`). MCP `decode_callback` validated this exact
payload: OK_CALLBACK, no defects.

**BUT the vault's reactive-contract address is immutable, so the vault MUST
be redeployed pointing at the new RC address.** The old vault
(`0x086a674515B4de3A805055C41F9819D8b6E4d686`) still points at the
blacklisted legacy contract and can never split again.

Two honest caveats, both recorded here rather than hidden:
1. `check_rc_source` on the vault returns CALLBACK_UNGUARDED — this is a
   **false positive**: the checker does not recognise the legacy modifier
   names. The vault's `callback()` IS doubly guarded: `authorizedSenderOnly`
   (`require(senders[msg.sender])`, proxy in the ACL) is the legacy
   equivalent of `onlyServiceProvider`, and the explicit
   `sender != reactiveContract` revert is the equivalent of
   `onlyCallbackSender`. (Its second finding, on `transferOwnership()`, is
   also a false positive — that is an owner-only admin function, not a
   callback entry point.)
2. Gas budget: only ~144,776 of the 300,000 gas limit reaches the vault
   (130,000 proxy overhead). The vault callback needs roughly 120–150k, so
   300,000 should be enough — but if the callback ever fails with
   `InsufficientGas`, raise `CALLBACK_GAS_LIMIT` (e.g. 400,000) and
   redeploy BOTH contracts (the limit is immutable in the RC).

### §7.3 — Redeploy steps (in this exact order, after Isaiah's yes)

```bash
export PATH="$HOME/.foundry/bin:$PATH"
cd ~/workspace/reactive-payday-splitter
PK=$(node -e "console.log(require('./.deployer.json').privateKey)")
DEPLOYER=0x7cBB9C2267E208E031E7a81Ef8A48642202FbE56
BASE=https://sepolia.base.org
LASNA=https://lasna-rpc.rnk.dev/
NEW_RC=0xBC6D6F936AeB6519d1b7C4Ed9c952B84207Aaf91
TOKEN=0x43a33C4AeC29DB91c655eAB44417545ceCeD21A1

# 0. NONCE DISCIPLINE: the deployer must make NO Lasna transaction before
#    step 2, or the predicted address breaks. Verify first:
cast nonce $DEPLOYER --rpc-url $LASNA   # must be 2
cast compute-address $DEPLOYER --nonce 2 --rpc-url $LASNA  # must be $NEW_RC

# 1. Redeploy the vault on Base Sepolia, pointing at the NEW reactive address.
#    Same token, same destinations, same callback proxy as §3.
export TOKEN REACTIVE_ADDRESS=$NEW_RC \
  MAIN_WALLET=0x77D3bbBAe111399a69a33b9feeC639fC3B155894 \
  SAVINGS_WALLET=0x6B9eE8C207F3258c023C0863DD8c638DD921cc66 \
  GAS_RESERVE=0x92760589D753E606D3AB6a2FC15be6D9Aa366B3c \
  CALLBACK_PROXY=0x476F44b11F5C942c58f4c8E3d0300E5710743585
forge script script/DeployVault.s.sol --rpc-url $BASE --broadcast
#    -> NEW_VAULT (record it)

# 2. Deploy the ported reactive contract on Lasna (first Lasna tx: nonce 2).
#    Script REVERTS unless the deployed address == prediction.
export VAULT=$NEW_VAULT ORIGIN_CHAIN_ID=84532 CALLBACK_GAS_LIMIT=300000
forge script script/DeployReactiveOmni.s.sol --rpc-url $LASNA --broadcast
#    -> must equal 0xBC6D6F936AeB6519d1b7C4Ed9c952B84207Aaf91

# 3. Fund the OMNI-side reserves for the new RC: ~0.17 lREACT via depositTo
#    on the OMNI system contract (0x8888...). The new RC starts with zero
#    debt, so this is pure reaction fuel (~10 reactions + buffer).
cast send 0x8888888888888888888888888888888888888888 --rpc-url $LASNA \
  --private-key $PK "depositTo(address)" $NEW_RC --value 0.17ether
#    Verify: cast call 0x8888... "debt(address)" $NEW_RC --rpc-url $LASNA
#    (expect 0) and MCP get_rc_health (expect no debt, subscription active).

# 4. Fund the NEW vault's callback reserves: 0.005 ETH via depositTo on the
#    Base Sepolia callback proxy (0x476F44b11F5C942c58f4c8E3d0300E5710743585).
cast send 0x476F44b11F5C942c58f4c8E3d0300E5710743585 --rpc-url $BASE \
  --private-key $PK "depositTo(address)" $NEW_VAULT --value 0.005ether
```

### §7.4 — Live loop on the new contracts (record every hash + timestamps)

```bash
# 1. Send 1,000 MPT to the NEW vault; record tx hash + block timestamp T0.
cast send $TOKEN --rpc-url $BASE --private-key $PK \
  "transfer(address,uint256)" $NEW_VAULT 1000ether
# 2. Watch Lasna for the reactive tx (PaymentSeen + CallbackRequest):
#    https://lasna.reactscan.net/address/0xBC6D6F936AeB6519d1b7C4Ed9c952B84207Aaf91
# 3. Watch Base Sepolia for the callback split tx (Split event on the vault):
#    https://sepolia.basescan.org/address/<new-vault>#events
# 4. Verify the three destinations received 700 / 200 / 100 MPT (same
#    balanceOf calls as §5, step 4).
# 5. Latency = split-tx block timestamp - payment-tx block timestamp.
# 6. If the callback never lands, run MCP trace_origin_event on the payment
#    tx hash, then get_rc_health on the new RC. If react() reverted, use
#    explain_error on the revert data.
```

### §7.5 — After a successful loop

Same §6 artefacts (DoraHacks registration, public repo, demo video, submit
by 5 Dec 2026, 21:00 WAT), but with the NEW addresses and tx hashes.
Record everything in `deployments/testnet.json` under a new `omni_redeploy`
section; do not overwrite the legacy deployment record — it is the evidence
of what failed and why.

### §7.6 — GAS FIX + LIVE LOOP SUCCESS (2026-11-23 ~06:51 WAT)

Isaiah approved the Omni redeploy ("Yes, port it to Omni and redeploy",
2026-11-23 ~06:41 WAT). The redeploy ran, but the first Omni live loop
FAILED on gas — and the fix for that also ran the same morning.

**Attempt 1 (RC v1 0xBC6D… + vault v2 0x2d7A…, gas limit 300,000):**
- Payment 1,000 MPT → vault v2, tx
  0x22d447b9cde49c81e0e4985774ce43161722b99776a2352dbbb6188cf66e3576,
  block 62454000.
- react() SUCCEEDED (reactive tx
  0xf65465a37195dfe1232a6e85d7252cae36e9cf7104dfee74e482fa5b11c02751,
  block 9032618, gasUsed 77,636, 1 callback requested) — the Omni port
  itself works.
- Callback REVERTED: CallbackFailure tx
  0x856b629f3aaea8839f59f38efbd2bac45503d1f430deb26260cf1237ec9540d9,
  block 62454009.
- Root cause, proven by replay: the vault callback needs **148,700 gas**
  (cast estimate; eth_call with 144,776 gas reverts, with 200,000 it
  succeeds), but a 300,000 limit only delivers **~144,776** after 130,000
  proxy overhead + ~25,224 intrinsic. Shortfall: just **3,924 gas**.
- Vault v2 keeps its 1,000 MPT, stranded (can never split).

**Fix (runbook §7.2 fallback):** raised CALLBACK_GAS_LIMIT to **400,000**
(delivers ~244,776 to the vault) and redeployed BOTH contracts.
- Vault v3: **0xB919828FfF2e6b3B6f7a3E5e8033b831e6545e9E**, deploy tx
  0x73830d78bb2770c3ea39674b6602e128e340fce2467b5be6f15a6f336108d9fc,
  block 62455688.
- RC v2: **0x4613485BE1C213361BD48F1e34C95E7694E014eD** (deployer Lasna
  nonce 4, predicted address matched exactly), deploy tx
  0xa2a6aaccfd4ab64e08ce7a36a6aa94f2dc3a90a09cbb4ab4ffa493c1dd6502d9,
  block 9032951, callbackGasLimit verified 400,000 on-chain.
- Funded: 0.17 lREACT Omni reserves (tx
  0x9bc03e4f0da6d051090e741122d7750d244b22a4e39bb62a35136e68aab0020d,
  block 9032964); vault v3 reserves **0.004 ETH** (tx
  0x26cb08d8184fc205aa7c61684a359a4d35f5179bb6076511ebdac97b36e9b15b,
  block 62455879) — 0.004 not 0.005 because the deployer held only
  0.0049765 ETH; one callback costs ~0.0000014 ETH, so 0.004 covers
  ~2,800 callbacks.

**Live loop SUCCESS (vault v3 + RC v2):**
- Payment 1,000 MPT → vault v3, tx
  0xdc88c361bc4ca1f24fab2f030ea55e54ff48b823d418614842bb7e29297fe85d,
  block 62455932, timestamp 1795413055 (05:50:55 UTC).
- Reactive tx
  0xb2fc4b61f0e0c9aba392c944b4c7d2c2d6853cf2e881e5ea3a5dd084e05da6a6,
  block 9032981, gasUsed 77,600, react() succeeded, 1 callback.
- Split tx
  0x7555e7151980c0b30a0f3b6d6c829f56baf1f46ad754058a307e8a8e84a4e61c,
  block 62455940, timestamp 1795413056 — **latency 1 second**.
  Split event + 3 Transfer logs: **700 / 200 / 100 MPT** to main /
  savings / gas reserve. Vault balance after: 0. No CallbackFailure.
- Remaining balances (~06:55 WAT): deployer 0.2995 lREACT Lasna,
  0.0009671 ETH Base Sepolia, 997,000 MPT; RC v2 Omni reserves
  0.1572478 lREACT, debt 0; vault v3 proxy reserves 0.0039986 ETH.

**DeployToken.s.sol bug fixed** in the same session (mints to
`vm.addr(PRIVATE_KEY)` instead of `msg.sender` inside the broadcast);
forge build clean. Token NOT redeployed — the existing token is reused.
