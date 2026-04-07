// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Headless} from "../src/Headless.sol";

/// @notice Deploy Headless (HDLS). No constructor args — the deployer (the
///         broadcasting EOA) becomes `founder` and receives FOUNDER_ALLOCATION.
///         Example:
///           forge script script/Deploy.s.sol \
///             --rpc-url $BASE_RPC --broadcast --verify
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Headless token = new Headless();
        vm.stopBroadcast();

        console2.log("Headless deployed at:", address(token));
        console2.log("Founder (deployer):",  token.founder());
        console2.log("Founder allocation:",  token.FOUNDER_ALLOCATION());
        console2.log("Max supply:",          token.MAX_SUPPLY());
        console2.log("Launch block:",        token.launchBlock());
    }
}
