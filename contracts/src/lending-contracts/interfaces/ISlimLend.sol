// SPDX-License-Identifier: BSL-3.0
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceFeed} from "./IPriceFeed.sol";

interface ISlimLend {
    // ──────────────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────────────
    error Slippage();
    error InsufficientLiquidity();
    error MinCollateralization();
    error HealthyAccount();
    error InsufficientCollateral();

    // ──────────────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────────────
    event LPDeposit(address indexed user, uint256 amount, uint256 shares);
    event LPRedeem(address indexed user, uint256 shares, uint256 amount);
    event DepositCollateral(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Liquidate(address indexed liquidator, address indexed borrower, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 amount);

    // ──────────────────────────────────────────────────────────────────────────────
    // Structs
    // ──────────────────────────────────────────────────────────────────────────────
    struct BorrowerInfo {
        uint256 borrowerShares;
        uint256 collateralTokenAmount;
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Constants / Immutables (exposed as views if needed, but usually not in interface)
    // ──────────────────────────────────────────────────────────────────────────────
    // Note: Immutables and constants are not required in interfaces, but you can add getters if useful.
    // For clarity, they're documented here but not enforced.

    // ──────────────────────────────────────────────────────────────────────────────
    // View / Pure Functions
    // ──────────────────────────────────────────────────────────────────────────────

    function assetToken() external view returns (IERC20);
    function collateralToken() external view returns (IERC20);
    function priceFeed() external view returns (IPriceFeed);

    function totalDepositedTokens() external view returns (uint256);
    function totalBorrowedTokens() external view returns (uint256);
    function lpSharePrice() external view returns (uint256);
    function borrowerSharePrice() external view returns (uint256);
    function lastUpdateTime() external view returns (uint256);

    function utilization() external view returns (uint256);

    function interestRate(uint256 _utilization) external pure returns (uint256 borrowerRate, uint256 lenderRate);

    function collateralValue(address borrower) external view returns (uint256);

    function collateralization_ratio(address borrower) external view returns (uint256);

    function canLiquidate(address borrower) external view returns (bool);

    function borrowerInfo(address borrower) external view returns (BorrowerInfo memory);

    // ──────────────────────────────────────────────────────────────────────────────
    // User Actions (Mutable)
    // ──────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Deposit asset token to earn interest and receive LP shares
     * @param amount The amount of asset token to deposit
     * @param minSharesOut The minimum amount of LP shares to receive (slippage protection)
     */
    function lpDepositAsset(uint256 amount, uint256 minSharesOut) external;

    /**
     * @notice Redeem asset token by burning LP shares
     * @param amountShares The amount of LP shares to burn
     * @param minAmountAssetOut The minimum amount of asset token to receive (slippage protection)
     */
    function lpRedeemShares(uint256 amountShares, uint256 minAmountAssetOut) external;

    /**
     * @notice Deposit collateral token
     * @param amount The amount of collateral token to deposit
     */
    function borrowerDepositCollateral(uint256 amount) external;

    /**
     * @notice Withdraw collateral token (checks min collateralization)
     * @param amount The amount of collateral token to withdraw
     */
    function borrowerWithdrawCollateral(uint256 amount) external;

    /**
     * @notice Borrow asset token against deposited collateral
     * @param amount The amount of asset token to borrow
     */
    function borrow(uint256 amount) external;

    /**
     * @notice Repay borrowed asset token to reduce debt
     * @param amountAsset The amount of asset token to repay
     * @param minBorrowSharesBurned The minimum amount of borrower shares to burn (slippage protection)
     */
    function repay(uint256 amountAsset, uint256 minBorrowSharesBurned) external;

    /**
     * @notice Liquidate an undercollateralized borrower (seizes all collateral for full debt repayment)
     * @param borrower The address of the borrower to liquidate
     * @dev Liquidator must approve this contract for the debt amount
     */
    function liquidate(address borrower) external;
}
