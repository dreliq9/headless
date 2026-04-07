// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Headless} from "../src/Headless.sol";

/// @notice Deploy Headless (HDLS). The deployer (broadcasting EOA) becomes
///         `founder` and receives FOUNDER_ALLOCATION. The two constructor
///         arguments configure the Dutch auction cadence:
///
///           AUCTION_INTERVAL = blocks between consecutive auctions
///           AUCTION_WINDOW   = blocks of Dutch decay per auction
///
///         Defaults below target Ethereum L1 (~12 s blocks → 5 min cadence).
///         For L2 deployments, override these to match the target chain's
///         block time so the wall-clock cadence stays sane:
///
///           Base / Optimism (~2 s blocks):  150, 150  (≈ 5 min cadence)
///           Arbitrum (~250 ms blocks):     1200, 1200 (≈ 5 min cadence)
///
///         Example:
///           forge script script/Deploy.s.sol \
///             --rpc-url $BASE_RPC --broadcast --verify
contract Deploy is Script {
    uint256 public constant DEFAULT_AUCTION_INTERVAL = 25;
    uint256 public constant DEFAULT_AUCTION_WINDOW   = 25;

    function run() external {
        vm.startBroadcast();
        Headless token = new Headless(DEFAULT_AUCTION_INTERVAL, DEFAULT_AUCTION_WINDOW);
        vm.stopBroadcast();

        console2.log("Headless deployed at:", address(token));
        console2.log("Founder (deployer):",  token.founder());
        console2.log("Founder allocation:",  token.FOUNDER_ALLOCATION());
        console2.log("Max supply:",          token.MAX_SUPPLY());
        console2.log("Launch block:",        token.launchBlock());
    }
}
