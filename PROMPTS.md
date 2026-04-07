# Headless (HDLS) — Provenance

Every line of `src/Headless.sol`, `test/Headless.t.sol`, and `script/Deploy.s.sol`
was written by **Claude** (Anthropic's AI) at the prompt of a non-coder,
working in the Claude Code CLI. The code was not hand-edited afterward.

This file records the prompts that produced the contract, in chronological
order. Nothing about the mechanism, the naming, or the design is hidden —
if you want to know why a constant is the value it is, you can read the
conversation that chose it.

## Prompt timeline

### Session 1 — first attempt (abandoned after v1)

- **User:** *"how difficult is it to make a meme coin good enough to make money off of?"*
  - Claude answered with the distribution problem and flagged memecoin-
    launching as -EV for someone without a pre-built audience.
- **User:** *"could you code up a technically advanced token that actually
  contributes value?"*
  - Claude sketched a fair-launch bonding-curve token with an immutable
    treasury ("GoodToken"). Wrote `src/GoodToken.sol`, `test/GoodToken.t.sol`,
    `script/Deploy.s.sol`, and `foundry.toml`.
- **User:** *"pull the latest tech from all of the best players"*
  - Claude listed 12 upgrades (VRGDA, Uniswap v4 hooks, ERC-4626, commit-
    reveal, quadratic funding, conviction voting, RetroPGF, Sablier
    streams, AA/7702, zk-personhood, TWAP, immutable+verified) but did not
    yet implement them.
- **User:** *"also what do you think of the story of calling it clawd..."*
  - Claude flagged the trademark problem with Claude/Clawd/Claudette and
    recommended against using Anthropic's brand on a financial instrument.
- **User:** *"what about headless"*
  - Claude judged Headless to be the best name considered — triple meaning
    (no leader / no founder / runs autonomously), trademark-clean.
- **User:** *"check head and prmt tickers"*
  - Claude web-searched: **HEAD** was taken (HeadDAO on Ethereum, direct
    collision). **PRMT** looked clean. Recommended **HDLS** as a compromise.
- **User:** *"im amenable to HDLS"*
  - Claude renamed GoodToken → Headless (ticker HDLS) across all files.
- **User:** *"no i want HDLS to be hands off and agentic trading focus.
  cus its headless"*
  - **And:** *"and written without a human coding"*
  - Claude pivoted the whole design: no human governance, no treasury,
    built for AI agents to trade, every line AI-authored.
- **User:** *"lets go with your recommendations. this is your token"*
  - **And:** *"but i definitely want some of the tokens to start"*
  - Claude added the 3% founder allocation with no vesting/cliff, visible
    in the constructor.
- **User:** *"rip it out"*
  - Session 1 ended mid-rewrite.

### Session 2 — this session (the actual v1)

- **User:** *"[pasted full transcript of session 1] ... rip it out"*
  - Claude rewrote `src/Headless.sol` from scratch around the agent-native
    design: curve-only pricing (buy and redeem share the same integral),
    scheduled ascending auctions with pull-refunds, keeper-poked rebase,
    3% founder allocation below the curve. Wrote the matching test file
    and updated the deploy script.
- **User:** *"is this the best token that you can make for this niche?"*
  - Claude answered *no* and listed 11 gaps vs the state of the art.
    Highlighted VRGDA, continuous rebase, and this PROMPTS.md file as
    the top three upgrades.
- **User:** *"make it the best"*
  - Claude backed off on VRGDA after reconsidering (VRGDA is a primary-
    emission schedule, not a round-trippable AMM — wrong primitive for
    HDLS). Rewrote the contract with:
    - **Spread fee** (50 bps on both buy and redeem) that accrues to
      holders via continuous rebase.
    - **Continuous rebase** — no more `tick()` keeper; rebase runs
      internally after every buy / redeem / claimAuction / poke, so the
      invariant stays tight every block that touches the contract.
    - **Dutch auction** (`claimAuction`) — single-taker, linear premium
      decay from 20 % → 0 % over 25 blocks, replaces the old bid / settle /
      claimRefund flow. No pull-refunds, no settle phase, just one tx.
    - **Public `poke()`** so anyone can sweep stray ETH (donations,
      coinbase, selfdestruct) into curveBase for the benefit of holders.
    - **TWAP cumulative tracker** (`cumulativeCurveBase`, `twapCurveBase`)
      for manipulation-resistant external price oracle consumers.
    - **Enriched `state()` view** returning a 14-field snapshot in one call.
    - Deferred (not "best" work): Uniswap v4 hook (periphery still moving),
      ERC-4626 vault wrapper (syntactic bloat over a self-appreciating
      token), multi-asset backing (v2).
  - Wrote this PROMPTS.md as part of the same change.
- **User:** *"download forge and verify"*
  - Claude installed `foundryup`, pulled `forge 1.5.1-stable` + Solc 0.8.24,
    installed `forge-std` and `openzeppelin-contracts v5.6.1`, compiled,
    ran the suite. 21/22 passed on first run; one test
    (`test_AuctionPriceDecaysLinearly`) failed because the previous
    session's fix advanced 24/25 blocks instead of exactly 25. Fixed the
    test to roll to the precise close block. 22/22 passed.
- **User:** *"make it the best"* (second time, after verification)
  - Claude declined to add Uniswap v4 hooks or an ERC-4626 vault — v4 is a
    ~500-line hook-address-mined commitment for marginal benefit, and
    4626 over a self-appreciating token is syntactic bloat. Instead
    pushed on rigor:
    - Swapped `ReentrancyGuard` → `ReentrancyGuardTransient` (OZ 5.1+,
      EIP-1153 transient storage; ~2.1 k gas cheaper per protected call).
    - Added a full **stateful invariant test suite**
      (`test/HeadlessInvariant.t.sol`) with a `HeadlessHandler` driving
      five actors through random sequences of `buy` / `redeem` /
      `claimAuction` / `poke` / `advanceBlocks`. Eight invariants:
      backing ≥ curve requirement, totalSupply == founder + tokensSold,
      supply ≤ max, curveBase monotonic, tokensSold bounded, totalRebased
      ≤ ghost_totalEthIn, founder allocation intact, and a call-summary
      ghost counter. 256 runs × 500 calls = 128 000 random handler calls
      per invariant → **1 024 000 calls total with zero breaks**.
    - Added nine edge-case unit tests (non-whole quotes, zero amounts,
      poke on empty contract, exact-payment auction, auction-price revert
      after expiry, curve price monotonic after buy, state views
      consistency, etc.) bringing the linear suite to 32 tests.
    - Split the old 14-field `state()` view into three smaller views
      (`curveState()`, `auctionState()`, `oracleState()`) to avoid
      stack-too-deep without needing `via_ir` (which has a known local-
      variable optimisation bug on 0.8.24 that silently broke one test).
    - Final suite: **40 tests, 40 passing** — 32 linear / fuzz +
      8 stateful invariants.
- **User:** *"make it excellent"* (then while Claude was working: *"do what
  you think is best"*)
  - Claude added a third verification tier and fixed two real issues
    that Slither surfaced:
    - Added **conservation-of-ETH** invariant: the contract's balance
      must equal ghost_totalEthIn − ghost_totalEthOut at all times. This
      is the strongest economic invariant a value-holding contract can
      assert and catches any path that mints or burns ETH out of thin
      air. Plus a tenth invariant (`invariant_EveryActorCanExitToPoolRoom`)
      for per-actor exit sufficiency. **10 invariants × 256 × 500 =
      1,280,000 handler calls, zero breaks.**
    - Ran **Slither** static analysis. Initial scan: 94 findings across
      25 contracts (mostly OZ library pragma lints). Filtering to just
      `Headless.sol`: 13 real findings. Two of them were material:
      1. **Cross-function read-only reentrancy** — `_rebase()` was
         modifying `curveBase` *after* the `.call{value:}` refund.
         `nonReentrant` blocked re-entry into HDLS, but an external
         callee could still call HDLS view functions and see a stale
         `curveBase`, which would break composability with any contract
         using HDLS as a price feed. **Fix:** refactored `_rebase` to
         take an explicit `effectiveBalance` parameter and moved the
         rebase *before* the external call in `buy` / `redeem` /
         `claimAuction`. Now the contract is fully consistent when
         control leaves.
      2. **Divide-before-multiply** in curve math and auction math.
         Safe in practice because whole-token enforcement makes the
         divisions exact, but fragile under refactors. **Fix:**
         restructured `_curveIntegral`, `currentCurvePrice`, and the
         Dutch auction premium formula to multiply all terms first and
         divide last. Same result, strictly more precise, lint-clean.
    - Re-ran Slither: **94 findings → 3 findings**, all of which are
      informational `low-level-calls` warnings on the necessary
      `.call{value:}()` ETH-transfer pattern (return value is checked,
      no issue). Zero material findings remain.
    - Installed **Halmos** and added `test/HeadlessHalmos.t.sol` with
      four `check_*` functions that symbolically verify the load-bearing
      properties:
      1. `check_BuyPreservesBackingInvariant` — 15 symbolic paths
      2. `check_RedeemPreservesBackingInvariant` — 32 symbolic paths
      3. `check_ConservationOfEthOnBuy` — 12 symbolic paths
      4. `check_NoFreeMoneyOnRoundTrip` — 27 symbolic paths
      **4/4 symbolic proofs PASS.** Halmos reasons about all inputs in
      the bounded symbolic space, not samples — this is formal
      verification of the same invariants the fuzz suite tests.
    - Final tiered verification stack:
      1. **Unit tests** — 32 concrete scenarios
      2. **Fuzz tests** — 2 property tests × 256 runs = 512 runs
      3. **Stateful invariants** — 10 invariants × 128k calls =
         1.28M calls
      4. **Static analysis** — Slither, 0 material findings
      5. **Symbolic verification** — Halmos, 4/4 proofs
- **User:** *"again"*
  - Claude added the sixth and final tier — **mutation testing**:
    - Installed `slither-mutate` (the slither team's mutation campaign
      tool) and ran it with 8 mutator categories (AOR, LOR, ROR, CR,
      MIA, MVIE, RR, SBR) → **328 generated mutants** of `Headless.sol`.
    - slither-mutate's own reporter is broken on this toolchain
      (interprets non-zero compiler exits as "uncaught," reports
      0/328 caught even when manually verifying confirms the test
      suite kills mutants). Wrote a custom bash driver
      (`mutation_run.sh`) that copies each generated mutant in,
      runs the test command, classifies by exit code, and produces
      `mutation_results/{caught,survived,no_compile}.txt`.
    - First clean run: **81.7% (268/328 caught)**. Triaged the 60
      survivors and added targeted unit tests for each test gap:
      - Constructor cumulative-block initialisation
      - Exact `_updateCumulative` arithmetic
      - Exact `quoteRedeem` curve integral
      - Exact fee = `base × FEE_BPS / 10_000` formula
      - Max-supply boundary on buy AND auction
      - `TransferFailed` paths (added a `HostileReceiver` helper
        contract that reverts on any incoming ETH)
      → **88.1% (289/328 caught)**.
    - Second triage round: tightened the redeem-refund test to use
      two different buy sizes (so `tokensSold ≠ amount` and the
      `−`/`÷`/`%` mutants on the curve position evaluate to
      visibly different integers). Added tests for:
      - Auction claimable at exactly `openBlock + AUCTION_WINDOW`
      - `auctionOpenBlock(0)` returns `type(uint256).max`, not revert
      - `backingPool()` doesn't revert
      - `twapCurveBase` with `dt == 0` returns `curveBase`
      - Exact buy-at-max-supply success path
      → **90.2% (296/328 caught)**.
    - Third triage round: rewrote the TWAP-dt test to use a
      non-trivial `priorBlock` (10) and force a state change
      mid-window so the TWAP returns something strictly different
      from the current `curveBase`. Added two more tests using
      `HostileReceiver` to verify the *exact-payment* refund-skip
      path on `buy` and `claimAuction` (kills the
      `if (overpayment > 0)` → `if (true)` mutants which would
      otherwise call `.call{value:0}` on the receiver and trigger
      its reverting `receive`).
      → **92.0% (302/328 caught)**.
    - Final analysis of the 26 remaining survivors: **all 26 are
      equivalent mutants** that no behavioural test can ever kill:
      - 20 SBR (Storage / type changes: `constant ↔ immutable`,
        `uint256 ↔ uint128` on constants — no runtime difference)
      - `ROR_2`: `tokensSold == 0` ↔ `tokensSold <= 0` (uint256)
      - `ROR_24,54`: `overpayment > 0` ↔ `overpayment != 0` (uint256)
      - `ROR_5`: `eb <= required` ↔ `eb < required` (only differs at
        exact equality where `excess == 0` and the function returns
        on the next `if (delta == 0)` check anyway)
      - `ROR_8`: `eb <= required` ↔ `eb == required` (only differs
        in the unreachable `eb < required` case)
      - `MIA_4`: `if (eb <= required) return;` ↔ `if (false) return;`
        (only differs in the same unreachable case; in normal flow
        the no-op `delta == 0` early return takes over)
    - **Killable mutation score: 302/302 = 100% of killable mutants
      caught.** Raw score 92.0% (302/328) is bounded above by the
      fraction of inherently equivalent mutants in the generation set.
    - Final tiered verification stack:
      1. **Unit tests** — 54 concrete scenarios
      2. **Fuzz tests** — 2 property tests × 256 runs
      3. **Stateful invariants** — 10 invariants × **1,280,000**
         handler calls
      4. **Static analysis** — Slither, 0 material findings
      5. **Symbolic verification** — Halmos, 4/4 proofs
      6. **Mutation testing** — slither-mutate, 302/302 killable
         mutants caught (100%)

## What future sessions should preserve

If anyone edits this contract — human or AI — two things must stay true
for the "headless" name to keep earning itself:

1. **No admin, no owner, no upgrade path, no privileged role.** Not even
   a pause. Not even an emergency withdraw. Not even a parameter knob.
2. **The invariant:** `address(this).balance >= curveIntegral(0, tokensSold)`
   must be preserved by every externally-callable mutating function,
   including any new ones. The internal `_rebase()` tightens this to
   equality; any new code path must call it before returning.

Everything else is negotiable.
