// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IRefPriceOracle {
    /// @notice price of token0 in quote terms, scaled to 1e18
    /// @dev for your pool this is token1 per token0 (e.g., USDC per token0)
    function refPriceE18() external view returns (uint256);
}