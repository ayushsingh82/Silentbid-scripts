// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BlindPoolCCA} from "../src/BlindPoolCCA.sol";

/// @title RevealBlindPool
/// @notice Call requestReveal() on BlindPoolCCA after the blind bid deadline.
///         This marks all encrypted bids as publicly decryptable via the Zama KMS.
/// @dev After this tx confirms, use the relayer SDK off-chain to:
///      1. instance.publicDecrypt([handle1, handle2, ...]) for each bid
///      2. Call forwardBidToCCA() with the decrypted values + KMS proof
contract RevealBlindPool is Script {
    function run() public {
        address blindPoolAddress = vm.envAddress("BLIND_POOL_ADDRESS");

        BlindPoolCCA blindPool = BlindPoolCCA(payable(blindPoolAddress));

        console2.log("=== BlindPool Reveal ===");
        console2.log("BlindPool Address:", blindPoolAddress);
        console2.log("Blind Bid Deadline:", blindPool.blindBidDeadline());
        console2.log("Current Block:", block.number);
        console2.log("Total Blind Bids:", blindPool.nextBlindBidId());
        console2.log("Already Revealed:", blindPool.revealed());

        require(block.number >= blindPool.blindBidDeadline(), "Blind bid deadline not reached");
        require(!blindPool.revealed(), "Already revealed");

        vm.startBroadcast();

        blindPool.requestReveal();

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Reveal Complete ===");
        console2.log("All", blindPool.nextBlindBidId(), "bids are now publicly decryptable.");
        console2.log("");
        console2.log("Next: use the relayer SDK to decrypt and forward each bid:");
        console2.log("  const results = await instance.publicDecrypt([priceHandle, amountHandle]);");
        console2.log("  await blindPool.forwardBidToCCA(bidId, price, amount, proof);");
    }
}
