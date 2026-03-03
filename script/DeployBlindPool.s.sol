// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BlindPoolCCA} from "../src/BlindPoolCCA.sol";
import {ContinuousClearingAuction} from "continuous-clearing-auction/ContinuousClearingAuction.sol";

/// @title DeployBlindPool
/// @notice Deploy the BlindPoolCCA privacy wrapper on Sepolia.
///         Requires an existing CCA auction address in AUCTION_ADDRESS env var.
contract DeployBlindPool is Script {
    function run() public {
        address auctionAddress = vm.envAddress("AUCTION_ADDRESS");

        ContinuousClearingAuction cca = ContinuousClearingAuction(auctionAddress);

        uint64 ccaEndBlock = cca.endBlock();
        uint64 ccaStartBlock = cca.startBlock();

        // Blind bid deadline: stop accepting encrypted bids 20 blocks before CCA ends
        // This gives enough time to reveal + forward bids to the real CCA
        uint64 blindDeadline = ccaEndBlock - 20;

        console2.log("=== BlindPool Deployment ===");
        console2.log("CCA Address:", auctionAddress);
        console2.log("CCA Start Block:", ccaStartBlock);
        console2.log("CCA End Block:", ccaEndBlock);
        console2.log("Blind Bid Deadline:", blindDeadline);
        console2.log("Current Block:", block.number);

        vm.startBroadcast();

        BlindPoolCCA blindPool = new BlindPoolCCA(auctionAddress, blindDeadline);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("BlindPoolCCA deployed to:", address(blindPool));
        console2.log("Admin:", blindPool.admin());
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Users submit sealed bids via frontend (submitBlindBid(commitment) with escrow)");
        console2.log("  2. After block", blindDeadline, "CRE workflow finalizes and calls forwardBidToCCA / forwardBidsToCCA (admin only)");
    }
}
