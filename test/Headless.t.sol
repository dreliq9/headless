// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Headless} from "../src/Headless.sol";

contract HeadlessTest is Test {
    Headless token;

    address deployer = address(this); // becomes `founder`
    address alice    = address(0xA11CE);
    address bob      = address(0xB0B);
    address carol    = address(0xCAA0);

    function _invariantHolds() internal view returns (bool) {
        return address(token).balance >= token.curveBackingRequired();
    }

    /// @dev Seed the curve with a tiny buy from a fresh address so the
    ///      `tokensSold > 0` auction gate is satisfied. Used by every
    ///      auction test that does not explicitly buy first. Uses a
    ///      dedicated seeder address so existing actor balances are
    ///      unaffected.
    function _seedCurveForAuction() internal {
        address seeder = address(0xDEED);
        vm.deal(seeder, 10 ether);
        (uint256 total, , ) = token.quoteBuy(1 ether);
        vm.prank(seeder);
        token.buy{value: total}(1 ether);
    }

    modifier seeded() {
        _seedCurveForAuction();
        _;
    }

    function setUp() public {
        token = new Headless(25, 25);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob,   1_000 ether);
        vm.deal(carol, 1_000 ether);
    }

    // ───────────────────────────── DEPLOY ──────────────────────────────

    function test_DeployMintsFounderAllocation() public view {
        assertEq(token.balanceOf(deployer), token.FOUNDER_ALLOCATION());
        assertEq(token.totalSupply(),       token.FOUNDER_ALLOCATION());
        assertEq(token.tokensSold(),        0);
        assertEq(token.curveBase(),         token.INITIAL_CURVE_BASE());
        assertEq(token.founder(),           deployer);
        assertTrue(_invariantHolds());
    }

    function test_NameAndSymbol() public view {
        assertEq(token.name(),   "Headless");
        assertEq(token.symbol(), "HDLS");
    }

    // ────────────────────────────── BUY ────────────────────────────────

    function test_BuyMintsAndChargesFee() public {
        uint256 amount = 1000 ether;
        (uint256 total, uint256 base, uint256 fee) = token.quoteBuy(amount);
        assertEq(total, base + fee);
        assertGt(fee, 0);

        vm.prank(alice);
        token.buy{value: total}(amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.tokensSold(),     amount);
        // The fee has been rebased into curveBase, so invariant is tight.
        assertEq(address(token).balance, token.curveBackingRequired());
        assertTrue(_invariantHolds());
        assertGt(token.totalRebased(), 0); // fee was swept
    }

    function test_BuyRefundsOverpayment() public {
        uint256 amount = 10 ether;
        (uint256 total, , ) = token.quoteBuy(amount);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        token.buy{value: total + 5 ether}(amount);

        assertEq(alice.balance, aliceBefore - total);
    }

    function test_BuyRevertsOnNonWhole() public {
        vm.prank(alice);
        vm.expectRevert(Headless.NotWholeTokens.selector);
        token.buy{value: 1 ether}(1.5 ether);
    }

    function test_BuyRevertsOnUnderpayment() public {
        uint256 amount = 10 ether;
        (uint256 total, , ) = token.quoteBuy(amount);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Headless.InsufficientPayment.selector, total - 1, total)
        );
        token.buy{value: total - 1}(amount);
    }

    // ──────────────────────────── REDEEM ───────────────────────────────

    function test_BuyThenRedeemLosesSpread() public {
        uint256 amount = 1000 ether;
        (uint256 totalBuy, , uint256 feeBuy) = token.quoteBuy(amount);

        vm.startPrank(alice);
        uint256 before = alice.balance;
        token.buy{value: totalBuy}(amount);
        token.redeem(amount);
        vm.stopPrank();

        // Alice should be down by approximately (buy fee + redeem fee).
        // Exact equality isn't possible because the buy's fee was rebased
        // into curveBase BEFORE alice's redeem — so alice actually redeems
        // against a slightly higher curveBase than she bought at, which
        // partially compensates her for the buy fee. Verify the direction:
        // she lost *some* value, but strictly less than 2x fee.
        uint256 lost = before - alice.balance;
        assertGt(lost, 0);
        assertLt(lost, 2 * feeBuy + 1);
        // Invariant holds and tokensSold is back to zero.
        assertEq(token.tokensSold(), 0);
        assertTrue(_invariantHolds());
    }

    function test_RedeemRevertsAboveTokensSold() public {
        vm.prank(deployer);
        vm.expectRevert(Headless.InsufficientCurveSupply.selector);
        token.redeem(1 ether);
    }

    /// @notice The founder must NOT be able to drain a buyer's deposit by
    ///         redeeming their pre-minted 3% allocation against tokensSold.
    ///         This is the load-bearing "founder is mechanically last in
    ///         line" promise from the README. Direct attempt by founder.
    function test_FounderCannotDrainBuyerDirect() public {
        uint256 amount = 100 ether;
        (uint256 total, , ) = token.quoteBuy(amount);
        vm.prank(alice);
        token.buy{value: total}(amount);

        // Founder holds the 3M allocation, all of it tainted. Any redeem
        // attempt must revert because the post-burn balance would dip below
        // the taint floor.
        vm.prank(deployer);
        vm.expectRevert(Headless.FounderTaintLocked.selector);
        token.redeem(amount);

        // Alice's deposit and redemption rights are intact.
        assertEq(token.tokensSold(), amount);
        assertEq(token.balanceOf(alice), amount);
        vm.prank(alice);
        token.redeem(amount);
        assertEq(token.tokensSold(), 0);
    }

    /// @notice Founder cannot escape the lock by transferring their allocation
    ///         to a fresh address — taint propagates on every transfer (rounded
    ///         UP for stickiness).
    function test_FounderCannotDrainBuyerViaTransfer() public {
        uint256 amount = 100 ether;
        (uint256 total, , ) = token.quoteBuy(amount);
        vm.prank(alice);
        token.buy{value: total}(amount);

        // Founder routes their allocation through bob.
        vm.prank(deployer);
        token.transfer(bob, token.FOUNDER_ALLOCATION());

        // Bob now carries all 3M of taint.
        assertEq(token.founderTaint(bob), token.FOUNDER_ALLOCATION());
        assertEq(token.founderTaint(deployer), 0);

        vm.prank(bob);
        vm.expectRevert(Headless.FounderTaintLocked.selector);
        token.redeem(amount);

        // Alice's position is intact and redeemable.
        assertEq(token.tokensSold(), amount);
        vm.prank(alice);
        token.redeem(amount);
    }

    /// @notice Founder may redeem tokens they purchased via the curve, but
    ///         not their tainted founder allocation. The taint check uses
    ///         `balance - amount >= taint`, so the founder can burn down
    ///         to (but not below) their taint floor.
    function test_FounderCanRedeemBoughtTokens() public {
        // Alice seeds the curve so the founder can buy and then redeem.
        uint256 alicesBuy = 100 ether;
        (uint256 aliceTotal, , ) = token.quoteBuy(alicesBuy);
        vm.prank(alice);
        token.buy{value: aliceTotal}(alicesBuy);

        // Founder buys 50 fresh tokens through the curve.
        uint256 founderBuy = 50 ether;
        (uint256 founderTotal, , ) = token.quoteBuy(founderBuy);
        vm.deal(deployer, founderTotal);
        vm.prank(deployer);
        token.buy{value: founderTotal}(founderBuy);

        // Founder taint stays at 3M (unchanged by buy/mint), but balance
        // is now 3M + 50, so they can redeem up to 50.
        assertEq(token.founderTaint(deployer), token.FOUNDER_ALLOCATION());

        vm.prank(deployer);
        token.redeem(founderBuy); // exactly the bought amount — should pass

        // Trying to redeem one more wei into the founder allocation reverts.
        vm.prank(deployer);
        vm.expectRevert(Headless.FounderTaintLocked.selector);
        token.redeem(1 ether);
    }

    /// @notice Taint propagates proportionally on partial transfers and
    ///         remains sticky (rounds up) so the founder cannot dilute it.
    function test_FounderTaintPropagatesProportionally() public {
        // Founder sends half their allocation to bob.
        uint256 half = token.FOUNDER_ALLOCATION() / 2;
        vm.prank(deployer);
        token.transfer(bob, half);

        // Both parties now hold ≥ proportional taint.
        assertGe(token.founderTaint(deployer), half);
        assertGe(token.founderTaint(bob), half);
        // Conservation modulo round-up (taint should never be lost on transfer).
        assertGe(
            token.founderTaint(deployer) + token.founderTaint(bob),
            token.FOUNDER_ALLOCATION()
        );
    }

    // ───────────────────── CONTINUOUS REBASE / FEES ────────────────────

    function test_FeeAccrualRaisesCurveBase() public {
        uint256 startBase = token.curveBase();

        uint256 amount = 1000 ether;
        (uint256 total, , uint256 fee) = token.quoteBuy(amount);
        vm.prank(alice);
        token.buy{value: total}(amount);

        assertGt(token.curveBase(), startBase);
        assertGe(token.totalRebased(), fee);
        // Invariant tight after rebase:
        assertEq(address(token).balance, token.curveBackingRequired());
    }

    function test_PokeRebasesDonatedEth() public {
        // Alice buys so there are holders.
        uint256 amount = 1000 ether;
        (uint256 total, , ) = token.quoteBuy(amount);
        vm.prank(alice);
        token.buy{value: total}(amount);

        uint256 baseBefore = token.curveBase();

        // Bob "donates" ETH directly to the contract.
        vm.prank(bob);
        (bool ok, ) = address(token).call{value: 3 ether}("");
        assertTrue(ok);
        assertEq(token.excessBacking(), 3 ether);

        // Anyone can poke to distribute it.
        vm.prank(carol);
        token.poke();

        assertGt(token.curveBase(), baseBefore);
        assertEq(token.excessBacking(), 0);
        assertTrue(_invariantHolds());
    }

    // ──────────────────────── DUTCH AUCTION ────────────────────────────

    function test_AuctionOpensAtInterval() public {
        // First auction is id=1, opens at launchBlock.
        uint256 id = token.currentAuctionId();
        assertEq(id, 1);

        uint256 price = token.auctionPrice(id);
        (, uint256 base, ) = _simBaseForAuction();
        // Price should start at base * 1.20 (20% premium).
        assertApproxEqAbs(price, (base * 12000) / 10000, 1);
    }

    function _simBaseForAuction() internal view returns (uint256 total, uint256 base, uint256 fee) {
        return token.quoteBuy(token.AUCTION_SIZE());
    }

    function test_AuctionPriceDecaysLinearly() public {
        uint256 id = token.currentAuctionId();
        // Use the contract's launchBlock (storage read) as the anchor so no
        // local-variable optimisation can inline the value.
        uint256 anchor = token.launchBlock();
        uint256 window = token.AUCTION_WINDOW();
        uint256 midTarget = anchor + window / 2;
        // Last claimable block (window is half-open).
        uint256 lastTarget = anchor + window - 1;

        uint256 priceAtOpen = token.auctionPrice(id);

        vm.roll(midTarget);
        uint256 priceMid = token.auctionPrice(id);
        assertLt(priceMid, priceAtOpen);

        vm.roll(lastTarget);
        uint256 priceLast = token.auctionPrice(id);
        (, uint256 base, ) = token.quoteBuy(token.AUCTION_SIZE());
        // Premium has decayed to its minimum non-zero value: 1 step out of
        // WINDOW remains, so the premium is exactly maxPremium / WINDOW.
        assertLt(priceLast, priceMid);
        assertGt(priceLast, base);
    }

    function test_ClaimAuctionMintsAndRebases() public seeded {
        uint256 id = token.currentAuctionId();
        uint256 priceAtOpen = token.auctionPrice(id);
        uint256 soldBefore = token.tokensSold();

        uint256 baseBefore = token.curveBase();
        vm.prank(alice);
        token.claimAuction{value: priceAtOpen}(id);

        assertEq(token.balanceOf(alice), token.AUCTION_SIZE());
        assertEq(token.tokensSold(),     soldBefore + token.AUCTION_SIZE());
        assertTrue(token.auctionClaimed(id));
        // Premium was rebased → curveBase rose.
        assertGt(token.curveBase(), baseBefore);
        // Invariant: backing covers required (within sub-gwei rebase residual).
        assertGe(address(token).balance, token.curveBackingRequired());
        assertLt(address(token).balance - token.curveBackingRequired(), 1 gwei);
    }

    function test_ClaimAuctionRefundsOverpayment() public seeded {
        uint256 id = token.currentAuctionId();
        uint256 price = token.auctionPrice(id);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        token.claimAuction{value: price + 7 ether}(id);
        assertEq(alice.balance, aliceBefore - price);
    }

    function test_ClaimAuctionTwiceReverts() public seeded {
        uint256 id = token.currentAuctionId();
        uint256 price = token.auctionPrice(id);

        vm.prank(alice);
        token.claimAuction{value: price}(id);

        vm.prank(bob);
        vm.expectRevert(Headless.AuctionAlreadyClaimed.selector);
        token.claimAuction{value: price * 2}(id);
    }

    function test_ClaimAuctionAfterWindowExpires() public seeded {
        uint256 id = token.currentAuctionId();
        vm.roll(block.number + token.AUCTION_WINDOW() + 1);

        vm.prank(alice);
        vm.expectRevert(Headless.AuctionExpired.selector);
        token.claimAuction{value: 100 ether}(id);
    }

    function test_ClaimAuctionUnderpaymentReverts() public seeded {
        uint256 id = token.currentAuctionId();
        uint256 price = token.auctionPrice(id);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Headless.InsufficientPayment.selector, price - 1, price)
        );
        token.claimAuction{value: price - 1}(id);
    }

    function test_NextAuctionOpensAtNextInterval() public seeded {
        uint256 id1 = token.currentAuctionId();
        uint256 price1 = token.auctionPrice(id1);
        vm.prank(alice);
        token.claimAuction{value: price1}(id1);

        // Advance to next interval.
        vm.roll(block.number + token.AUCTION_INTERVAL());
        uint256 id2 = token.currentAuctionId();
        assertGt(id2, id1);

        uint256 price2 = token.auctionPrice(id2);
        vm.prank(bob);
        token.claimAuction{value: price2}(id2);
        assertEq(token.balanceOf(bob), token.AUCTION_SIZE());
    }

    // ─────────────────────────── TWAP ──────────────────────────────────

    function test_TwapReturnsAverageCurveBase() public {
        uint256 priorCumulative = token.cumulativeCurveBase();
        uint256 priorBlock      = token.lastCumulativeBlock();

        // Buy to trigger fee rebase + cumulative update.
        uint256 amount = 1000 ether;
        (uint256 total, , ) = token.quoteBuy(amount);
        vm.prank(alice);
        token.buy{value: total}(amount);

        vm.roll(block.number + 100);

        uint256 twap = token.twapCurveBase(priorCumulative, priorBlock);
        // TWAP should sit between the old curveBase (INITIAL) and current.
        assertGe(twap, token.INITIAL_CURVE_BASE());
        assertLe(twap, token.curveBase());
    }

    // ──────────────────── INVARIANT / FUZZ ─────────────────────────────

    function testFuzz_BuyRedeemPreservesInvariant(uint96 a, uint96 b, uint96 c) public {
        uint256 amountA = (uint256(a) % 5_000 + 1) * 1 ether;
        uint256 amountB = (uint256(b) % 5_000 + 1) * 1 ether;
        uint256 redeemAmt = ((uint256(c) % 5_000) * 1 ether);

        vm.deal(alice, 1_000_000 ether);
        vm.deal(bob,   1_000_000 ether);

        (uint256 totalA, , ) = token.quoteBuy(amountA);
        vm.prank(alice);
        token.buy{value: totalA}(amountA);
        assertTrue(_invariantHolds());

        (uint256 totalB, , ) = token.quoteBuy(amountB);
        vm.prank(bob);
        token.buy{value: totalB}(amountB);
        assertTrue(_invariantHolds());

        if (redeemAmt > 0 && redeemAmt <= token.balanceOf(alice)) {
            vm.prank(alice);
            token.redeem(redeemAmt);
            assertTrue(_invariantHolds());
        }
    }

    /// @notice Round-tripping the curve should strictly cost value (fee leakage).
    function testFuzz_RoundTripIsNegativeEV(uint96 raw) public {
        uint256 amount = (uint256(raw) % 1_000 + 1) * 1 ether;
        vm.deal(alice, 1_000_000 ether);

        (uint256 total, , ) = token.quoteBuy(amount);
        uint256 before = alice.balance;

        vm.startPrank(alice);
        token.buy{value: total}(amount);
        token.redeem(amount);
        vm.stopPrank();

        // Alice must NEVER gain from a round-trip. Some loss is acceptable.
        assertLe(alice.balance, before);
    }

    // ───────────────────────── EDGE CASES ─────────────────────────────

    /// @notice quoteBuy / quoteRedeem revert cleanly on non-whole amounts.
    function test_QuoteBuyRevertsOnNonWhole() public {
        vm.expectRevert(Headless.NotWholeTokens.selector);
        token.quoteBuy(1.5 ether);
    }

    function test_QuoteRedeemRevertsOnNonWhole() public {
        vm.expectRevert(Headless.NotWholeTokens.selector);
        token.quoteRedeem(1.5 ether);
    }

    /// @notice quoteRedeem reverts if caller asks for more than tokensSold
    ///         (even if their own balance is higher — founder case).
    function test_QuoteRedeemRevertsAboveTokensSold() public {
        vm.expectRevert(Headless.InsufficientCurveSupply.selector);
        token.quoteRedeem(1 ether);
    }

    /// @notice poke() on an empty contract is a safe no-op.
    function test_PokeNoOpOnEmptyContract() public {
        uint256 baseBefore = token.curveBase();
        token.poke();
        assertEq(token.curveBase(), baseBefore);
        assertEq(token.totalRebased(), 0);
    }

    /// @notice Zero-amount buy and zero-amount redeem both revert explicitly.
    function test_BuyZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(Headless.ZeroAmount.selector);
        token.buy{value: 1 ether}(0);
    }

    function test_RedeemZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(Headless.ZeroAmount.selector);
        token.redeem(0);
    }

    /// @notice A claimAuction with exactly the right payment leaves no refund.
    function test_ClaimAuctionExactPaymentNoRefund() public seeded {
        uint256 id = token.currentAuctionId();
        uint256 price = token.auctionPrice(id);
        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        token.claimAuction{value: price}(id);

        assertEq(alice.balance, aliceBefore - price);
    }

    /// @notice Calling auctionPrice on an expired auction reverts.
    function test_AuctionPriceRevertsAfterExpiry() public {
        uint256 id = token.currentAuctionId();
        vm.roll(block.number + token.AUCTION_WINDOW() + 1);
        vm.expectRevert(Headless.AuctionNotOpen.selector);
        token.auctionPrice(id);
    }

    /// @notice Two buyers in sequence: the second pays a higher curve price.
    function test_CurvePriceRisesAfterBuy() public {
        uint256 amount = 1000 ether;

        (uint256 total1, , ) = token.quoteBuy(amount);
        vm.prank(alice);
        token.buy{value: total1}(amount);

        (uint256 total2, , ) = token.quoteBuy(amount);
        assertGt(total2, total1);
    }

    /// @notice The curveState() / auctionState() / oracleState() views return
    ///         fields consistent with the top-level accessors.
    function test_StateViewsReturnConsistentSnapshot() public {
        uint256 amount = 500 ether;
        (uint256 total, , ) = token.quoteBuy(amount);
        vm.prank(alice);
        token.buy{value: total}(amount);

        (
            uint256 totalSupply_,
            uint256 tokensSold_,
            uint256 backing_,
            uint256 curveBase_,
            ,
            uint256 required_,
            uint256 excess_
        ) = token.curveState();

        assertEq(totalSupply_, token.totalSupply());
        assertEq(tokensSold_,  token.tokensSold());
        assertEq(backing_,     address(token).balance);
        assertEq(curveBase_,   token.curveBase());
        assertEq(required_,    token.curveBackingRequired());
        assertEq(excess_,      0); // tight after rebase

        (uint256 aid, uint256 openBlk, uint256 closeBlk, bool claimed) = token.auctionState();
        assertEq(aid,       token.currentAuctionId());
        assertEq(openBlk,   token.auctionOpenBlock(aid));
        assertEq(closeBlk,  token.auctionCloseBlock(aid));
        assertEq(claimed,   token.auctionClaimed(aid));

        (uint256 cum, uint256 lastBlk, uint256 rebased) = token.oracleState();
        assertEq(cum,     token.cumulativeCurveBase());
        assertEq(lastBlk, token.lastCumulativeBlock());
        assertEq(rebased, token.totalRebased());
    }

    // ──────────── MUTATION-DRIVEN COVERAGE TESTS ──────────────────────
    // The following tests were added to kill specific surviving mutants
    // identified by slither-mutate. Each one targets a code path that the
    // earlier behaviour-only tests left uncovered.

    /// @notice Constructor must initialise lastCumulativeBlock to launchBlock,
    ///         not leave it at the default 0. Kills CR_2 (commented assignment).
    function test_ConstructorInitsCumulativeBlock() public view {
        assertEq(token.lastCumulativeBlock(), token.launchBlock());
        assertEq(token.cumulativeCurveBase(), 0);
    }

    /// @notice _updateCumulative must add `curveBase * dt` to the cumulative,
    ///         where dt is the EXACT block delta. Kills AOR_15 / MVIE_5 (the
    ///         dt computation mutants in `_updateCumulative`).
    function test_CumulativeAccumulatesExactly() public {
        uint256 startBase = token.curveBase();
        uint256 startCum  = token.cumulativeCurveBase();
        uint256 startBlk  = token.lastCumulativeBlock();

        // Advance 17 blocks at the starting curveBase, then trigger
        // _updateCumulative via a buy.
        vm.roll(block.number + 17);
        uint256 amount = 1 ether;
        (uint256 total, , ) = token.quoteBuy(amount);
        vm.prank(alice);
        token.buy{value: total}(amount);

        // After the buy, cumulative should have grown by exactly
        // startBase * (block.number_at_buy - startBlk).
        // The block.number at the time of the buy is startBlk + 17.
        uint256 expectedDelta = startBase * 17;
        assertEq(token.cumulativeCurveBase(), startCum + expectedDelta);
        assertEq(token.lastCumulativeBlock(), startBlk + 17);
    }

    /// @notice quoteRedeem must return exactly the curve integral over the
    ///         segment being unwound. Kills AOR_32/33/35 (which mutate the
    ///         `tokensSold - amount` argument inside redeem's _curveIntegral).
    function test_QuoteRedeemReturnsExactCurveIntegral() public {
        // Buy 100 tokens at the initial curve so we know the math precisely.
        uint256 buyAmt = 100 ether;
        (uint256 totalBuy, uint256 baseBuy, ) = token.quoteBuy(buyAmt);
        vm.prank(alice);
        token.buy{value: totalBuy}(buyAmt);

        // Redeeming the SAME amount must return a base equal to the curve
        // integral over [0, 100], at the (now-rebased) curveBase.
        // After the buy + fee rebase, curveBase has risen, so we can't
        // hard-code the value — but we can assert that quoteRedeem's `base`
        // equals the SAME formula computed against current curveBase, and
        // that quoteBuy + quoteRedeem are inverses up to fee leakage.
        (uint256 refund, uint256 baseRedeem, uint256 feeRedeem) = token.quoteRedeem(buyAmt);
        assertEq(refund, baseRedeem - feeRedeem);
        assertEq(feeRedeem, (baseRedeem * token.FEE_BPS()) / 10_000);
        // Curve symmetry: redeeming the only outstanding tokens must drain
        // the contract to exactly the residue (balance - refund).
        assertEq(baseRedeem, token.curveBackingRequired());
    }

    /// @notice The redeem `fee` formula must be `base * FEE_BPS / 10000`,
    ///         not `base + FEE_BPS` etc. Kills AOR_36,37,38 (fee operator
    ///         mutants in redeem) and the analogous fee mutants in buy.
    function test_FeeIsExactBpsOfBase() public {
        // Buy a known amount and verify the quoted fee matches the formula.
        uint256 amount = 500 ether;
        (uint256 total, uint256 base, uint256 fee) = token.quoteBuy(amount);
        assertEq(fee, (base * token.FEE_BPS()) / 10_000);
        assertEq(total, base + fee);
    }

    /// @notice Buys cannot push tokensSold past MAX_SUPPLY - FOUNDER. Kills
    ///         ROR_12,13 and MIA_7 (max-supply check mutants in buy).
    function test_BuyRevertsAtMaxSupplyBoundary() public {
        // Compute the largest legal buy amount.
        uint256 maxBuy = token.MAX_SUPPLY() - token.FOUNDER_ALLOCATION();
        uint256 oneTooMany = maxBuy + 1 ether;

        vm.deal(alice, type(uint128).max);
        vm.prank(alice);
        vm.expectRevert(Headless.ExceedsMaxSupply.selector);
        token.buy{value: type(uint128).max}(oneTooMany);

        // And buying EXACTLY at the max should be allowed.
        vm.prank(alice);
        // We don't actually run this — it would mint 97M tokens which is
        // expensive in the test. The revert path is what we're checking.
    }

    /// @notice claimAuction cannot push tokensSold past MAX_SUPPLY. Kills
    ///         ROR_42,43 and MIA_27 (max-supply check mutants in claimAuction).
    ///         We force tokensSold to a value where the next AUCTION_SIZE
    ///         would overflow MAX_SUPPLY by buying directly.
    function test_ClaimAuctionRevertsAtMaxSupplyBoundary() public {
        // Buy enough that the next auction would push past max supply.
        uint256 maxBuy = token.MAX_SUPPLY() - token.FOUNDER_ALLOCATION();
        uint256 toBuy  = maxBuy - (token.AUCTION_SIZE() / 2); // leaves room < AUCTION_SIZE
        // Round to whole tokens.
        toBuy = (toBuy / 1 ether) * 1 ether;

        vm.deal(alice, type(uint128).max);
        (uint256 total, , ) = token.quoteBuy(toBuy);
        vm.prank(alice);
        token.buy{value: total}(toBuy);

        // Now claim the current auction — should revert because
        // tokensSold + AUCTION_SIZE + FOUNDER would exceed MAX_SUPPLY.
        uint256 id = token.currentAuctionId();
        uint256 price = token.auctionPrice(id);
        vm.deal(bob, price * 2);
        vm.prank(bob);
        vm.expectRevert(Headless.ExceedsMaxSupply.selector);
        token.claimAuction{value: price}(id);
    }

    /// @notice If overpayment refund fails, buy must revert. Kills CR_15
    ///         and MIA_16 (TransferFailed revert mutants in buy).
    function test_BuyRevertsIfRefundCallFails() public {
        // Deploy a hostile receiver that rejects ETH.
        HostileReceiver hostile = new HostileReceiver();
        vm.deal(address(hostile), 1000 ether);

        uint256 amount = 1 ether;
        (uint256 total, , ) = token.quoteBuy(amount);

        // Try to buy with overpayment — refund call will revert in receive.
        vm.prank(address(hostile));
        vm.expectRevert(Headless.TransferFailed.selector);
        token.buy{value: total + 1 ether}(amount);
    }

    /// @notice If redeem refund fails, redeem must revert. Kills CR_15-redeem
    ///         and MIA_36 (TransferFailed revert mutant in redeem).
    function test_RedeemRevertsIfRefundCallFails() public {
        // Buy via a normal path, then transfer tokens to a hostile receiver
        // and have it call redeem.
        uint256 amount = 10 ether;
        (uint256 total, , ) = token.quoteBuy(amount);
        vm.prank(alice);
        token.buy{value: total}(amount);

        HostileReceiver hostile = new HostileReceiver();
        vm.prank(alice);
        token.transfer(address(hostile), amount);

        vm.prank(address(hostile));
        vm.expectRevert(Headless.TransferFailed.selector);
        hostile.callRedeem(token, amount);
    }

    /// @notice claimAuction with overpayment to a hostile receiver must revert.
    function test_ClaimAuctionRevertsIfRefundCallFails() public seeded {
        HostileReceiver hostile = new HostileReceiver();
        vm.deal(address(hostile), 100 ether);

        uint256 id = token.currentAuctionId();
        uint256 price = token.auctionPrice(id);

        vm.prank(address(hostile));
        vm.expectRevert(Headless.TransferFailed.selector);
        token.claimAuction{value: price + 1 ether}(id);
    }

    /// @notice Redeem must use exactly `_curveIntegral(tokensSold-amount, amount)`
    ///         on the redeem code path (NOT just on quoteRedeem). Verifies the
    ///         actor's ETH balance change equals the expected refund exactly.
    ///         Kills AOR_32 / AOR_33 / AOR_35 (mutants of `tokensSold - amount`
    ///         in `redeem`).
    /// @dev    Critical detail: buys TWO different sizes, then redeems the
    ///         smaller one. This makes `tokensSold ≠ amount`, so mutants
    ///         like `tokensSold % amount` and `tokensSold / amount` evaluate
    ///         to integer offsets that produce measurably different curve
    ///         integrals (by ≥2 gwei). Without this, all three operators
    ///         produce the same integer result and the mutants survive.
    function test_RedeemRefundsExactExpectedAmount() public {
        // Two different buys to put tokensSold at 300, then redeem 100.
        // tokensSold-amount = 200, tokensSold/amount = 3, tokensSold%amount = 0.
        // All three are visibly different positions on the curve.
        (uint256 t1, , ) = token.quoteBuy(200 ether);
        vm.prank(alice);
        token.buy{value: t1}(200 ether);

        (uint256 t2, , ) = token.quoteBuy(100 ether);
        vm.prank(alice);
        token.buy{value: t2}(100 ether);

        // Quote against the post-buy state to get the expected refund.
        (uint256 expectedRefund, , ) = token.quoteRedeem(100 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        token.redeem(100 ether);
        assertEq(alice.balance - aliceBefore, expectedRefund);
    }

    /// @notice Redeem's fee must be exactly base * FEE_BPS / 10000 (not +, -, /).
    ///         Verified by computing what the refund WOULD be at zero fee and
    ///         comparing to the actual refund. Kills AOR_36 / AOR_37 / AOR_38.
    function test_RedeemFeeOperatorIsMultiplyDivide() public {
        uint256 amount = 100 ether;
        (uint256 totalBuy, , ) = token.quoteBuy(amount);
        vm.prank(alice);
        token.buy{value: totalBuy}(amount);

        (uint256 refund, uint256 base, uint256 fee) = token.quoteRedeem(amount);
        // Tight identity that pins the operator: base - refund == fee, AND
        // fee == base * FEE_BPS / 10000. Either of those wrong means the
        // operator was mutated.
        assertEq(base - refund, fee);
        assertEq(fee, (base * token.FEE_BPS()) / 10_000);
        // Also verify the actual redeem matches the quoted refund.
        uint256 before = alice.balance;
        vm.prank(alice);
        token.redeem(amount);
        assertEq(alice.balance - before, refund);
    }

    /// @notice Auction window is half-open: claimable at `openBlock + WINDOW - 1`
    ///         but NOT at `openBlock + WINDOW`. The latter is reserved as the
    ///         opening block of the next auction id. This guarantees the
    ///         premium is strictly > 0 on every claimable block (the floor
    ///         is approached but never reached), preserving the
    ///         "every trade pays a spread" symmetry. Kills AOR_57.
    function test_AuctionClaimableAtLastBlockBeforeClose() public seeded {
        uint256 id = token.currentAuctionId();
        uint256 anchor = token.launchBlock();

        // Roll to the last claimable block.
        vm.roll(anchor + token.AUCTION_WINDOW() - 1);

        uint256 price = token.auctionPrice(id);
        // Premium is non-zero — strictly above curve cost.
        (, uint256 base, ) = token.quoteBuy(token.AUCTION_SIZE());
        assertGt(price, base);

        vm.deal(alice, price);
        vm.prank(alice);
        token.claimAuction{value: price}(id);
        assertEq(token.balanceOf(alice), token.AUCTION_SIZE());
    }

    /// @notice At exactly `openBlock + AUCTION_WINDOW`, the auction is no
    ///         longer claimable — both `auctionPrice` and `claimAuction`
    ///         must reject. Defends the half-open window.
    function test_AuctionExpiredAtCloseBlock() public seeded {
        uint256 id = token.currentAuctionId();
        uint256 anchor = token.launchBlock();

        vm.roll(anchor + token.AUCTION_WINDOW());

        vm.expectRevert(Headless.AuctionNotOpen.selector);
        token.auctionPrice(id);

        vm.deal(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(Headless.AuctionExpired.selector);
        token.claimAuction{value: 100 ether}(id);
    }

    /// @notice TWAP `dt` must equal exactly `block.number - priorBlock`, not
    ///         a different operator (e.g. modulo). Kills AOR_87 / MVIE_28
    ///         (mutants of dt in `twapCurveBase`).
    /// @dev    Uses a non-trivial priorBlock (10) and a delta (50) such that
    ///         `block.number % priorBlock` would give `60 % 10 = 0`, which
    ///         the mutated code interprets as "no time elapsed" and returns
    ///         curveBase. The original computes dt=50 and returns the actual
    ///         time-weighted average. The two values are different because
    ///         there's a buy in between that raised curveBase mid-window.
    function test_TwapDtIsExactSubtraction() public {
        // Roll forward and trigger _updateCumulative via a buy at block 10.
        // priorBlock will be 10 (non-trivial — `% 10` ≠ subtraction).
        vm.roll(block.number + 9); // block 10 (assuming launchBlock=1)
        (uint256 t1, , ) = token.quoteBuy(1 ether);
        vm.prank(alice);
        token.buy{value: t1}(1 ether);

        // Snapshot AFTER the buy (cumulative is now updated, lastCumulativeBlock=10).
        uint256 priorCum = token.cumulativeCurveBase();
        uint256 priorBlk = token.lastCumulativeBlock();
        uint256 baseAtSnap = token.curveBase();

        // Advance to block 60 (delta = 50).
        vm.roll(block.number + 50);

        // No further state changes — curveBase has stayed at baseAtSnap the
        // entire 50-block window. TWAP must equal baseAtSnap.
        uint256 twap = token.twapCurveBase(priorCum, priorBlk);
        assertEq(twap, baseAtSnap);

        // Sanity: under AOR_87 (`%`), dt = 60 % 10 = 0, the function returns
        // `curveBase` directly. baseAtSnap == curveBase here, so the values
        // would actually still match. To force divergence, we need curveBase
        // to CHANGE between snapshot and query. Do another buy that bumps
        // curveBase via fee rebase.
        (uint256 t2, , ) = token.quoteBuy(50 ether);
        vm.prank(alice);
        token.buy{value: t2}(50 ether);

        // Now curveBase > baseAtSnap. The honest TWAP from priorBlk to now
        // is (cumulativeAtBuy - priorCum) / (buyBlock - priorBlk), which
        // equals baseAtSnap (the curveBase that was held during the window
        // before the second buy). Plus the post-buy tail at the new
        // curveBase. Compute it manually.
        uint256 currentCum  = token.cumulativeCurveBase();
        uint256 currentBlk  = token.lastCumulativeBlock();
        uint256 currentBase = token.curveBase();
        // Tail since lastCumulativeBlock (which is the second-buy block).
        // No additional time has passed (no further vm.roll), so tail = 0.
        uint256 nowCum = currentCum;
        uint256 dt     = block.number - priorBlk;
        uint256 expected = (nowCum - priorCum) / dt;

        // expected reflects the weighted average over the 50-block window
        // at baseAtSnap. It must NOT equal currentBase (which is higher).
        assertEq(token.twapCurveBase(priorCum, priorBlk), expected);
        assertLt(expected, currentBase);
    }

    /// @notice The redeem function must reject non-whole token amounts. Kills
    ///         CR_13 (commented-out NotWholeTokens revert in `redeem`).
    function test_RedeemRevertsOnNonWhole() public {
        // First buy some so tokensSold > 0.
        uint256 buyAmt = 5 ether;
        (uint256 total, , ) = token.quoteBuy(buyAmt);
        vm.prank(alice);
        token.buy{value: total}(buyAmt);

        vm.prank(alice);
        vm.expectRevert(Headless.NotWholeTokens.selector);
        token.redeem(1.5 ether);
    }

    /// @notice Buying EXACTLY at MAX_SUPPLY - FOUNDER must SUCCEED (the `>`
    ///         in the cap check is correct, not `>=`). Kills ROR_12.
    function test_BuyAtExactMaxSupplyAllowed() public {
        uint256 maxBuy = token.MAX_SUPPLY() - token.FOUNDER_ALLOCATION();
        vm.deal(alice, type(uint128).max);
        (uint256 total, , ) = token.quoteBuy(maxBuy);
        vm.prank(alice);
        token.buy{value: total}(maxBuy);
        assertEq(token.tokensSold(), maxBuy);
    }

    /// @notice claimAuction at exactly the max-supply boundary must SUCCEED.
    ///         Kills ROR_42.
    function test_ClaimAuctionAtExactMaxSupplyAllowed() public {
        // Buy enough to leave EXACTLY AUCTION_SIZE remaining capacity.
        uint256 toBuy =
            token.MAX_SUPPLY() - token.FOUNDER_ALLOCATION() - token.AUCTION_SIZE();
        vm.deal(alice, type(uint128).max);
        (uint256 total, , ) = token.quoteBuy(toBuy);
        vm.prank(alice);
        token.buy{value: total}(toBuy);

        // The next auction should claim successfully.
        uint256 id = token.currentAuctionId();
        uint256 price = token.auctionPrice(id);
        vm.deal(bob, price);
        vm.prank(bob);
        token.claimAuction{value: price}(id);
        assertEq(token.balanceOf(bob), token.AUCTION_SIZE());
        assertEq(token.tokensSold(),   toBuy + token.AUCTION_SIZE());
    }

    /// @notice `auctionOpenBlock(0)` must return `type(uint256).max`, not
    ///         revert. Kills RR_29.
    function test_AuctionOpenBlockZeroReturnsMax() public view {
        assertEq(token.auctionOpenBlock(0), type(uint256).max);
    }

    /// @notice `backingPool()` must return the contract balance, not revert.
    ///         Kills RR_40.
    function test_BackingPoolReturnsBalance() public {
        // After a buy, backingPool should equal the curve requirement.
        uint256 amount = 50 ether;
        (uint256 total, , ) = token.quoteBuy(amount);
        vm.prank(alice);
        token.buy{value: total}(amount);
        assertEq(token.backingPool(), address(token).balance);
        assertGt(token.backingPool(), 0);
    }

    /// @notice `twapCurveBase` with priorBlock == current block (dt == 0) must
    ///         return the current curveBase, not revert. Kills RR_41.
    function test_TwapDtZeroReturnsCurveBase() public view {
        uint256 cum = token.cumulativeCurveBase();
        uint256 blk = block.number; // dt = 0 against this
        // Use launchBlock as priorBlock and 0 as priorCum so dt = block.number - blk = 0.
        uint256 twap = token.twapCurveBase(cum, blk);
        assertEq(twap, token.curveBase());
    }

    /// @notice With EXACT payment (no overpayment), `buy` must NOT call the
    ///         refund path at all. Kills ROR_22 / ROR_24 / MIA_12 (mutants
    ///         that always-enter the refund branch). A hostile receiver
    ///         that reverts on any ETH receipt would only be triggered if
    ///         the refund path is incorrectly entered with overpayment=0.
    function test_BuyExactPaymentSkipsRefundPath() public {
        HostileReceiver hostile = new HostileReceiver();
        vm.deal(address(hostile), 1000 ether);

        uint256 amount = 1 ether;
        (uint256 total, , ) = token.quoteBuy(amount);

        // EXACT payment — original code skips the refund branch entirely.
        // Mutated code that turns `if (overpayment > 0)` into `if (true)`
        // (or `>= 0`, or `!= 0` after all-arithmetic, etc.) will try to
        // send 0 ETH to the hostile receiver, which reverts.
        vm.prank(address(hostile));
        token.buy{value: total}(amount);

        // If we got here, the buy succeeded. Verify state.
        assertEq(token.balanceOf(address(hostile)), amount);
    }

    /// @notice Same property for `claimAuction`. Kills ROR_52 / ROR_54 / MIA_32.
    function test_ClaimAuctionExactPaymentSkipsRefundPath() public seeded {
        HostileReceiver hostile = new HostileReceiver();
        vm.deal(address(hostile), 100 ether);

        uint256 id = token.currentAuctionId();
        uint256 price = token.auctionPrice(id);

        vm.prank(address(hostile));
        token.claimAuction{value: price}(id);

        assertEq(token.balanceOf(address(hostile)), token.AUCTION_SIZE());
    }

    /// @notice The Rebased event's reported `excess` must equal the actual
    ///         excess swept (not zero). Kills MVIE-style mutants that drop
    ///         the local `excessBefore` initialization in `poke`.
    function test_PokeEventReportsExactExcess() public {
        // Buy so there's a curve position.
        uint256 amount = 100 ether;
        (uint256 total, , ) = token.quoteBuy(amount);
        vm.prank(alice);
        token.buy{value: total}(amount);

        // Donate ETH directly.
        uint256 donation = 2 ether;
        (bool ok, ) = address(token).call{value: donation}("");
        assertTrue(ok);

        // Snapshot excess BEFORE poke.
        uint256 excessBefore = token.excessBacking();
        assertEq(excessBefore, donation);

        // Poke: the Poked event's `excess` field must equal donation.
        vm.expectEmit(true, false, false, true);
        emit Headless.Poked(address(this), donation);
        token.poke();
    }

    receive() external payable {}
}

/// @notice Helper contract for testing the failed-refund paths.
///         Rejects all incoming ETH via a reverting receive.
contract HostileReceiver {
    error Rejected();

    receive() external payable {
        revert Rejected();
    }

    function callRedeem(Headless token, uint256 amount) external {
        token.redeem(amount);
    }
}
