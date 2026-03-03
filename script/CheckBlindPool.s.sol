// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BlindPoolCCA} from "../src/BlindPoolCCA.sol";

/// @title CheckBlindPool
/// @notice View the current status of a BlindPoolCCA deployment
contract CheckBlindPool is Script {
    function run() public view {
        address blindPoolAddress = vm.envAddress("BLIND_POOL_ADDRESS");

        BlindPoolCCA blindPool = BlindPoolCCA(payable(blindPoolAddress));

        console2.log("=== BlindPool Status ===");
        console2.log("BlindPool Address:", blindPoolAddress);
        console2.log("CCA Address:", address(blindPool.cca()));
        console2.log("Admin:", blindPool.admin());

        console2.log("");
        console2.log("=== Timing ===");
        console2.log("Current Block:", block.number);
        console2.log("Blind Bid Deadline:", blindPool.blindBidDeadline());

        bool acceptingBids = block.number < blindPool.blindBidDeadline();
        console2.log("Accepting Blind Bids:", acceptingBids);
        if (acceptingBids) {
            console2.log("Blocks Until Deadline:", blindPool.blindBidDeadline() - uint64(block.number));
        }

        console2.log("");
        console2.log("=== Bids ===");
        console2.log("Total Blind Bids:", blindPool.nextBlindBidId());
        console2.log("ETH Balance (escrow):", address(blindPool).balance);

        // Show individual bid info (public fields only)
        uint256 totalBids = blindPool.nextBlindBidId();
        if (totalBids > 0) {
            console2.log("");
            console2.log("=== Individual Bids ===");
            for (uint256 i = 0; i < totalBids && i < 20; i++) {
                (address bidder, uint256 ethDeposit, bool forwarded, bytes32 bidCommitment) = blindPool.getBlindBidInfo(i);
                console2.log("  Bid", i, ":");
                console2.log("    Bidder:", bidder);
                console2.log("    ETH Deposit:", ethDeposit);
                console2.log("    Forwarded to CCA:", forwarded);
                console2.log("    Commitment:", uint256(bidCommitment));
                if (forwarded) {
                    console2.log("    CCA Bid ID:", blindPool.ccaBidIds(i));
                }
            }
        }
    }
}
