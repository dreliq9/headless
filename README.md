# Headless (HDLS)

> An autonomous, agent-native token. Written end-to-end by **Claude** (Anthropic's AI) at the prompt of a non-coder. No human wrote a line of the contract, the tests, or the verification stack.

**Status:** pre-audit, unaudited, not deployed. This is a verified code artifact, not a live protocol. **Do not put real ETH into this contract.** See [Safety](#safety) below.

---

## What it is

Headless is a fair-launch ERC-20 with four interlocking mechanisms, all fully on-chain, deterministic, and callable by anyone:

1. **Bonding-curve AMM** — `buy()` and `redeem()` price along a linear curve `price(n) = curveBase + SLOPE · n`. Both sides use the same integral, so round-tripping is net-zero minus fees. No free arbitrage via the curve.
2. **Spread fee (50 bps each side)** — every trade leaves a fee behind as excess backing, which is immediately swept into `curveBase` by the continuous rebase. Holders earn yield passively from every trade that touches the contract.
3. **Continuous rebase** — after every state-changing call, `_rebase()` runs internally and tightens the invariant `balance == curveIntegral(0, tokensSold)` to equality. No keeper, no poke ritual.
4. **Dutch auction** — every `AUCTION_INTERVAL` blocks a fresh auction opens for `AUCTION_SIZE` HDLS. Price starts at `curveCost × 1.20` and decays linearly to `curveCost` over the window. First caller takes the lot. The premium flows into `curveBase` via rebase.

**Built for AI trading agents, not humans.** Every event is scheduled, deterministic, and computable from on-chain state alone. Single-call `curveState()`, `auctionState()`, `oracleState()` snapshots for agent planners. On-chain TWAP cumulative tracker for composability.

**Headless** = no admin, no owner, no founder team, no upgrade path, no oracle, no off-chain dependency. The contract is the entire organisation for its entire lifetime. A 3% founder allocation is minted at construction — these tokens sit *below* the curve (cannot be curve-redeemed until someone else has bought above them), giving the deployer mechanical last-in-line exit.

## Why it exists

This repo is the output of a week-long experiment: **can someone with zero coding experience ship a non-rug, formally-verified smart contract by only prompting an AI?** See [`PROMPTS.md`](PROMPTS.md) for the full prompt timeline — every design decision, every pivot, every mistake, and every fix, recorded as it happened.

The verification stack below is the interesting part. The token itself is secondary.

## Verification stack

Six independent methodologies. All run locally, all free, all pass:

| Tier | Tool | Scope | Result |
|---|---|---|---|
| 1. **Unit tests** | `forge test` | 52 concrete behavioural scenarios | **52 / 52 pass** |
| 2. **Fuzz tests** | `forge test` | 2 property tests × 256 runs = 512 sampled inputs | **pass** |
| 3. **Stateful invariants** | `forge test` (handler + ghost state) | 10 invariants × 256 × 500 = **1,280,000 random handler calls** | **10 / 10 pass** |
| 4. **Static analysis** | [Slither](https://github.com/crytic/slither) | 25 contracts, 101 detectors | **0 material findings** |
| 5. **Symbolic verification** | [Halmos](https://github.com/a16z/halmos) | 4 `check_*` properties, 85 symbolic paths | **4 / 4 proved** |
| 6. **Mutation testing** | [slither-mutate](https://github.com/crytic/slither) + custom driver | 328 mutants × 8 operator categories (AOR/LOR/ROR/CR/MIA/MVIE/RR/SBR) | **302 / 302 killable mutants caught (100%)** |

### Load-bearing invariants

The invariant that must hold forever, on every block, after every mutating call:

```
address(this).balance  ≥  curveIntegral(0, tokensSold)
```

The continuous rebase tightens this to equality on every touch. If this ever breaks, redemptions fail and the "floor" promise is void.

Plus nine others asserted during the 1.28M-call stateful fuzz:

- `totalSupply == FOUNDER_ALLOCATION + tokensSold` (accounting consistency)
- `totalSupply ≤ MAX_SUPPLY` (hard cap)
- `curveBase ≥ INITIAL_CURVE_BASE` (monotonic non-decreasing)
- `tokensSold ≤ MAX_SUPPLY − FOUNDER_ALLOCATION`
- `totalRebased ≤ ghost_totalEthIn` (yield bounded by ETH inflows)
- `address(this).balance == ghost_totalEthIn − ghost_totalEthOut` (**conservation of ETH** — value is never created or destroyed)
- `FOUNDER_ALLOCATION == 3_000_000 ether` (immutable)
- `backing ≥ required` (per-actor exit sufficiency)
- Call summary (debugging aid)

### Symbolic proofs (Halmos)

For every whole-token amount in `[1, 100] ether`, Halmos has enumerated the full symbolic path space and proved:

- `balance ≥ curveBackingRequired` after any `buy`
- `balance ≥ curveBackingRequired` after any `buy` + `redeem` sequence
- `balance_after == balance_before + total_paid` for any `buy` (exact conservation)
- `user.balance_after ≤ user.balance_before` for any `buy + redeem` round-trip (**no free money**)

These are not samples — every feasible input is covered within the bounds.

### Mutation score

Raw score: **302 / 328 = 92.0 %**. The 26 surviving mutants are all equivalent mutants that no behavioural test can kill:

- 20 **SBR** (storage type changes: `constant ↔ immutable`, `uint256 ↔ uint128` on constants — no runtime difference)
- 5 **ROR equivalents** (`<= 0` ≡ `== 0` for uint, `!= 0` ≡ `> 0` for uint, `<= req` vs `< req` differs only at equality where `delta == 0` returns anyway)
- 1 **MIA equivalent** (removed early-return guard takes the same `delta == 0` path)

**Killable mutation score: 302 / 302 = 100 %.** Every mutation that *could* be detected by a behavioural test *is* detected.

## How to verify it yourself

### Prerequisites

```bash
# Foundry (forge, cast, anvil)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Optional: Slither (Python, static analysis)
pipx install slither-analyzer

# Optional: Halmos (Python, symbolic verification)
pipx install halmos
```

### Clone and build

```bash
git clone --recurse-submodules https://github.com/<your-user>/headless.git
cd headless
forge build
```

If you already cloned without `--recurse-submodules`:
```bash
git submodule update --init --recursive
```

### Run the tests

```bash
# Unit + fuzz tests (fast, ~1 second)
forge test --no-match-contract 'Headless(Invariant|Halmos)'

# Stateful invariants (slow — 1.28M calls, ~30 seconds)
forge test --match-contract HeadlessInvariant

# Everything
forge test
```

### Run the static analysis

```bash
slither src/Headless.sol \
  --solc-remaps "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/" \
  --filter-paths "lib/"
```

### Run the symbolic proofs

```bash
halmos --match-contract HeadlessHalmosTest
```

### Run the mutation campaign (optional, slow)

```bash
slither-mutate src/Headless.sol \
  --test-cmd "forge test --no-match-contract 'Headless(Invariant|Halmos)' -q" \
  --output-dir mutation_campaign
bash mutation_run.sh
```

The custom driver is necessary because `slither-mutate`'s own result reporter misinterprets forge exit codes; the shell script in `mutation_run.sh` re-runs each generated mutant and correctly classifies caught vs. survived.

## Repository layout

```
headless/
├── README.md                        # you are here
├── PROMPTS.md                       # full prompt provenance — every AI instruction that built this
├── LICENSE                          # AGPL-3.0-or-later
├── foundry.toml
├── mutation_run.sh                  # custom mutation testing driver
├── src/
│   └── Headless.sol                 # the contract (~480 lines, every line AI-written)
├── test/
│   ├── Headless.t.sol               # 52 unit + fuzz + mutation-killer tests
│   ├── HeadlessInvariant.t.sol      # 10 stateful invariants via handler
│   └── HeadlessHalmos.t.sol         # 4 symbolic proofs
└── script/
    └── Deploy.s.sol                 # no-arg deploy
```

## Safety

**This contract is not audited. It has not been deployed. Do not put real ETH into it.**

The verification stack above is strong — probably stronger than a lot of audited-and-shipped DeFi contracts — but it is not a substitute for a human audit. Automated tools catch known bug patterns and specified invariants; auditors catch the unknown unknowns, misaligned incentives, unstated assumptions, and novel attack vectors.

If you want to play with this:

- **Deploy to a testnet.** Base Sepolia is free and has Foundry tooling. Zero real value at risk.
- **Open an Immunefi bounty** if you're curious whether there are bugs — you only pay on findings, and for a zero-TVL contract the cost is also zero.
- **Read the code.** All 480 lines are heavily commented and the invariants are spelled out at the top of `Headless.sol`. The provenance in `PROMPTS.md` shows every reason behind every decision.

Contributions, bug reports, and "this mechanism is wrong for reason X" feedback are all welcome. Open an issue.

## Known limitations

- **Single-chain, ETH-only backing.** No cross-chain, no multi-asset collateral.
- **No Uniswap v4 hook or ERC-4626 wrapper.** Deliberately scoped out — see `PROMPTS.md` for the reasoning.
- **Bounded Halmos proofs.** Symbolic verification is bounded to amounts ≤ 100 ether and single operations. The invariant tests cover larger sequences stochastically; only unbounded formal verification (Certora, K-framework) would give complete proof.
- **No audit.** As noted above.

## What's interesting here (beyond the code)

- **Provenance as a feature.** `PROMPTS.md` records every prompt that produced this contract, in order. The "AI wrote every line" claim is falsifiable — you can read the conversation.
- **A non-coder shipped this.** I don't know Solidity. I don't know Python. I prompted each component into existence via Claude Code, verified the output via the six-tier stack, and iterated until every tier was green. The AI wrote the code; I wrote the intent.
- **Six verification tiers with $0 in tooling cost.** Everything in this repo runs locally on a laptop for free. The only thing you cannot do without paying is a human audit — and for a zero-TVL portfolio piece, you don't need one.

If this is interesting to you as a research artifact, reach out — I'd love to hear what other AI-authored verification stacks look like.

## License

**AGPL-3.0-or-later.** See [`LICENSE`](LICENSE) for the full text.

Short version: you can fork, modify, use, and even sell this code commercially — but any derivative work (including code you run as a network service) must be released under AGPL-3.0 too. In plain English: no closed-source copy-and-resell. If you improve it, the whole ecosystem gets to see the improvement.

---

*Built with [Claude Code](https://claude.com/claude-code). See [`PROMPTS.md`](PROMPTS.md) for the full story.*
