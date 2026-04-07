# Headless (HDLS)

[![verify](https://github.com/dreliq9/headless/actions/workflows/verify.yml/badge.svg)](https://github.com/dreliq9/headless/actions/workflows/verify.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)

> A one-week experiment in AI-authored smart contract development and the verification gaps of AI-driven verification. Every line of the contract, the tests, and the verification stack was written by **Claude** (Anthropic's AI) at the prompt of a non-coder. The interesting artifact is not the token — it's the gap a six-tier verification stack didn't catch.

**Status:** unaudited, never deployed, never will be by me. This repository is a research artifact and a case study, not a live protocol. **Do not put real ETH into this contract.** See [Safety](#safety).

---

## What this repository actually is

A bonding-curve ERC-20 was the *vehicle*. The thing worth your attention is everything around it:

1. A non-coder directed an AI to design and implement a non-trivial Solidity contract end-to-end. ([`PROMPTS.md`](PROMPTS.md) records the entire prompt timeline that produced it.)
2. The same AI (in a separate session) built a six-tier verification stack against the contract: 54 unit tests, 2 fuzz properties, 10 stateful invariants × 1.28M handler calls, Slither static analysis, 4 Halmos symbolic proofs, 302/302 killable mutants caught.
3. **Every tier passed.** The contract was claimed to be "non-rug, formally verified."
4. A subsequent **3-evaluator adversarial review** (also AI, in a fresh session, with no shared state) found a critical bug that would have allowed the deployer to drain every buyer's deposit in a single transaction.
5. The same review session designed the fix, wrote the regression tests, identified the structural reason every prior tier missed the bug, and patched four moderate findings on top.

The bug fix is in [PR #1](https://github.com/dreliq9/headless/pull/1). The story arc — *six tiers of automated verification rubber-stamped a contract that was trivially exploitable, and a separate adversarial AI session caught it on the first pass* — is the actual finding of this experiment.

If you only have time to read one thing in this repo, read [PR #1](https://github.com/dreliq9/headless/pull/1).

## The contract (briefly)

Headless is a fair-launch ERC-20 with four mechanisms, all deterministic and on-chain:

1. **Bonding-curve AMM.** `buy()` and `redeem()` price along a linear curve `price(n) = curveBase + SLOPE · n`. Both sides use the same integral, so round-tripping is net-zero minus fees.
2. **Spread fee (50 bps each side).** Every trade leaves a fee behind as excess backing, immediately swept into `curveBase` by the continuous rebase. Holders earn passive yield from every trade.
3. **Continuous rebase.** After every state-changing call, `_rebase()` tightens the invariant `balance == curveIntegral(0, tokensSold)` to equality. No keeper.
4. **Dutch auction.** Every `AUCTION_INTERVAL` blocks a fresh auction opens for `AUCTION_SIZE` HDLS. Price decays linearly from a 20% premium to the curve floor. Premium flows into `curveBase`.

No admin, no owner, no upgrade path, no oracle, no off-chain dependency. A 3% founder allocation is minted at construction; after the fix in [PR #1](https://github.com/dreliq9/headless/pull/1), it is taint-locked at the token level so the founder cannot redeem against it.

This is a deployable Solidity artifact. It is not a token I am offering for sale or use.

---

## The historical critical finding

> The README originally claimed: *"The founder is mechanically last in line on exit — a hard lock enforced by the `tokensSold` counter, not by a flag."*
>
> This was materially false until [PR #1](https://github.com/dreliq9/headless/pull/1).

### The bug

`redeem()` had only two guards:

```solidity
if (balanceOf(msg.sender) < amount) revert InsufficientBalance();
if (amount > tokensSold)             revert InsufficientCurveSupply();
```

Neither guard distinguished founder-pre-mined tokens from buyer tokens. Both balance types were fungible ERC-20. The attack:

1. Deployer holds 3,000,000 HDLS from construction. `tokensSold = 0`.
2. Alice calls `buy(100 ether)`, deposits ≈ `_curveIntegral(0,100) + fee`. `tokensSold = 100`.
3. Founder calls `redeem(100)`. Both guards pass (founder has 3M ≥ 100; 100 ≤ tokensSold).
4. `_burn` decrements founder's 3M by 100. `tokensSold → 0`. Refund (≈ Alice's payment − fees) is sent to **the founder**.
5. Alice still holds 100 HDLS, but her next `redeem` reverts `InsufficientCurveSupply` because `tokensSold == 0`. Her tokens are stranded.

The founder could repeat this against every buyer until the 3M allocation was exhausted, capturing roughly the entire curve-paid-in ETH at no risk to themselves. The "fair launch, no rug" framing was structurally false.

### Why every tier of the verification stack missed it

| Tier | Why it greenlit the bug |
|---|---|
| **Unit tests** | A test named `test_FounderCannotRedeemBelowBaseline` *demonstrated the exploit succeeding* — alice buys, founder transfers 3M to bob, bob calls `redeem` against alice's deposit, the call returns success. The test then asserted only that bob couldn't redeem *more*. Reading the name, you'd conclude the founder was locked out. The author had tested the wrong property and confidently named the test for what they thought they had tested. |
| **Stateful invariants (1.28M handler calls)** | The actor set was 5 keccak-derived addresses; the founder was `address(this)` and never participated in fuzzing. The one invariant that *should* have caught it (`invariant_EveryActorCanExitToPoolRoom`) had a stub body that re-asserted the aggregate `balance ≥ curveBackingRequired` check. After a successful drain, the aggregate check holds **vacuously** because `tokensSold = 0` and therefore `required = 0`. |
| **Halmos symbolic proofs** | All four `check_*` functions used a single symbolic actor. The founder-buyer ordering bug requires *two* actors with different taint state. Halmos cannot construct an attack it has no symbolic variable to express. |
| **Slither static analysis** | This is a control-flow / pattern detector. The bug is a higher-order property of the economic model, not a code-level antipattern. Slither was never going to find it. |
| **Mutation testing (302/302 killable)** | Mutation testing measures whether the test suite catches small code modifications. It cannot detect missing tests for properties no one specified. Every mutation was caught by the same flawed test that celebrated the exploit. |

The structural failure is consistent across every tier: **the verification stack tested the properties someone wrote down, and nobody wrote down "no actor may take ETH that backs another actor's tokens."** The aggregate invariant is necessary but not sufficient — per-holder solvency is the load-bearing property and was never asserted.

### How a separate AI session found it on the first pass

The author ran an adversarial 3-evaluator review using a different AI session with no access to the build conversation. Each evaluator was given the contract and the README's claims about it, and asked to find places where the code did not match the prose. All three evaluators independently identified the same critical bug, traced the same exact attack path, and pointed at the same lines of code (`Headless.sol:148` mint, `:302-327` redeem). All three graded the contract `D`. None of the prior six tiers had flagged it.

The methodological lesson is uncomfortable: **"the same AI built the contract and the tests, both confidently wrong about the same thing."** A second AI session, asked to argue *against* the artifact rather than verify it, was more useful than the entire automated stack.

### The fix

[PR #1](https://github.com/dreliq9/headless/pull/1) introduces:

- A per-address `founderTaint` mapping initialized at construction.
- An `_update` override that propagates taint proportionally on every transfer (rounded up for stickiness, capped at sender's taint). Burns and mints leave taint alone.
- A new `redeem` precondition: `balanceOf(msg.sender) - amount >= founderTaint[msg.sender]`. The founder cannot burn any token that originated in their pre-mine, even if routed through fresh addresses.
- The previously-stub `invariant_EveryActorCanExitToPoolRoom` rewritten as a real per-holder check: for every actor, taint ≤ balance, and `Σ(balance − taint) == tokensSold`. The founder is now actor 0 of the handler.
- Four moderate findings also fixed: half-open auction window (closes the zero-fee floor block), `tokensSold > 0` gate on the first auction (closes the deploy-block self-rebate), constructor-immutable auction parameters (closes the L1-only block-time assumption), `twapCurveBase` input validation, `Donated` event in `receive()`.

After the fix:

| Tier | Result |
|---|---|
| Unit + fuzz | 58 / 58 pass (was 54: +4 founder regression tests, +1 close-block expiry test, −1 misleading test removed) |
| Stateful invariants | 10 / 10 pass × 256 runs × 500 handler calls = 1.28M (founder is actor 0; per-holder solvency invariant) |
| Halmos symbolic | 4 / 4 pass |
| Slither | unchanged |

The bug was fixable. The methodological gap is more interesting than the bug.

---

## Verification stack (pre-fix description, kept for the case study)

Six methodologies, all run locally, all free, all originally green:

| Tier | Tool | Scope | Result |
|---|---|---|---|
| 1. **Unit tests** | `forge test` | concrete behavioural scenarios | 54 → 58 passing post-fix |
| 2. **Fuzz tests** | `forge test` | 2 property tests × 256 runs | pass |
| 3. **Stateful invariants** | `forge test` (handler + ghost state) | 10 invariants × 256 × 500 = 1.28M random handler calls | 10 / 10 pass |
| 4. **Static analysis** | [Slither](https://github.com/crytic/slither) | 25 contracts, 101 detectors | 0 material findings |
| 5. **Symbolic verification** | [Halmos](https://github.com/a16z/halmos) | 4 `check_*` properties, 86 symbolic paths | 4 / 4 proved within bounds |
| 6. **Mutation testing** | [slither-mutate](https://github.com/crytic/slither) + custom driver | 328 mutants × 8 operator categories | 302 / 302 killable mutants caught (100%) |

### Bounds and disclosures the original README didn't make explicit

- **Halmos proofs are bounded**: every `check_*` constrains `amount ≤ 100 ether` and operates on a single symbolic actor. The slope-dominated regime (large amounts) and the multi-actor regime (any property requiring two distinct callers) are unverified by Halmos. The founder-drain bug lives in the multi-actor regime — Halmos *cannot express it*, not "missed it."
- **Mutation testing measures coverage of the existing test suite, not coverage of the specification.** A test suite that asserts the wrong property will catch every mutation that contradicts the wrong property. 100% killable does not mean 100% correct; it means consistent.
- **The stateful fuzz handler is part of the test surface.** The actor set, the action selectors, and the ghost-variable definitions are all decisions the author makes. None of them caught the founder case until [PR #1](https://github.com/dreliq9/headless/pull/1) added the founder as actor 0 and rewrote the per-holder invariant.
- **Block-time sensitivity.** The original `AUCTION_INTERVAL = AUCTION_WINDOW = 25` constants assume Ethereum L1 timing (~5 minute cadence). On Base (~2 s blocks) the same constants give ~50 second auctions, which is a sniping market. PR #1 makes both constructor parameters with validation.

### The load-bearing invariant

```
address(this).balance ≥ curveIntegral(0, tokensSold)
```

True before [PR #1](https://github.com/dreliq9/headless/pull/1), still true after. **And insufficient.** It holds vacuously after a founder drain (`required = 0`). The per-holder version added in PR #1 is the actual safety property:

```
∀ actor a:  balanceOf(a) − founderTaint(a) ≥ 0
Σ_a (balanceOf(a) − founderTaint(a)) == tokensSold
address(this).balance ≥ curveBackingRequired()
```

If the global invariant alone had been the only safety property of this contract, the bug would have been undetectable. Per-holder solvency is the primitive that should have been written down on day one.

---

## What v2 should look like (open design space)

This section is forward-looking — design notes for anyone (you, me, someone else) who might pick this artifact up and build the next iteration. Ranked by how strongly I'd argue for each.

1. **Sub-whole-token denomination.** v1 enforces `amount % 1 ether == 0`. This is a convenience for the curve integral, not a property users want. It rules out micropayments — an agent that wants to pay 0.001 HDLS for a tool call literally cannot. For an "agent-native" token this is the largest UX gap. v2 should drop the restriction and accept the slightly messier integral.
2. **Slippage-bounded primitives.** Ship `buyWithMaxPayment(amount, maxETH)` and `redeemWithMinRefund(amount, minETH)` as first-class. Every agent that integrates v1 will re-implement these.
3. **Commit-reveal auction instead of first-caller-wins.** First-caller Dutch auctions are a gas war that selects for fastest-RPC infrastructure rather than economic signal. A commit-reveal scheme over two phases lets agents bid honestly without front-running.
4. **`simulate(action, params)` view.** Returns the post-trade state without mutating, so an agent can plan chains of actions in a single RPC call.
5. **Proof-of-reserves as an explicit API.** v1 exposes the invariant implicitly via `curveBackingRequired() ≤ address(this).balance`. v2 should expose `proofOfReserves() returns (uint256 backing, uint256 required, bool solvent, uint256 excessPerToken)` so agents do not have to derive solvency from primitives.
6. **`maxBuyForSlippage(bps)` view.** "How much can I buy in a single tx without moving the price by more than X bps?" Derivable from curve math today; should be a one-call view.
7. **Per-actor solvency as a load-bearing invariant from day one**, not bolted on after a critical finding. This is a methodology change, not a code change: write down what each holder is owed before writing the code that owes it to them.
8. **Adversarial review as a verification tier.** Every project that uses an automated verification stack should also schedule at least one separate AI session whose only job is to argue *against* the artifact's claims. The 3-evaluator pattern in PR #1's history is the cheapest tier in the stack and was the only one that found the critical bug.

These are not improvements I plan to make. They are notes for whoever does.

---

## How to verify what's here yourself

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
git clone --recurse-submodules https://github.com/dreliq9/headless.git
cd headless
forge build
```

### Run the tests

```bash
# Unit + fuzz tests (fast)
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

### Reproduce the historical bug

To see the original bug at the original commit, check out the parent of PR #1 and run:

```bash
git checkout f1d793c~1   # parent of the fix commit
forge test --match-test test_FounderCannotRedeemBelowBaseline -vv
```

You will see the test pass while the founder successfully drains alice's deposit. That's the methodological finding in one command.

---

## Repository layout

```
headless/
├── README.md                        # you are here
├── PROMPTS.md                       # full prompt provenance — every AI instruction that built this
├── LICENSE                          # AGPL-3.0-or-later
├── foundry.toml
├── mutation_run.sh                  # custom mutation testing driver
├── src/
│   └── Headless.sol                 # the contract
├── test/
│   ├── Headless.t.sol               # unit + fuzz + mutation-killer + founder regression tests
│   ├── HeadlessInvariant.t.sol      # 10 stateful invariants via handler (founder is actor 0)
│   └── HeadlessHalmos.t.sol         # 4 symbolic proofs
└── script/
    └── Deploy.s.sol                 # deploy script with auction-cadence parameters
```

## Safety

**This contract is unaudited and not deployed. Do not put real ETH into it.**

The verification stack documented above caught one critical bug only after a separate AI session was specifically asked to argue against the claims of the original session. The same stack failed to catch that bug when run end-to-end as a positive verification of the contract. Before this finding I would have said "the verification stack is probably stronger than most audited DeFi contracts." After this finding I would say "automated verification stacks of any depth catch the bugs you specify and miss the bugs you don't specify, and the gap between those two sets is exactly where you get exploited."

If you want to use this contract for anything beyond reading:

- **Deploy to a testnet.** Base Sepolia is free.
- **Read [PR #1](https://github.com/dreliq9/headless/pull/1) before reading any other claim in this README.** The verification stack and the "fair launch" framing were both materially wrong until that PR; the README around them is now caveated, not deleted.
- **Treat this as a research artifact, not a portfolio piece you put money into.**

Bug reports, "this mechanism is wrong because X" feedback, and methodological critique of the case study are all welcome.

## License

**AGPL-3.0-or-later.** See [`LICENSE`](LICENSE).

## Contact

Methodological critique, review requests, or questions about the case study: open an issue, or reach me at `headless@dreliq9.dev`.

---

*Built with [Claude Code](https://claude.com/claude-code). The build conversation is logged in [`PROMPTS.md`](PROMPTS.md). The adversarial review and fix conversation is the second half of the same file.*
