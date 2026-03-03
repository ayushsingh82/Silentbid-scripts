// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { BlindPoolCCA } from "../src/BlindPoolCCA.sol";

/// @title RevealBlindPool (CRE flow — no onchain reveal)
/// @notice With CRE integration, there is no requestReveal(). After the blind bid deadline,
///         the CRE workflow loads stored bids, computes clearing price, and calls
///         forwardBidToCCA / forwardBidsToCCA (admin-only). This script only prints status.
contract RevealBlindPool is Script {
    function run() public view {
        address blindPoolAddress = vm.envAddress("BLIND_POOL_ADDRESS");

        BlindPoolCCA blindPool = BlindPoolCCA(payable(blindPoolAddress));

        console2.log("=== BlindPool Status (CRE flow) ===");
        console2.log("BlindPool Address:", blindPoolAddress);
        console2.log("Blind Bid Deadline:", blindPool.blindBidDeadline());
        console2.log("Current Block:", block.number);
        console2.log("Total Blind Bids:", blindPool.nextBlindBidId());

        if (block.number < blindPool.blindBidDeadline()) {
            console2.log("Still accepting sealed bids. After deadline, run CRE finalization workflow.");
        } else {
            console2.log("Deadline passed. CRE workflow should call forwardBidToCCA(blindBidId, maxPrice, amount, owner, hookData) for each bid (admin only).");
        }
    }
}
