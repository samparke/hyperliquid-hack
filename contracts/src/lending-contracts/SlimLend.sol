// SPDX-License-Identifier: BSL-3.0
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

contract SlimLend is ERC20("LPSlimShares", "LPS") {
    using SafeERC20 for IERC20;

    uint256 public totalDepositedTokens;
    uint256 public totalBorrowedTokens;
    uint256 public lpSharePrice = 1e18;
    uint256 public borrowerSharePrice = 1e18;
    uint256 public lastUpdateTime = block.timestamp;
    IERC20 immutable assetToken;
    IERC20 immutable collateralToken;
    IPriceFeed immutable priceFeed;

    uint256 constant MIN_COLLATERALIZATION_RATIO = 1.5e18;
    uint256 constant LIQUIDATION_THRESHOLD = 1.1e18;
    uint256 constant OPTIMAL_UTILIZATION = 0.95e18;
    uint256 constant KINK_INTEREST_PER_SECOND = 1585489599; // see test for derivation
    uint256 constant MAX_INTEREST_PER_SECOND = 15854895991; // see test for derivation

    error Slippage();
    error InsufficientLiquidity();
    error MinCollateralization();
    error HealthyAccount();
    error InsufficientCollateral();

    event LPDeposit(address indexed user, uint256 amount, uint256 shares);
    event LPRedeem(address indexed user, uint256 shares, uint256 amount);
    event DepositCollateral(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Liquidate(address indexed liquidator, address indexed borrower, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 amount);

    struct BorrowerInfo {
        uint256 borrowerShares;
        uint256 collateralTokenAmount;
    }

    mapping(address => BorrowerInfo) public borrowerInfo;

    constructor(IERC20 _assetToken, IERC20 _collateralToken, IPriceFeed _priceFeed) {
        assetToken = _assetToken;
        collateralToken = _collateralToken;
        priceFeed = _priceFeed;
    }

    /**
     * @notice Calculate the current utilization of the pool
     * @return The utilization ratio (total borrowed / total deposited) with 18 decimals
     */
    function utilization() public view returns (uint256) {
        uint256 _totalBorrowedTokens = totalBorrowedTokens;
        uint256 _totalDepositedTokens = totalDepositedTokens;
        if (_totalDepositedTokens == 0 || _totalBorrowedTokens == 0) return 0;
        return _totalBorrowedTokens * 1e18 / _totalDepositedTokens;
    }

    /*
     * @notice Calculate the current interest rates based on utilization
     * @param _utilization The current utilization ratio with 18 decimals
     * @return borrowerRate The interest rate paid by borrowers with 18 decimals
     * @return lenderRate The interest rate earned by lenders with 18 decimals
     */
    function interestRate(uint256 _utilization) public pure returns (uint256 borrowerRate, uint256 lenderRate) {
        if (_utilization <= OPTIMAL_UTILIZATION) {
            uint256 slope = KINK_INTEREST_PER_SECOND * 1e18 / OPTIMAL_UTILIZATION;
            borrowerRate = slope * _utilization / 1e18;
        } else {
            uint256 slope = (MAX_INTEREST_PER_SECOND - KINK_INTEREST_PER_SECOND) * 1e18 / (1e18 - OPTIMAL_UTILIZATION);
            borrowerRate = KINK_INTEREST_PER_SECOND + (_utilization - OPTIMAL_UTILIZATION) * slope / 1e18;
        }
        lenderRate = borrowerRate * _utilization / 1e18;
        return (borrowerRate, lenderRate);
    }

    function _updateSharePrices() internal {
        uint256 elapsed = block.timestamp - lastUpdateTime;
        uint256 currentUtilisation = utilization();
        (uint256 borrowerRate, uint256 lenderRate) = interestRate(currentUtilisation);

        borrowerSharePrice += borrowerSharePrice * borrowerRate * elapsed / 1e18;
        lpSharePrice += lpSharePrice * lenderRate * elapsed / 1e18;

        lastUpdateTime = block.timestamp;
    }

    /*
     * @notice Deposit asset token to earn interest and receive LP shares
     * @param amount The amount of asset token to deposit
     * @param minSharesOut The minimum amount of LP shares to receive (slippage protection)
     */
    function lpDepositAsset(uint256 amount, uint256 minSharesOut) public {
        _updateSharePrices();

        uint256 shares = amount * 1e18 / lpSharePrice;
        if (shares < minSharesOut) revert Slippage();

        assetToken.safeTransferFrom(msg.sender, address(this), amount);
        totalDepositedTokens += amount;
        _mint(msg.sender, shares);
        emit LPDeposit(msg.sender, amount, shares);
    }

    /*
     * @notice Redeem asset token by burning LP shares
     * @param amountShares The amount of LP shares to burn
     * @param minAmountAssetOut The minimum amount of asset token to receive (slippage protection)
     */
    function lpRedeemShares(uint256 amountShares, uint256 minAmountAssetOut) public {
        _updateSharePrices();

        uint256 assets = amountShares * lpSharePrice / 1e18;
        if (assets < minAmountAssetOut) revert Slippage();
        // come to understand this
        if (assets > totalDepositedTokens - totalBorrowedTokens) revert("insufficient liquidity");
        assetToken.safeTransfer(msg.sender, assets);
        totalDepositedTokens -= assets;

        _burn(msg.sender, amountShares);
        emit LPRedeem(msg.sender, amountShares, assets);
    }

    /*
     * @notice Deposit collateral token
     * @param amount The amount of collateral token to deposit
     */
    function borrowerDepositCollateral(uint256 amount) public {
        _updateSharePrices();
        borrowerInfo[msg.sender].collateralTokenAmount += amount;
        if (collateralization_ratio(msg.sender) < MIN_COLLATERALIZATION_RATIO) revert MinCollateralization();
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        emit DepositCollateral(msg.sender, amount);
    }

    /*
     * @notice Withdraw collateral token. Cannot withdraw if it would cause the borrower's
     *         collateralization ratio to fall below the minimum.
     * @param amount The amount of collateral token to withdraw
     */
    function borrowerWithdrawCollateral(uint256 amount) public {
        _updateSharePrices();
        if (borrowerInfo[msg.sender].collateralTokenAmount < amount) revert InsufficientCollateral();
        borrowerInfo[msg.sender].collateralTokenAmount -= amount;
        if (collateralization_ratio(msg.sender) < MIN_COLLATERALIZATION_RATIO) revert MinCollateralization();
        collateralToken.safeTransfer(msg.sender, amount);

        emit WithdrawCollateral(msg.sender, amount);
    }

    /*
     * @notice Borrow asset token. Assumes collateral has already been deposited
     * @param amount The amount of asset token to borrow
     */
    function borrow(uint256 amount) public {
        _updateSharePrices();
        if (amount > totalDepositedTokens - totalBorrowedTokens) revert InsufficientLiquidity();

        uint256 shares = amount * 1e18 / borrowerSharePrice;
        borrowerInfo[msg.sender].borrowerShares += shares;
        totalBorrowedTokens += amount;
        if (collateralization_ratio(msg.sender) < MIN_COLLATERALIZATION_RATIO) revert MinCollateralization();

        assetToken.safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, amount);
    }

    /*
     * @notice Calculate the value of a borrower's collateral in asset token
     * @param borrower The address of the borrower to check
     * @return The dollar value of the borrower's collateral in asset token with 18 decimals
     */
    function collateralValue(address borrower) public view returns (uint256) {
        uint256 borrowerCollateral = borrowerInfo[borrower].collateralTokenAmount;
        (, int256 answer,,,) = priceFeed.latestRoundData();
        uint256 priceUsd18 = uint256(answer) * 1e10;
        uint256 collateralPrice = borrowerCollateral * priceUsd18 / 1e18;
        return collateralPrice; // compilation dummy
    }

    /*
     * @notice Calculate the collateralization ratio of a borrower
     * @param borrower The address of the borrower to check
     * @return The collateralization ratio (collateral value / debt value) with 18 decimals
     *         If the borrower has no debt, returns type(uint256).max
     */
    function collateralization_ratio(address borrower) public view returns (uint256) {
        uint256 debtShares = borrowerInfo[borrower].borrowerShares;
        if (debtShares == 0) {
            return type(uint256).max;
        }
        uint256 collateral = collateralValue(borrower);
        uint256 debtValue = debtShares * borrowerSharePrice / 1e18;
        return collateral * 1e18 / debtValue; // compilation dummy
    }

    /*
     * @notice Repay borrowed asset token to reduce debt
     * @param amountAsset The amount of asset token to repay
     * @param minBorrowSharesBurned The minimum amount of borrower shares to burn (slippage protection)
     */
    function repay(uint256 amountAsset, uint256 minBorrowSharesBurned) public {
        _updateSharePrices();
        uint256 borrowerDebt = borrowerInfo[msg.sender].borrowerShares;
        if (borrowerDebt == 0) {
            totalBorrowedTokens = _subFloorZero(totalBorrowedTokens, amountAsset);
            assetToken.safeTransferFrom(msg.sender, address(this), amountAsset);
            return;
        }

        uint256 assetToShares = amountAsset * 1e18 / borrowerSharePrice;
        uint256 sharesBurned = assetToShares > borrowerDebt ? borrowerDebt : assetToShares;

        if (assetToShares < minBorrowSharesBurned) revert Slippage();

        borrowerInfo[msg.sender].borrowerShares -= sharesBurned;
        totalBorrowedTokens = _subFloorZero(totalBorrowedTokens, amountAsset);

        assetToken.safeTransferFrom(msg.sender, address(this), amountAsset);

        emit Repay(msg.sender, amountAsset);
    }

    // if x < y return 0, else x - y
    function _subFloorZero(uint256 x, uint256 y) internal pure returns (uint256) {
        if (x < y) {
            return 0;
        }
        return x - y; // compilation
    }

    /*
     * @notice Check if a borrower can be liquidated
     * @param borrower The address of the borrower to check
     * @return True if the borrower can be liquidated, false otherwise
     */
    function canLiquidate(address borrower) public view returns (bool) {
        uint256 collateralRatio = collateralization_ratio(borrower);
        if (collateralRatio < LIQUIDATION_THRESHOLD) {
            return true;
        }
        return false; // compilation
    }

    /*
     * @notice Liquidate a borrower if their collateralization ratio is below the liquidation threshold.
     *         Seize all of the borrower's collateral in exchange for repaying all of their debt.
     *         This liquidation strategy is unsafe because if the debt goes underwater, nobody has an incentive
     *         to liquidate. This is acceptable for a demo / educational project but not for production.
     * @dev The liquidator must approve the contract to spend the borrower's debt amount in asset token
     * @param borrower The address of the borrower to liquidate
     */
    function liquidate(address borrower) public {
        if (!canLiquidate(borrower)) revert HealthyAccount();
        _updateSharePrices();

        uint256 borrowerShares = borrowerInfo[borrower].borrowerShares;
        uint256 borrowerCollateral = borrowerInfo[borrower].collateralTokenAmount;
        uint256 borrowerDebtValue = borrowerShares * borrowerSharePrice / 1e18;

        borrowerInfo[borrower].borrowerShares = 0;
        borrowerInfo[borrower].collateralTokenAmount = 0;
        totalBorrowedTokens = _subFloorZero(totalBorrowedTokens, borrowerDebtValue);

        collateralToken.safeTransfer(msg.sender, borrowerCollateral);
        assetToken.safeTransferFrom(msg.sender, address(this), borrowerDebtValue);

        emit Liquidate(msg.sender, borrower, borrowerDebtValue);
    }
}
