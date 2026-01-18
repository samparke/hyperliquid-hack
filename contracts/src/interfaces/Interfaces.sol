// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;



interface ISovereignVault {
    function transferToModule(address module, address token, uint256 amount) external;
    function transferFromModule(address module, address token, uint256 amount) external;
    function balanceOf(address token) external view returns (uint256);
    function totalAllocatedUsd() external view returns (uint256);
}

interface IInventoryView {
    /// @notice Return current reserves for token0/token1 managed by the pool/vault
    function reserves() external view returns (uint256 r0, uint256 r1);

    /// @notice Signed delta in terms of token0 (positive = long token0, negative = short)
    function netDeltaToken0() external view returns (int256);
}

interface IRefPriceOracle {
    /// @notice Returns reference price token0/token1 in 1e18 fixed-point (token1 per token0)
    function refPriceE18() external view returns (uint256);
}