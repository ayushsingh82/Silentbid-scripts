// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlindPoolCCA} from "./BlindPoolCCA.sol";

/// @notice Minimal interface to read CCA endBlock for deadline
interface ICCAEndBlock {
    function endBlock() external view returns (uint64);
}

/// @title BlindPoolFactory
/// @notice Deploy a BlindPoolCCA for a given CCA auction. Callable from the UI (user signs with wallet).
contract BlindPoolFactory {
    event BlindPoolDeployed(address indexed cca, address indexed blindPool, uint64 blindBidDeadline);

    /// @param _cca Address of the Uniswap CCA auction
    /// @return blindPool Address of the deployed BlindPoolCCA
    function deployBlindPool(address _cca) external returns (address blindPool) {
        uint64 endBlock = ICCAEndBlock(_cca).endBlock();
        uint64 blindDeadline = endBlock > 20 ? endBlock - 20 : 0;

        BlindPoolCCA pool = new BlindPoolCCA(_cca, blindDeadline);
        blindPool = address(pool);

        emit BlindPoolDeployed(_cca, blindPool, blindDeadline);
    }
}
