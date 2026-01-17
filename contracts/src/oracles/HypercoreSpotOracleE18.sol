// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {IRefPriceOracle} from "./interfaces/IRefPriceOracle.sol";

/// @notice Read-only price oracle for DeltaBook / strategies.
/// @dev Mirrors the normalization you already use in SovereignALM:
///      raw spotPx has 8 decimals and must be multiplied by 10^szDecimals.
contract HypercoreSpotOracleE18 is IRefPriceOracle {
    uint256 private constant PRICE_DECIMALS = 8;

    address public immutable token0;

    constructor(address _token0) {
        token0 = _token0;
    }

    /// @return token1 per token0, scaled to 1e18
    function refPriceE18() external view override returns (uint256) {
        PrecompileLib.TokenInfo memory info = PrecompileLib.tokenInfo(token0);

        uint64 raw = PrecompileLib.spotPx(token0);
        require(raw != 0, "ZERO_PRICE");

        // Same normalization as your SovereignALM
        uint256 normalizedPrice = uint256(raw) * (10 ** info.szDecimals);

        // Convert 8-decimal price -> 1e18
        return (normalizedPrice * 1e18) / (10 ** PRICE_DECIMALS);
    }
}