// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Headless} from "../src/Headless.sol";

/// @title  Symbolic verification of Headless's backing invariant
/// @notice Run with: `halmos --match-contract HeadlessHalmosTest`
///
///         Halmos is a symbolic bounded model checker. Unlike Foundry fuzz,
///         it reasons about ALL possible inputs in a bounded space rather
///         than sampling random ones. A passing `check_*` function means
///         the invariant holds for every input Halmos could construct
///         within the loop/unroll bounds.
///
/// @dev    The properties checked here are the same load-bearing invariants
///         asserted in the stateful fuzz suite, but now verified against
///         the symbolic semantics of the contract rather than against a
///         sampled execution trace.
contract HeadlessHalmosTest is Test {
    Headless token;
    address user = address(0xBEEF);

    function setUp() public {
        token = new Headless();
        vm.deal(user, 1_000_000 ether);
    }

    /// @notice For ANY whole-token `amount` within a bounded range, `buy`
    ///         must preserve: balance ≥ curveBackingRequired.
    function check_BuyPreservesBackingInvariant(uint256 amount) public {
        // Bound to a small range so Halmos can enumerate feasibly.
        // Whole tokens only, at least 1, at most 100.
        vm.assume(amount >= 1 ether && amount <= 100 ether);
        vm.assume(amount % 1 ether == 0);

        (uint256 total, , ) = token.quoteBuy(amount);

        vm.prank(user);
        token.buy{value: total}(amount);

        assert(address(token).balance >= token.curveBackingRequired());
    }

    /// @notice `redeem` must preserve the backing invariant for any amount
    ///         within a previously-minted curve position. Uses a concrete
    ///         buy amount so only the redeem amount is symbolic (keeps the
    ///         solver tractable — two correlated symbolic values in curve
    ///         integrals cause exponential state-space blowup).
    function check_RedeemPreservesBackingInvariant(uint256 redeemAmt) public {
        uint256 buyAmt = 10 ether;
        vm.assume(redeemAmt >= 1 ether && redeemAmt <= buyAmt);
        vm.assume(redeemAmt % 1 ether == 0);

        (uint256 total, , ) = token.quoteBuy(buyAmt);

        vm.startPrank(user);
        token.buy{value: total}(buyAmt);
        token.redeem(redeemAmt);
        vm.stopPrank();

        assert(address(token).balance >= token.curveBackingRequired());
    }

    /// @notice Conservation of ETH on a single buy: contract balance equals
    ///         exactly the ETH paid in, for any whole amount.
    function check_ConservationOfEthOnBuy(uint256 amount) public {
        vm.assume(amount >= 1 ether && amount <= 100 ether);
        vm.assume(amount % 1 ether == 0);

        (uint256 total, , ) = token.quoteBuy(amount);
        uint256 balanceBefore = address(token).balance;

        vm.prank(user);
        token.buy{value: total}(amount);

        assert(address(token).balance == balanceBefore + total);
    }

    /// @notice Round-tripping the curve can never be profitable: the user's
    ///         ETH balance after buy+redeem must be ≤ their balance before.
    ///         This is the "no free money" property, symbolically verified.
    function check_NoFreeMoneyOnRoundTrip(uint256 amount) public {
        vm.assume(amount >= 1 ether && amount <= 100 ether);
        vm.assume(amount % 1 ether == 0);

        (uint256 total, , ) = token.quoteBuy(amount);
        uint256 userBefore = user.balance;

        vm.startPrank(user);
        token.buy{value: total}(amount);
        token.redeem(amount);
        vm.stopPrank();

        assert(user.balance <= userBefore);
    }
}
