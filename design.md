# Payday Splitter — Reactive Omni Buildathon idea (Set It and Forget It)

Prepared 2026-11-22 ~20:40 WAT, for Isaiah's decision. Nothing built yet — no repo,
no contracts, no registration. A yes starts the build; a no kills it with nothing spent.

## The idea in one line

Every payment that lands in his agent vault is automatically split by a Reactive
contract — no bot, no manual move, fixed verified destinations.

## Why this one

- It is a real automation he would leave running. He receives payments across
  several EVM wallets and moves them by hand. On 2026-10-31 a manual move sent
  steve54's full 11,250 IAO to the wrong wallet (0x8c67fD2AEf905B3d4dc21D6C78625Df187C27879).
  Fixed destinations set once at deploy remove that whole class of mistake.
- His agent wallets repeatedly hit zero-balance blocks (QDay deployer holds 0 tQDAY;
  LastCall wallet holds 0.0027 OKB). A fixed gas-reserve share keeps a reserve
  topped up automatically.
- It fits the track's own test, from the Reactive brief: "is this something you'd
  actually leave running?" Usefulness beats speed here, and no latency race is needed.

## How it works (technically sound on the Reactive docs)

Two new contracts, built during the event:

1. **SplitterVault, on Base Sepolia** — the agent's receiving address. It holds
   incoming ERC-20 payments and exposes a split function callable only via a
   Reactive callback.
2. **PaydayReactive, on Reactive Lasna (chain 5318007)** — subscribes to that
   token's `Transfer` events filtered to the vault as recipient (topic 0 = Transfer,
   topic 2 = vault address). On each event, `react()` parses the amount and
   requests a callback to the vault, which splits it by fixed shares.

Default shares (owner-settable): 70% main wallet / 20% savings wallet / 10% gas
reserve. Destinations are fixed at deploy.

Full loop, demoable end to end: send test tokens to the vault on Base Sepolia →
Reactive sees the Transfer → callback splits on Base Sepolia → three outgoing
transfers on-chain, with end-to-end latency measured. That is exactly what judging
requires: reactive transactions and the callbacks they trigger, on-chain.

## Why it scores (judging: Execution / Integration / Usefulness / Craft, 1–5 each)

- Execution: real reactive txs + callbacks, no simulation.
- Integration: without Reactive nothing splits — the vault cannot trigger itself.
- Usefulness: real money routing for a multi-wallet agent operator.
- Craft: two small readable contracts, public repo, demo video under 3 minutes.

## Facts (verified 2026-11-22)

- Buildathon: Reactive Omni, 5 Nov – 5 Dec 2026, closes Sat 5 Dec 20:00 UTC
  (21:00 WAT). Source: DoraHacks page, https://dorahacks.io/hackathon/reactive-omni-buildathon/detail
  (crawled 2026-11-06), and the Reactive blog post Isaiah pasted.
- Track: Set It and Forget It — 1st $2,000, runner-up $250, paid in REACT
  (a token, not dollars — value can move, cashing out is extra work).
- Submission needs: public repo, deployed contract addresses, tx hashes showing
  the full loop from origin event to callback, demo video under 3 minutes.
- Ground rule: everything built during the event; prior work can be a dependency,
  not the submission itself. These two contracts are new code.
- Cost: $0 real money. Lasna testnet + Base/Unichain Sepolia; testnet REACT from
  the Lasna faucet. No mainnet, no real funds.
- Registration is on DoraHacks — he already has an account there (Delphi, QDay).
- No country restriction was visible on the DoraHacks page I read; not separately
  verified for Nigeria.

## The trade-off (honest)

His week is already full: Delphi opens Mon 23 Nov, Motion post due Tue 24 Nov,
HybridAI closes Mon 30 Nov, Tari due Tue 1 Dec, Kiroween grant due Tue 1 Dec,
Kiroween submission Fri 4 Dec. The realistic build window for this is 2–4 Dec,
alongside the Kiroween submission. That means it displaces something — the
weakest live build is HybridAI (Demo mode, Firebase unconnected, Devpost
registration paused since 16 Nov) — or it waits until Kiroween is submitted early.
Do not start it before he picks what gives way.

## Build plan if he says yes

1. Register on DoraHacks, pick Set It and Forget It.
2. SplitterVault + PaydayReactive contracts, Foundry tests, deploy to Base Sepolia
   + Lasna testnet.
3. Run the loop live, record tx hashes + latency, small frontend (set shares,
   show splits).
4. Demo video under 3 minutes (he posts videos himself — Everest scripts it).
5. Submit by 5 Dec 21:00 WAT.

## Fallback, not recommended

A Reactive port of his LastCall dead-man's switch: the design is done and proven
(90-day check-in, 14-day challenge), and the TapeOut version is stalled on a
~0.02 OKB mainnet fee. But it is a port of prior work, and the ground rule bars
prior work as the submission itself. The Splitter is the cleaner entry.
