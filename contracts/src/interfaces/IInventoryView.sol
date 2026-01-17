// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IInventoryView {
    function totalAllocatedUsd() external view returns (uint256);
    function usdc() external view returns (address);
}