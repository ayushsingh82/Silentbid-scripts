// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BlindPoolFactory} from "../src/BlindPoolFactory.sol";

/// @title DeployBlindPoolFactory
/// @notice One-time deploy of BlindPoolFactory. After this, anyone can deploy BlindPools from the UI.
contract DeployBlindPoolFactory is Script {
    function run() public {
        vm.startBroadcast();
        BlindPoolFactory factory = new BlindPoolFactory();
        vm.stopBroadcast();
        console2.log("BlindPoolFactory deployed to:", address(factory));
        console2.log("Set in app: NEXT_PUBLIC_BLIND_POOL_FACTORY_ADDRESS=", address(factory));
    }
}
