// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import "encrypted-types/EncryptedTypes.sol";
import {FHE} from "@fhevm/solidity/lib/FHE.sol";
import {BlindPoolCCA} from "../../src/BlindPoolCCA.sol";

contract TestBlindPoolOnly is BlindPoolCCA {
    constructor(address _cca, uint64 _deadline) BlindPoolCCA(_cca, _deadline) {}

    function mockSubmitBlindBid(uint64 _maxPrice, uint64 _amount) external payable {
        if (block.number >= blindBidDeadline) revert AuctionClosed();
        if (msg.value == 0) revert NoDeposit();

        euint64 encPrice = FHE.asEuint64(_maxPrice);
        euint64 encAmt = FHE.asEuint64(_amount);

        uint256 bidId = nextBlindBidId++;
        _blindBids[bidId] = BlindBid({
            bidder: msg.sender,
            encMaxPrice: encPrice,
            encAmount: encAmt,
            ethDeposit: msg.value,
            forwarded: false
        });

        ebool isHigher = FHE.lt(_encHighestPrice, encPrice);
        _encHighestPrice = FHE.select(isHigher, encPrice, _encHighestPrice);
        FHE.allowThis(_encHighestPrice);
        _encTotalDemand = FHE.add(_encTotalDemand, encAmt);
        FHE.allowThis(_encTotalDemand);
        FHE.allowThis(encPrice);
        FHE.allowThis(encAmt);
        FHE.allow(encPrice, msg.sender);
        FHE.allow(encAmt, msg.sender);

        emit BlindBidPlaced(bidId, msg.sender);
    }
}

contract DeployBlindPoolOnly is Script {
    function run() public {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        uint64 deadline = uint64(vm.envUint("BLIND_DEADLINE"));
        // Use AUCTION_ADDRESS env if set, else address(1) as dummy
        address ccaAddr = vm.envOr("AUCTION_ADDRESS", address(1));

        vm.startBroadcast(pk);
        TestBlindPoolOnly pool = new TestBlindPoolOnly(ccaAddr, deadline);
        vm.stopBroadcast();

        console2.log("BLINDPOOL:", address(pool));
        console2.log("DEADLINE:", deadline);

        vm.writeFile(".forge-snapshots/app/blindpool.txt", vm.toString(address(pool)));
        vm.writeFile(".forge-snapshots/app/blind_deadline.txt", vm.toString(uint256(deadline)));
    }
}
