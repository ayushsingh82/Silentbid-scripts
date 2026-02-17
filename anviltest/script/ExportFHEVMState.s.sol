// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {HostContractsDeployerTestUtils} from "@fhevm-foundry/HostContractsDeployerTestUtils.sol";
import {
    aclAdd,
    fhevmExecutorAdd,
    kmsVerifierAdd,
    inputVerifierAdd,
    hcuLimitAdd,
    pauserSetAdd
} from "@fhevm-host-contracts/addresses/FHEVMHostAddresses.sol";

/// @title ExportFHEVMState
/// @notice Deploys fhEVM in simulation, then exports code + storage to files
///         so a bash script can apply them to a running Anvil via cast rpc.
contract ExportFHEVMState is HostContractsDeployerTestUtils {
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    string constant BASE = ".forge-snapshots/fhevm/";

    function run() public {
        address[] memory kmsSigners = new address[](1);
        kmsSigners[0] = address(0x7777);
        address[] memory inputSigners = new address[](1);
        inputSigners[0] = address(0x8888);

        // Record all storage writes during deployment
        vm.record();

        _deployFullHostStack(
            address(0xBEEF), // owner
            address(0xDEAD), // pauser
            address(0x1234), // gateway
            address(0x1234), // gateway (verifying)
            31337, // chainId
            kmsSigners,
            1, // kms threshold
            inputSigners,
            1 // input threshold
        );

        console2.log("fhEVM deployed. Exporting state...");

        _export("acl", aclAdd);
        _export("executor", fhevmExecutorAdd);
        _export("kms", kmsVerifierAdd);
        _export("input", inputVerifierAdd);
        _export("hcu", hcuLimitAdd);
        _export("pauser", pauserSetAdd);

        console2.log("Export complete to .forge-snapshots/fhevm/");
    }

    function _export(string memory name, address addr) internal {
        // 1. Export contract code at canonical address
        vm.writeFile(string.concat(BASE, name, "_addr.txt"), vm.toString(addr));
        vm.writeFile(string.concat(BASE, name, "_code.hex"), vm.toString(addr.code));

        // 2. Check for ERC1967 implementation (UUPS proxy)
        bytes32 implSlotVal = vm.load(addr, IMPL_SLOT);
        address impl = address(uint160(uint256(implSlotVal)));

        if (impl != address(0) && impl.code.length > 0) {
            vm.writeFile(string.concat(BASE, name, "_impl_addr.txt"), vm.toString(impl));
            vm.writeFile(string.concat(BASE, name, "_impl_code.hex"), vm.toString(impl.code));
            console2.log("  proxy:", name, addr);
            console2.log("   impl:", impl);
        } else {
            console2.log("  direct:", name, addr);
        }

        // 3. Export all storage slots written during deployment
        (, bytes32[] memory writes) = vm.accesses(addr);

        string memory data = "";
        uint256 count = 0;

        for (uint256 i = 0; i < writes.length; i++) {
            bytes32 slot = writes[i];
            bytes32 val = vm.load(addr, slot);
            if (val == bytes32(0)) continue;

            // Deduplicate
            bool dup = false;
            for (uint256 j = 0; j < i; j++) {
                if (writes[j] == slot) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;

            // Format: slot\nvalue\n (pairs)
            data = string.concat(data, vm.toString(slot), "\n", vm.toString(val), "\n");
            count++;
        }

        vm.writeFile(string.concat(BASE, name, "_storage.txt"), data);
        console2.log("    slots:", count);
    }
}
