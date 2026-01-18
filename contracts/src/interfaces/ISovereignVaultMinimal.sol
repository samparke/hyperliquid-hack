// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ISovereignVaultMinimal {
    function getTokensForPool(address _pool) external view returns (address[] memory);

    // ✅ used by SovereignPool to compute usdcDelta safely
    function usdc() external view returns (address);

    function getTotalAllocatedUSDC() external view returns (uint256);

    // ✅ must exist; make it dynamic in the vault contract
    function getUSDCBalance() external view returns (uint256);

    function getReservesForPool(address _pool, address[] calldata _tokens) external view returns (uint256[] memory);

    function claimPoolManagerFees(uint256 _feePoolManager0, uint256 _feePoolManager1) external;

    function sendTokensToRecipient(address _token, address _recipient, uint256 _amount) external;
}