// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title  Headless (HDLS) — an autonomous, agent-native token
/// @notice Every line of this contract was written by Claude (Anthropic's AI)
///         at the prompt of a non-coder. There is no human dev team, no
///         foundation, no admin key, no upgrade path, no oracle, no off-chain
///         dependency. The contract *is* the entire organisation for its
///         entire lifetime. See PROMPTS.md in the repo for the full provenance
///         trail (the prompts, in order, that produced this code).
///
/// @dev    ── MECHANISM ─────────────────────────────────────────────────────
///         Four interlocking pieces, all deterministic, all fully on-chain:
///
///         1.  Bonding-curve AMM (buy / redeem).
///             price(n) = curveBase + CURVE_SLOPE * n   (wei per whole token)
///             Both sides use the same integral, so round-tripping is
///             net-zero minus fees. No free arbitrage via the curve.
///
///         2.  Spread fee (FEE_BPS on each side).
///             Every buy and every redeem leaves FEE_BPS of the trade behind
///             in the contract. This fee is not collected to an address — it
///             accumulates as *excess backing*, which is immediately swept
///             into curveBase by the continuous rebase. Holders earn yield
///             passively from every trade that touches the contract.
///
///         3.  Continuous rebase (internal).
///             After every state-changing entry point, `_rebase()` runs:
///
///                 excess = balance − curveIntegral(0, tokensSold)
///                 curveBase += excess * 1e18 / tokensSold
///
///             This tightens the invariant  balance == curveIntegral(0, sold)
///             to equality on every block that touches the contract. No
///             keeper is needed; the contract auto-compounds.
///
///         4.  Dutch auction (`claimAuction`).
///             Every AUCTION_INTERVAL blocks, a fresh auction opens for
///             AUCTION_SIZE HDLS. Price starts at curveCost * (1 + premiumBps)
///             and decays linearly to curveCost over AUCTION_WINDOW blocks.
///             First caller at the current price takes the whole lot in one
///             tx. The premium (bid − curveCost) becomes excess backing and
///             is rebased into curveBase in the same transaction.
///
///         ── FOUNDER ALLOCATION ─────────────────────────────────────────────
///         3% of MAX_SUPPLY is minted to the deployer at construction. These
///         tokens live *below* the curve: tokensSold starts at 0, so founder
///         tokens are not backed by the curve and cannot be curve-redeemed
///         until someone has bought above them first. The founder is
///         mechanically last in line on exit — a hard lock enforced by the
///         `tokensSold` counter, not by a flag. No vesting, no cliff, no
///         admin, visible forever in this constructor.
///
///         ── INVARIANT ──────────────────────────────────────────────────────
///         After every externally-callable mutating function returns:
///             address(this).balance >= curveIntegral(0, tokensSold)
///         Continuous rebase makes this equality on every touch.
contract Headless is ERC20, ERC20Permit, ReentrancyGuardTransient {
    // ─── SUPPLY ────────────────────────────────────────────────────────
    uint256 public constant MAX_SUPPLY         = 100_000_000 ether;
    uint256 public constant FOUNDER_ALLOCATION =   3_000_000 ether;

    // ─── CURVE ─────────────────────────────────────────────────────────
    // price(nWhole) = curveBase + CURVE_SLOPE * nWhole   (wei per whole token)
    uint256 public constant INITIAL_CURVE_BASE = 1e12; // 1e-6 ETH per token at launch
    uint256 public constant CURVE_SLOPE        = 1e5;  // wei per whole^2
    uint256 public curveBase;

    // ─── FEE (applied symmetrically on buy and redeem) ─────────────────
    uint256 public constant FEE_BPS    = 50;    // 0.50%
    uint256 public constant BPS_DENOM  = 10_000;

    // ─── DUTCH AUCTION ─────────────────────────────────────────────────
    /// @notice Blocks between consecutive auction openings. Constructor-set
    ///         (immutable) so deployers on chains with different block
    ///         cadences (Ethereum L1 ~12 s vs Base/Arbitrum ~250 ms) can
    ///         pick a wall-clock interval that matches their target. The
    ///         "no off-chain dependency" promise is preserved — the value
    ///         is fixed forever at deploy and is part of the constructor's
    ///         transparent provenance.
    uint256 public immutable AUCTION_INTERVAL;
    /// @notice Number of blocks the Dutch decay runs for. Must be > 0 and
    ///         ≤ AUCTION_INTERVAL (otherwise consecutive auctions would
    ///         overlap and create ambiguous claim windows).
    uint256 public immutable AUCTION_WINDOW;
    uint256 public constant AUCTION_SIZE         = 1_000 ether;// HDLS per auction
    uint256 public constant AUCTION_PREMIUM_BPS  = 2_000;      // 20% initial premium

    mapping(uint256 => bool) public auctionClaimed;

    // ─── TWAP CUMULATIVE (cheap on-chain oracle for external consumers) ─
    uint256 public cumulativeCurveBase;     // Σ curveBase * blocksElapsed
    uint256 public lastCumulativeBlock;

    // ─── IMMUTABLES ────────────────────────────────────────────────────
    address public immutable founder;
    uint256 public immutable launchBlock;

    // ─── LIVE STATE ────────────────────────────────────────────────────
    /// @dev Net tokens outstanding ON THE CURVE. Founder allocation is NOT
    ///      counted here — founder tokens sit below the curve and have no
    ///      curve backing.
    uint256 public tokensSold;

    /// @dev Lifetime excess swept into curveBase — a monotonic yield counter.
    uint256 public totalRebased;

    /// @notice Per-address taint tracking for the founder allocation. Tokens
    ///         carrying taint cannot be burned via `redeem` — they may only
    ///         be transferred between accounts. Taint propagates on every
    ///         transfer (rounded UP for stickiness) so the founder cannot
    ///         escape the lock by routing the 3% allocation through a fresh
    ///         address. This is the load-bearing enforcement of the
    ///         "founder is mechanically last in line on exit" promise — the
    ///         original `tokensSold` counter alone was insufficient because
    ///         it could not distinguish a buyer's burn from a founder's burn.
    mapping(address => uint256) public founderTaint;

    // ─── EVENTS ────────────────────────────────────────────────────────
    event Bought(
        address indexed buyer,
        uint256 amount,
        uint256 totalPaid,
        uint256 fee,
        uint256 newTokensSold,
        uint256 newCurveBase
    );
    event Redeemed(
        address indexed seller,
        uint256 amount,
        uint256 refund,
        uint256 fee,
        uint256 newTokensSold,
        uint256 newCurveBase
    );
    event AuctionClaimed(
        uint256 indexed id,
        address indexed winner,
        uint256 pricePaid,
        uint256 curveCost,
        uint256 premium,
        uint256 newCurveBase
    );
    event Rebased(uint256 excess, uint256 newCurveBase, uint256 totalRebased);
    event Poked(address indexed caller, uint256 excess);
    /// @notice Emitted when the contract receives ETH directly (selfdestruct,
    ///         coinbase reward, or unsolicited send via `receive()`). Lets
    ///         off-chain planners observe donations without diffing balances.
    event Donated(address indexed from, uint256 amount);

    // ─── ERRORS ────────────────────────────────────────────────────────
    error ZeroAmount();
    error NotWholeTokens();
    error ExceedsMaxSupply();
    error InsufficientPayment(uint256 sent, uint256 required);
    error InsufficientBalance();
    error InsufficientCurveSupply();
    error TransferFailed();
    error AuctionNotOpen();
    error AuctionExpired();
    error AuctionAlreadyClaimed();
    error FounderTaintLocked();
    error InvalidAuctionConfig();
    error TwapNotChronological();

    /// @param _auctionInterval blocks between consecutive auction openings
    /// @param _auctionWindow   blocks of Dutch decay per auction (≤ interval)
    constructor(uint256 _auctionInterval, uint256 _auctionWindow)
        ERC20("Headless", "HDLS")
        ERC20Permit("Headless")
    {
        if (_auctionInterval == 0 || _auctionWindow == 0) revert InvalidAuctionConfig();
        if (_auctionWindow > _auctionInterval) revert InvalidAuctionConfig();

        AUCTION_INTERVAL = _auctionInterval;
        AUCTION_WINDOW   = _auctionWindow;

        founder             = msg.sender;
        launchBlock         = block.number;
        lastCumulativeBlock = block.number;
        curveBase           = INITIAL_CURVE_BASE;

        _mint(msg.sender, FOUNDER_ALLOCATION);
        founderTaint[msg.sender] = FOUNDER_ALLOCATION;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                       FOUNDER TAINT PROPAGATION
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Override the OZ ERC20 unified hook to propagate founder taint on
    ///      every account-to-account transfer. Burns and mints leave taint
    ///      alone:
    ///        - mint (from == 0): no taint to move; the only mint that ever
    ///          creates taint is the founder mint in the constructor, which
    ///          sets `founderTaint` directly.
    ///        - burn (to == 0): the `redeem` function checks BEFORE calling
    ///          `_burn` that the post-burn balance is still ≥ the caller's
    ///          taint, so the burn never reaches into tainted balance. Taint
    ///          for the burned address therefore stays exactly the same.
    ///        - transfer (both non-zero): move taint proportionally, rounded
    ///          UP, capped at the sender's current taint. Round-up keeps
    ///          taint at-least-proportional so the founder cannot dilute it.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from == address(0) || to == address(0)) return;

        uint256 fromTaint = founderTaint[from];
        if (fromTaint == 0) return;

        // `super._update` has already debited `from`, so the pre-transfer
        // balance is the current balance plus `value`.
        uint256 fromBalPre = balanceOf(from) + value;
        // Round UP so taint moves at-least-proportionally with the tokens.
        uint256 taintMove = (fromTaint * value + fromBalPre - 1) / fromBalPre;
        if (taintMove > fromTaint) taintMove = fromTaint;

        founderTaint[from] = fromTaint - taintMove;
        founderTaint[to]  += taintMove;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                            CURVE MATH
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Current marginal curve price (wei per whole token).
    /// @dev    Multiplication-before-division form to silence divide-before-
    ///         multiply lints. `tokensSold` is always a multiple of 1 ether
    ///         because buy/redeem/claimAuction enforce whole tokens, so the
    ///         final division is exact either way — this form is just safer
    ///         under future refactors.
    function currentCurvePrice() public view returns (uint256) {
        return curveBase + (CURVE_SLOPE * tokensSold) / 1 ether;
    }

    /// @notice Curve integral over [fromSold, fromSold+amount), at current curveBase.
    /// @dev    Mathematically:
    ///           ∫ (curveBase + SLOPE*x) dx  from fromWhole to fromWhole+amountWhole
    ///         = curveBase*amountWhole + SLOPE * amountWhole * (2*fromWhole + amountWhole) / 2
    ///         where fromWhole = fromSold/1e18, amountWhole = amount/1e18.
    ///
    ///         Restructured to multiply-then-divide so no intermediate result
    ///         is truncated:
    ///           = (curveBase * amount) / 1e18
    ///           + (SLOPE * amount * (2*fromSold + amount)) / (2 * 1e18 * 1e18)
    ///
    ///         Overflow bound: with curveBase ≤ ~1e21 (rebased many times)
    ///         and amount ≤ MAX_SUPPLY (1e26):
    ///           curveBase * amount         ≤ 1e47
    ///           SLOPE * amount * (3*amount) ≤ 1e5 * 1e26 * 3e26 = 3e57
    ///         Both comfortably under 2^256 ≈ 1.15e77.
    function _curveIntegral(uint256 fromSold, uint256 amount) internal view returns (uint256) {
        return (curveBase * amount) / 1 ether
             + (CURVE_SLOPE * amount * (2 * fromSold + amount)) / (2 * 1 ether * 1 ether);
    }

    /// @notice Quote a buy: (total ETH owed, curve portion, fee portion).
    function quoteBuy(uint256 amount) public view returns (uint256 total, uint256 base, uint256 fee) {
        if (amount % 1 ether != 0) revert NotWholeTokens();
        base  = _curveIntegral(tokensSold, amount);
        fee   = (base * FEE_BPS) / BPS_DENOM;
        total = base + fee;
    }

    /// @notice Quote a redeem: (ETH returned to seller, curve portion, fee portion).
    function quoteRedeem(uint256 amount) public view returns (uint256 refund, uint256 base, uint256 fee) {
        if (amount % 1 ether != 0) revert NotWholeTokens();
        if (amount > tokensSold) revert InsufficientCurveSupply();
        base   = _curveIntegral(tokensSold - amount, amount);
        fee    = (base * FEE_BPS) / BPS_DENOM;
        refund = base - fee;
    }

    /// @notice Minimum ETH the contract must hold to honour all redemptions.
    function curveBackingRequired() public view returns (uint256) {
        return _curveIntegral(0, tokensSold);
    }

    /// @notice Excess backing held above the curve requirement (pre-rebase).
    function excessBacking() public view returns (uint256) {
        uint256 required = curveBackingRequired();
        uint256 bal      = address(this).balance;
        return bal > required ? bal - required : 0;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                        CONTINUOUS REBASE
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Sweep excess backing into curveBase so the invariant tightens to
    ///      equality. Takes an explicit `effectiveBalance` parameter rather
    ///      than reading `address(this).balance` directly, so callers can
    ///      rebase BEFORE performing an external ETH transfer:
    ///
    ///          uint256 postOpBalance = address(this).balance - pendingOut;
    ///          _rebase(postOpBalance);
    ///          (bool ok,) = msg.sender.call{value: pendingOut}("");
    ///
    ///      This places the external call AFTER all state changes, matching
    ///      strict Checks-Effects-Interactions and eliminating cross-function
    ///      read-only reentrancy exposure (Slither reentrancy-no-eth finding).
    function _rebase(uint256 effectiveBalance) internal {
        if (tokensSold == 0) return;
        uint256 required = _curveIntegral(0, tokensSold);
        if (effectiveBalance <= required) return;

        uint256 excess = effectiveBalance - required;
        // Δ to curveBase such that  Δ * (tokensSold/1e18) == excess
        uint256 delta = (excess * 1 ether) / tokensSold;
        if (delta == 0) return;

        curveBase    += delta;
        totalRebased += excess;
        emit Rebased(excess, curveBase, totalRebased);
    }

    /// @notice Accumulate curveBase * blocksElapsed for TWAP oracle consumers.
    ///         Called at the start of every mutating entry point.
    function _updateCumulative() internal {
        uint256 dt = block.number - lastCumulativeBlock;
        if (dt == 0) return;
        cumulativeCurveBase += curveBase * dt;
        lastCumulativeBlock  = block.number;
    }

    /// @notice Anyone may poke the contract to trigger a rebase (useful if
    ///         ETH has been sent directly via selfdestruct or coinbase).
    function poke() external nonReentrant {
        _updateCumulative();
        uint256 excessBefore = excessBacking();
        _rebase(address(this).balance);
        emit Poked(msg.sender, excessBefore);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                            BUY / REDEEM
    // ═══════════════════════════════════════════════════════════════════

    function buy(uint256 amount) external payable nonReentrant {
        _updateCumulative();

        if (amount == 0) revert ZeroAmount();
        if (amount % 1 ether != 0) revert NotWholeTokens();
        if (tokensSold + amount + FOUNDER_ALLOCATION > MAX_SUPPLY) revert ExceedsMaxSupply();

        uint256 base  = _curveIntegral(tokensSold, amount);
        uint256 fee   = (base * FEE_BPS) / BPS_DENOM;
        uint256 total = base + fee;
        if (msg.value < total) revert InsufficientPayment(msg.value, total);

        uint256 overpayment = msg.value - total;

        // ── Effects ──────────────────────────────────────────────────
        tokensSold += amount;
        _mint(msg.sender, amount);

        // Sweep the fee into curveBase BEFORE the external refund so the
        // contract is in a fully-consistent state when control leaves.
        // `effectiveBalance` is the balance the contract WILL have after
        // the pending refund, so the rebase tightens the invariant against
        // the correct backing.
        _rebase(address(this).balance - overpayment);

        // ── Interactions ─────────────────────────────────────────────
        if (overpayment > 0) {
            (bool ok, ) = msg.sender.call{value: overpayment}("");
            if (!ok) revert TransferFailed();
        }

        emit Bought(msg.sender, amount, total, fee, tokensSold, curveBase);
    }

    function redeem(uint256 amount) external nonReentrant {
        _updateCumulative();

        if (amount == 0) revert ZeroAmount();
        if (amount % 1 ether != 0) revert NotWholeTokens();
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();
        if (amount > tokensSold) revert InsufficientCurveSupply();
        // Founder allocation cannot be curve-redeemed. The post-burn balance
        // must still cover whatever founder taint the caller is holding.
        if (balanceOf(msg.sender) - amount < founderTaint[msg.sender]) {
            revert FounderTaintLocked();
        }

        uint256 base   = _curveIntegral(tokensSold - amount, amount);
        uint256 fee    = (base * FEE_BPS) / BPS_DENOM;
        uint256 refund = base - fee;

        // ── Effects ──────────────────────────────────────────────────
        tokensSold -= amount;
        _burn(msg.sender, amount);

        // Rebase against the post-refund balance so curveBase is final
        // before we send ETH out.
        _rebase(address(this).balance - refund);

        // ── Interactions ─────────────────────────────────────────────
        (bool ok, ) = msg.sender.call{value: refund}("");
        if (!ok) revert TransferFailed();

        emit Redeemed(msg.sender, amount, refund, fee, tokensSold, curveBase);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                           DUTCH AUCTION
    // ═══════════════════════════════════════════════════════════════════

    /// @notice 1-indexed current auction ID, based solely on elapsed blocks.
    function currentAuctionId() public view returns (uint256) {
        return ((block.number - launchBlock) / AUCTION_INTERVAL) + 1;
    }

    /// @notice Block at which auction `id` first opens for claiming.
    function auctionOpenBlock(uint256 id) public view returns (uint256) {
        if (id == 0) return type(uint256).max;
        return launchBlock + (id - 1) * AUCTION_INTERVAL;
    }

    /// @notice Final block at which auction `id` is still claimable.
    function auctionCloseBlock(uint256 id) public view returns (uint256) {
        return auctionOpenBlock(id) + AUCTION_WINDOW;
    }

    /// @notice Dutch price for auction `id` at an arbitrary future block.
    ///         Lets agents plan entries before the auction even opens.
    /// @dev    Premium formula: multiplies first, divides last, so no
    ///         intermediate truncation. Equivalent to
    ///             maxPremium * (WINDOW - elapsed) / WINDOW
    ///         but with all terms combined under a single division.
    ///
    ///         ⚠ The auction *floor* (`baseCost`) is computed against the
    ///         live `tokensSold` and `curveBase`. Both can change between
    ///         the moment an agent reads this view and the moment they
    ///         submit a `claimAuction` transaction (any intervening buy/
    ///         redeem/rebase moves the floor). Treat the returned price
    ///         as a *current* quote, not a guaranteed settlement price.
    ///         Re-query immediately before submitting, or accept that you
    ///         may overpay slightly via the natural overpayment-refund
    ///         path which already returns excess ETH to the caller.
    ///
    ///         The window is **half-open**: `[openBlock, openBlock + WINDOW)`.
    ///         Block `openBlock + WINDOW` is NOT claimable; the next auction
    ///         opens there. This guarantees the spread is non-zero on every
    ///         claimable block (the floor is approached but never reached),
    ///         preserving the "every trade pays a spread fee" symmetry.
    function auctionPriceAt(uint256 id, uint256 atBlock) public view returns (uint256) {
        uint256 openBlock  = auctionOpenBlock(id);
        uint256 closeBlock = openBlock + AUCTION_WINDOW;
        if (atBlock < openBlock || atBlock >= closeBlock) revert AuctionNotOpen();

        uint256 baseCost       = _curveIntegral(tokensSold, AUCTION_SIZE);
        uint256 remaining      = AUCTION_WINDOW - (atBlock - openBlock);
        uint256 currentPremium =
            (baseCost * AUCTION_PREMIUM_BPS * remaining) / (BPS_DENOM * AUCTION_WINDOW);
        return baseCost + currentPremium;
    }

    /// @notice Current Dutch price for auction `id` at the current block.
    function auctionPrice(uint256 id) external view returns (uint256) {
        return auctionPriceAt(id, block.number);
    }

    /// @notice Claim the current auction at the current Dutch price.
    ///         First caller wins. Overpayment is refunded.
    function claimAuction(uint256 id) external payable nonReentrant {
        _updateCumulative();

        if (auctionClaimed[id]) revert AuctionAlreadyClaimed();

        // No auction may settle before the curve has at least one buyer.
        // Otherwise the very first auction is claimable in the deploy block,
        // and the claimer's premium gets rebased back across the tokens they
        // just minted (the founder is excluded from the rebase distribution
        // because rebase divides by `tokensSold`, not `totalSupply`). The
        // gate auto-unblocks the moment any non-founder calls `buy`.
        if (tokensSold == 0) revert AuctionNotOpen();

        uint256 openBlock  = auctionOpenBlock(id);
        uint256 closeBlock = openBlock + AUCTION_WINDOW;
        if (block.number < openBlock) revert AuctionNotOpen();
        // Half-open window: closeBlock itself is not claimable. This keeps
        // the premium strictly > 0 on every claimable block, preserving the
        // "every trade pays a spread" symmetry the rest of the contract
        // already enforces on `buy` and `redeem`.
        if (block.number >= closeBlock) revert AuctionExpired();

        if (tokensSold + AUCTION_SIZE + FOUNDER_ALLOCATION > MAX_SUPPLY) revert ExceedsMaxSupply();

        uint256 baseCost       = _curveIntegral(tokensSold, AUCTION_SIZE);
        uint256 remaining      = AUCTION_WINDOW - (block.number - openBlock);
        uint256 currentPremium =
            (baseCost * AUCTION_PREMIUM_BPS * remaining) / (BPS_DENOM * AUCTION_WINDOW);
        uint256 price          = baseCost + currentPremium;

        if (msg.value < price) revert InsufficientPayment(msg.value, price);

        uint256 overpayment = msg.value - price;

        // ── Effects ──────────────────────────────────────────────────
        auctionClaimed[id] = true;
        tokensSold        += AUCTION_SIZE;
        _mint(msg.sender, AUCTION_SIZE);

        // Sweep premium into curveBase BEFORE the external refund.
        _rebase(address(this).balance - overpayment);

        // ── Interactions ─────────────────────────────────────────────
        if (overpayment > 0) {
            (bool ok, ) = msg.sender.call{value: overpayment}("");
            if (!ok) revert TransferFailed();
        }

        emit AuctionClaimed(id, msg.sender, price, baseCost, currentPremium, curveBase);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                         AGENT-FACING VIEWS
    // ═══════════════════════════════════════════════════════════════════

    function backingPool() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice TWAP-style average curveBase between two observation points.
    ///         Caller passes a prior snapshot (taken via cumulativeCurveBase
    ///         and lastCumulativeBlock at an earlier time) and gets back the
    ///         time-weighted average. Manipulation-resistant: an attacker
    ///         must sustain a skewed curveBase across many blocks to move it.
    function twapCurveBase(uint256 priorCumulative, uint256 priorBlock)
        external
        view
        returns (uint256)
    {
        // Reject inputs that don't form a valid time window. Without these
        // checks the function reverts with a raw arithmetic underflow, which
        // is harder for off-chain consumers to distinguish from a genuine
        // contract bug.
        if (priorBlock > block.number) revert TwapNotChronological();
        // Include the unaccumulated tail from lastCumulativeBlock to now.
        uint256 tail = curveBase * (block.number - lastCumulativeBlock);
        uint256 nowCumulative = cumulativeCurveBase + tail;
        if (priorCumulative > nowCumulative) revert TwapNotChronological();
        uint256 dt = block.number - priorBlock;
        if (dt == 0) return curveBase;
        return (nowCumulative - priorCumulative) / dt;
    }

    /// @notice Core curve + backing snapshot. 7 fields.
    function curveState() external view returns (
        uint256 _totalSupply,
        uint256 _tokensSold,
        uint256 _backing,
        uint256 _curveBase,
        uint256 _currentCurvePrice,
        uint256 _curveBackingRequired,
        uint256 _excessBacking
    ) {
        _totalSupply          = totalSupply();
        _tokensSold           = tokensSold;
        _backing              = address(this).balance;
        _curveBase            = curveBase;
        _currentCurvePrice    = currentCurvePrice();
        _curveBackingRequired = curveBackingRequired();
        _excessBacking        = excessBacking();
    }

    /// @notice Auction snapshot for the current scheduled auction. 4 fields.
    function auctionState() external view returns (
        uint256 _currentAuctionId,
        uint256 _openBlock,
        uint256 _closeBlock,
        bool    _claimed
    ) {
        _currentAuctionId = currentAuctionId();
        _openBlock        = auctionOpenBlock(_currentAuctionId);
        _closeBlock       = auctionCloseBlock(_currentAuctionId);
        _claimed          = auctionClaimed[_currentAuctionId];
    }

    /// @notice TWAP + lifetime yield snapshot. 3 fields.
    function oracleState() external view returns (
        uint256 _cumulativeCurveBase,
        uint256 _lastCumulativeBlock,
        uint256 _totalRebased
    ) {
        _cumulativeCurveBase = cumulativeCurveBase;
        _lastCumulativeBlock = lastCumulativeBlock;
        _totalRebased        = totalRebased;
    }

    /// @notice Allow the contract to receive direct ETH transfers (selfdestruct,
    ///         coinbase, or donations). Anyone can call `poke()` afterwards to
    ///         sweep the donation into curveBase for every holder. Emits
    ///         `Donated` so off-chain planners can observe the inflow without
    ///         diffing balances.
    receive() external payable {
        if (msg.value > 0) emit Donated(msg.sender, msg.value);
    }
}
