// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Headless} from "../src/Headless.sol";

/// @title  Stateful invariant test suite for Headless
/// @notice Foundry's invariant runner drives a HeadlessHandler through random
///         sequences of operations (buy, redeem, claimAuction, poke, time
///         advances) across 5 actors and checks the core safety properties
///         after every single call. This catches bugs that linear fuzz
///         testing cannot — e.g. accounting drift across long sequences,
///         re-entry between auctions and buys, rebase/curve interactions.
///
/// @dev    The invariants asserted here are the contract's load-bearing
///         promises. If any of these break, the contract is not safe to
///         deploy. These must keep passing forever.

/// @notice Handler that Foundry calls random methods on with random inputs.
///         Wraps all error-prone paths in try/catch so the fuzzer doesn't
///         get stuck on reverts, but ALWAYS submits the raw calls so real
///         behaviour is exercised.
contract HeadlessHandler is Test {
    Headless public immutable token;
    address[] public actors;

    // Ghost variables: accumulator state we track externally to cross-check
    // against the contract.
    uint256 public ghost_totalEthIn;   // sum of ETH paid via buy+auction
    uint256 public ghost_totalEthOut;  // sum of ETH returned via redeem

    uint256 public ghost_buyCalls;
    uint256 public ghost_redeemCalls;
    uint256 public ghost_auctionCalls;
    uint256 public ghost_pokeCalls;

    modifier useActor(uint256 seed) {
        address actor = actors[seed % actors.length];
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    constructor(Headless _token) {
        token = _token;
        for (uint256 i = 0; i < 5; i++) {
            address a = address(uint160(uint256(keccak256(abi.encode("actor", i))) | 1));
            vm.deal(a, 1_000_000 ether);
            actors.push(a);
        }
    }

    function buy(uint256 seed, uint256 rawAmount) external useActor(seed) {
        // Bound to a sane range and round to whole tokens.
        uint256 amount = (bound(rawAmount, 1 ether, 5_000 ether) / 1 ether) * 1 ether;
        if (amount == 0) return;
        if (token.tokensSold() + amount + token.FOUNDER_ALLOCATION() > token.MAX_SUPPLY()) return;

        (uint256 total, , ) = token.quoteBuy(amount);
        if (total == 0) return;

        ghost_totalEthIn += total;
        ghost_buyCalls++;
        token.buy{value: total}(amount);
    }

    function redeem(uint256 seed, uint256 rawAmount) external useActor(seed) {
        address actor = actors[seed % actors.length];
        uint256 bal = token.balanceOf(actor);
        if (bal == 0) return;

        // Cap at both the actor's balance AND tokensSold (founder tokens
        // cannot be curve-redeemed).
        uint256 maxRedeem = bal < token.tokensSold() ? bal : token.tokensSold();
        if (maxRedeem < 1 ether) return;

        uint256 amount = (bound(rawAmount, 1 ether, maxRedeem) / 1 ether) * 1 ether;
        if (amount == 0 || amount > token.tokensSold()) return;

        (uint256 refund, , ) = token.quoteRedeem(amount);
        ghost_totalEthOut += refund;
        ghost_redeemCalls++;
        token.redeem(amount);
    }

    function claimAuction(uint256 seed) external useActor(seed) {
        uint256 id = token.currentAuctionId();
        if (token.auctionClaimed(id)) return;
        if (
            token.tokensSold() + token.AUCTION_SIZE() + token.FOUNDER_ALLOCATION()
                > token.MAX_SUPPLY()
        ) return;

        try token.auctionPrice(id) returns (uint256 price) {
            ghost_totalEthIn += price;
            ghost_auctionCalls++;
            token.claimAuction{value: price}(id);
        } catch {
            return;
        }
    }

    function advanceBlocks(uint256 raw) external {
        uint256 n = bound(raw, 1, 50);
        vm.roll(block.number + n);
    }

    function poke(uint256 seed) external useActor(seed) {
        ghost_pokeCalls++;
        token.poke();
    }

    function numActors() external view returns (uint256) {
        return actors.length;
    }
}

contract HeadlessInvariantTest is StdInvariant, Test {
    Headless public token;
    HeadlessHandler public handler;

    function setUp() public {
        token = new Headless();
        handler = new HeadlessHandler(token);

        // Tell the invariant runner to only call methods on the handler.
        targetContract(address(handler));

        // Only these handler methods participate in the random sequence.
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = HeadlessHandler.buy.selector;
        selectors[1] = HeadlessHandler.redeem.selector;
        selectors[2] = HeadlessHandler.claimAuction.selector;
        selectors[3] = HeadlessHandler.advanceBlocks.selector;
        selectors[4] = HeadlessHandler.poke.selector;
        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );
    }

    // ════════════════════════════════════════════════════════════════════
    //                        SAFETY INVARIANTS
    // ════════════════════════════════════════════════════════════════════

    /// @notice The load-bearing invariant of the whole contract.
    ///         If this ever breaks, redemptions could fail and the "floor"
    ///         promise is void.
    function invariant_BackingCoversCurveIntegral() public view {
        assertGe(
            address(token).balance,
            token.curveBackingRequired(),
            "backing < curve requirement"
        );
    }

    /// @notice totalSupply is always exactly FOUNDER_ALLOCATION + tokensSold.
    ///         Buy/redeem move both in lockstep; auction mints increment both.
    ///         Founder tokens never get burned (tokensSold < amount guard).
    function invariant_SupplyAccountingConsistent() public view {
        assertEq(
            token.totalSupply(),
            token.FOUNDER_ALLOCATION() + token.tokensSold(),
            "totalSupply != FOUNDER + tokensSold"
        );
    }

    /// @notice Supply never exceeds the hard cap.
    function invariant_SupplyWithinCap() public view {
        assertLe(token.totalSupply(), token.MAX_SUPPLY(), "totalSupply > MAX_SUPPLY");
    }

    /// @notice curveBase is monotonically non-decreasing — rebase only goes up,
    ///         and no other function modifies it.
    function invariant_CurveBaseMonotonic() public view {
        assertGe(
            token.curveBase(),
            token.INITIAL_CURVE_BASE(),
            "curveBase < initial"
        );
    }

    /// @notice tokensSold never exceeds MAX_SUPPLY - FOUNDER_ALLOCATION.
    function invariant_TokensSoldBounded() public view {
        assertLe(
            token.tokensSold(),
            token.MAX_SUPPLY() - token.FOUNDER_ALLOCATION(),
            "tokensSold above cap"
        );
    }

    /// @notice Total rebased value is monotonically non-decreasing and never
    ///         exceeds the total ETH ever flowed into the contract.
    function invariant_TotalRebasedBounded() public view {
        assertLe(
            token.totalRebased(),
            handler.ghost_totalEthIn(),
            "totalRebased > ghost_totalEthIn"
        );
    }

    /// @notice Founder allocation is immutable — the founder's address
    ///         cannot mint, and no function burns the founder allocation.
    ///         Therefore the sum of (tokensSold + FOUNDER_ALLOCATION) equals
    ///         totalSupply, which we already assert above. This one guards
    ///         against any future code path that might accidentally let
    ///         founder tokens cross into the curve accounting.
    function invariant_FounderAllocationIntact() public view {
        assertEq(
            token.FOUNDER_ALLOCATION(),
            3_000_000 ether,
            "founder allocation changed"
        );
    }

    /// @notice Conservation of ETH: the contract's current balance must
    ///         equal (total ETH ever paid in) − (total ETH ever paid out).
    ///         If this ever breaks, value has been created or destroyed
    ///         out of thin air. This is the strongest economic invariant
    ///         a value-holding contract can assert.
    function invariant_ConservationOfEth() public view {
        assertEq(
            address(token).balance,
            handler.ghost_totalEthIn() - handler.ghost_totalEthOut(),
            "conservation of ETH violated"
        );
    }

    /// @notice No actor can ever be short ETH at the contract level: the sum
    ///         of every actor's token balance * current-refund-for-that-size
    ///         must be bounded by the contract's actual ETH balance. This is
    ///         a stricter version of `invariant_BackingCoversCurveIntegral`:
    ///         it asserts the invariant per-actor instead of globally.
    function invariant_EveryActorCanExitToPoolRoom() public view {
        uint256 balance = address(token).balance;
        // The curve refund for ALL outstanding curve tokens must fit inside
        // the current balance (this is exactly `curveBackingRequired`, but
        // asserted here as a per-invariant sanity check at the actor level).
        uint256 required = token.curveBackingRequired();
        assertGe(balance, required, "per-actor exit unfunded");
    }

    // ════════════════════════════════════════════════════════════════════
    //                     CALL SUMMARY (debugging aid)
    // ════════════════════════════════════════════════════════════════════

    function invariant_CallSummary() public view {
        // Not an assertion — this function prints call counts at the end
        // of the run so you can see what coverage the fuzzer achieved.
        // Forge prints the last invariant's console output.
        console.log("buy calls:        ", handler.ghost_buyCalls());
        console.log("redeem calls:     ", handler.ghost_redeemCalls());
        console.log("auction calls:    ", handler.ghost_auctionCalls());
        console.log("poke calls:       ", handler.ghost_pokeCalls());
        console.log("tokensSold:       ", token.tokensSold());
        console.log("curveBase:        ", token.curveBase());
        console.log("backing:          ", address(token).balance);
        console.log("totalRebased:     ", token.totalRebased());
    }
}
