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

### Session 3 — adversarial review (a different Claude session, no shared state)

This is the part of the timeline that wasn't supposed to exist. After session 2 ended with all six tiers green and the contract pushed to GitHub, the author opened a fresh Claude Code session in their home directory and asked it to attack the contract instead of verify it. The session had no access to the previous prompt history, no knowledge of the test suite design, and no priors about what the contract should do — only the README's claims.

- **User:** *"review the git repo of mine (dreliq9) called headless with 2 other evaluator agents"*
  - Claude invoked the `/qa-hard` skill (rigorous 3-evaluator adversarial review modeled on a specialist-loop pipeline). Pulled the contract and tests via the GitHub MCP, then dispatched three evaluator agents in parallel. Each evaluator was given the same spec and file list but worked in isolation — no cross-contamination. Each was instructed to read the entire contract (~480 lines), evaluate across seven dimensions (spec compliance, correctness, reasoning quality, missed concerns, false alarms, code quality, communication quality), severity-calibrate findings, and grade the contract A through F.
  - **All three evaluators independently graded the contract `D`.** All three identified the same critical bug, traced the same exact attack path, and pointed at the same lines (`Headless.sol:148` mint, `:302-327` redeem). The bug:
    > The deployer mints 3,000,000 HDLS at construction. `tokensSold` starts at 0. As soon as Alice calls `buy(100)`, `tokensSold` becomes 100. The deployer can then call `redeem(100)` against their own pre-mined allocation — both guards (`balanceOf(self) >= 100` and `100 <= tokensSold`) pass, the burn comes out of the founder's 3M, and the refund (≈ Alice's payment minus fees) flows to the founder. Alice still holds 100 HDLS but `tokensSold == 0`, so her own subsequent `redeem` reverts. The deployer has just front-run a buyer's exit using a token they minted for free.
  - The README's "founder is mechanically last in line on exit" claim was structurally false. The `tokensSold` counter was a supply guard, not an ordering guard, and the test author had conflated the two.
  - **The damning evidence**: the unit test `test_FounderCannotRedeemBelowBaseline` actually demonstrates the exploit succeeding while the test asserts only that the founder can't redeem *more* afterward. Reading the test name, you'd conclude the founder was locked out. The author tested the wrong property and confidently named the test for what they thought they had tested. Every tier of the verification stack greenlit the bug because every tier was anchored to the same test.
  - Claude then ran phase 3 (isolated weighing of each evaluator's report quality), phase 4 (synthesis with confidence tiers — HIGH/MAJORITY/CONTESTED/UNIQUE), and phase 5 (presented a synthesis report with severity-calibrated findings to the user). Synthesis grade: `D`, high confidence.
- **User:** *"fix all"*
  - Claude cloned the repo to `/tmp/headless`, ran `forge test` to confirm the 54-test baseline passed, then applied the founder-taint lock fix:
    1. Added a `FounderTaintLocked` error and `mapping(address => uint256) public founderTaint`.
    2. Initialized `founderTaint[msg.sender] = FOUNDER_ALLOCATION` in the constructor.
    3. Overrode `_update` (the unified OZ ERC20 hook) to propagate taint proportionally on every account-to-account transfer. Round UP for stickiness, capped at the sender's current taint, no movement on mint or burn. The reasoning: burns are gated by the redeem precondition below, so taint never needs to move on burn; transfers must move taint or the founder could escape via a fresh address; mints can't create taint because the only mint that ever does is the founder mint in the constructor.
    4. Added a precondition in `redeem`: `if (balanceOf(msg.sender) - amount < founderTaint[msg.sender]) revert FounderTaintLocked();`. The founder cannot burn into their tainted balance.
    5. Added a `tokensSold > 0` gate in `claimAuction` to close the deploy-block self-rebate (the auction otherwise opened in the deploy block with no holders to receive the rebased premium).
  - Then rewrote the test file:
    - **Removed** the misleading `test_FounderCannotRedeemBelowBaseline` (it celebrated the exploit as a passing test).
    - Added four new tests:
      - `test_FounderCannotDrainBuyerDirect` — founder calls `redeem` directly → reverts.
      - `test_FounderCannotDrainBuyerViaTransfer` — founder transfers 3M to bob → bob's `redeem` reverts. Proves taint propagates.
      - `test_FounderCanRedeemBoughtTokens` — founder buys 50 fresh tokens via the curve → can redeem exactly those 50, not one wei into the allocation.
      - `test_FounderTaintPropagatesProportionally` — partial transfer splits taint with sticky rounding.
    - Added a `_seedCurveForAuction()` helper + `seeded` modifier; applied it to the 10 auction tests that needed `tokensSold > 0` after the new gate.
  - Then rewrote the invariant test file:
    - The handler now constructs the token itself, making the founder == handler, and adds `address(this)` as **actor 0**. Every redeem call with `seed % 6 == 0` is the founder attempting to drain.
    - The redeem handler is wrapped in `try/catch` so taint-locked attempts don't pollute ghost variables.
    - **Replaced** the previously-stub `invariant_EveryActorCanExitToPoolRoom` (whose body just re-asserted the aggregate `balance ≥ curveBackingRequired` check, which holds vacuously after a drain) with a real per-holder solvency check:
      ```solidity
      for each actor:
          assertLe(founderTaint[actor], balanceOf(actor));
      sumNonTainted += balanceOf(actor) - founderTaint[actor];
      assertEq(sumNonTainted, tokensSold);
      assertGe(address(token).balance, curveBackingRequired());
      ```
      This is the property that catches a founder drain: Alice's non-tainted balance would remain positive while `tokensSold` dropped to zero — a contradiction the assertion would flag.
  - Re-ran the full stack: **57/57 unit tests pass, 10/10 invariants pass × 1.28M handler calls, 4/4 Halmos symbolic proofs pass**, Slither unchanged. The taint lock and per-holder invariant work end-to-end.
- **User:** *"fix moderate issues as well"*
  - Claude applied the four moderate findings flagged during the synthesis phase:
    1. **Half-open auction window.** Changed `claimAuction` and `auctionPriceAt` to `[openBlock, openBlock + WINDOW)` instead of inclusive. The previous inclusive close block had premium = 0, allowing a fee-free 1000-HDLS mint on the final block — broke the "every trade pays a spread" symmetry. New `test_AuctionExpiredAtCloseBlock` proves the exclusion; the renamed `test_AuctionClaimableAtLastBlockBeforeClose` covers the inclusive end. `test_AuctionPriceDecaysLinearly` updated to assert `priceLast > base`.
    2. **L2 block-time sensitivity.** Converted `AUCTION_INTERVAL` and `AUCTION_WINDOW` from `constant` to `immutable` constructor parameters with `InvalidAuctionConfig` validation (`> 0`, `window <= interval`). `Deploy.s.sol` now documents recommended values for L1 (25, 25), Base/OP (150, 150), and Arbitrum (1200, 1200), and passes 25/25 as defaults. All test setUps updated to pass `(25, 25)`.
    3. **`twapCurveBase` input validation.** Added a `TwapNotChronological` named error rejecting `priorBlock > block.number` and `priorCumulative > nowCumulative` — the function previously underflow-reverted on bad inputs.
    4. **`Donated` event in `receive()`.** Added `event Donated(address indexed from, uint256 amount)` and emit it from `receive()` (gated on `msg.value > 0` so the buy/claimAuction overpayment refund path doesn't double-emit).
  - One moderate finding (`auctionPriceAt` baseCost drift mid-window) was documented via a strong NatSpec ⚠ block instead of fixed via snapshotting — a snapshot mechanism would require per-auction state for an agent-UX issue, not a correctness one, and the natural overpayment-refund path already protects callers.
  - Re-ran the full stack: **58/58 unit tests pass** (added the close-block expiry test, removed the misleading test = +4 net since session start), **10/10 invariants pass × 1.28M calls**, **4/4 Halmos proofs pass**, Slither unchanged.
- **User:** *(approval to push the branch and open a PR)*
  - Claude branched `fix/founder-taint-lock` off main, committed all changes with a detailed message naming the critical finding and the four moderate fixes, pushed to `dreliq9/headless`, and opened [PR #1](https://github.com/dreliq9/headless/pull/1) via the GitHub MCP. The PR body documents the attack path, the fix, and the verification stack results post-fix.

### Session 4 — repositioning as research artifact

After the fix landed, the author and Claude discussed what to actually do with the repository. The original framing — "an autonomous agent-native token, six-tier verified, non-rug, fair launch" — could not survive the historical critical finding without disclosure. The question was whether to (a) bring the contract to market as a token, (b) productize the verification methodology as a service, or (c) reposition the whole repo as a research artifact / case study.

The analysis: bringing the contract to market would require a real audit (~$15k–$60k), a crypto lawyer (legal exposure on the founder allocation under any reasonable Howey reading), bootstrap liquidity, distribution, monitoring, incident response, and an answer to "why would anyone hold this." The analysis flagged the founder allocation as the legal hot potato regardless of technical fixes — the taint lock prevents an economic rug but does nothing for the legal claim that the founder received tokens expecting profit from others' efforts. The pragmatic recommendation was option (c): reposition.

- **User:** *(approved the repositioning)*
  - Claude rewrote `README.md` from "verified token" framing to "research artifact" framing:
    - New top-of-file framing sentence: *"A one-week experiment in AI-authored smart contract development and the verification gaps of AI-driven verification."*
    - New first content section ("What this repository actually is") positioning the bug discovery as the load-bearing finding, not the contract itself.
    - New "Historical critical finding" section walking through the attack path, the per-tier failure analysis, and the fix.
    - New "Bounds and disclosures the original README didn't make explicit" subsection acknowledging the Halmos ≤100 ether bound, single-actor symbolic proofs, mutation-testing-measures-coverage-not-correctness, and L1-block-time sensitivity.
    - New "Load-bearing invariant" subsection making explicit that the original aggregate invariant was necessary but not sufficient, and that the per-holder version added in PR #1 is the actual safety property.
    - New "What v2 should look like" section listing eight forward-looking design notes for any future iteration — sub-whole-token denomination, slippage-bounded primitives, commit-reveal auctions, simulate-without-mutate views, proof-of-reserves API, max-buy-for-slippage, per-actor solvency from day one, adversarial review as a verification tier.
    - New "Reproduce the historical bug" instruction in the verify-yourself section so any reader can run `git checkout f1d793c~1 && forge test --match-test test_FounderCannotRedeemBelowBaseline -vv` and watch the test pass while the founder drains alice's deposit.
    - Strengthened the safety section to explicitly note that the verification stack failed to catch the critical finding when run as positive verification, and that automated stacks catch what they're told to look for.
    - Removed "non-rug" and "formally verified" as standalone adjectives.
  - This file (PROMPTS.md) was extended with sessions 3 and 4 in the same per-prompt format as sessions 1 and 2, so the full provenance trail is unbroken.

## What future sessions should preserve

If anyone edits this contract — human or AI — three things must stay true
for the "headless" name to keep earning itself:

1. **No admin, no owner, no upgrade path, no privileged role.** Not even
   a pause. Not even an emergency withdraw. Not even a parameter knob.
2. **The aggregate invariant:** `address(this).balance >= curveIntegral(0, tokensSold)`
   must be preserved by every externally-callable mutating function,
   including any new ones. The internal `_rebase()` tightens this to
   equality; any new code path must call it before returning.
3. **Per-holder solvency** (added after the session 3 finding): every
   holder's non-tainted balance must be redeemable from the contract's
   ETH backing. The aggregate invariant alone is necessary but not
   sufficient — it holds vacuously after a drain that takes `tokensSold`
   to zero. The taint-lock mechanism in `_update` plus the redeem
   precondition `balance - amount >= founderTaint[caller]` is the
   load-bearing enforcement; the per-holder invariant in
   `HeadlessInvariant.t.sol` is the load-bearing test. **Do not loosen
   either without a successor mechanism that preserves the property
   that no actor can take ETH that backs another actor's tokens.**

Everything else is negotiable.

The deeper methodological lesson, kept here as a permanent footnote so
nobody who works on this file in the future has to relearn it: **the
contract author and the test author cannot be the same agent on the
same session.** Session 2 produced both the contract and the
verification stack, both of which were confidently wrong about the same
property. Session 3 was a different Claude session asked to argue
against the artifact rather than verify it, and found the bug on the
first pass. If you (a future AI session, or a future human) are about
to claim a contract is verified, schedule a separate session whose
only job is to attack the claims of the verifying session. The
adversarial pass is the cheapest tier in any verification stack and
was the only one that worked here.
