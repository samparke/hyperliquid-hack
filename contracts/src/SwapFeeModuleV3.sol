// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ISwapFeeModule, SwapFeeModuleData} from "./swap-fee-modules/interfaces/ISwapFeeModule.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";

/*//////////////////////////////////////////////////////////////
                        Minimal Pool Interface
//////////////////////////////////////////////////////////////*/
interface ISovereignPoolLite {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function sovereignVault() external view returns (address);
}

/**
 * @title BalanceSeekingSwapFeeModuleV3
 *
 * Fee rule (your spec):
 *  - Let spot = normalizedSpotPx(spotIndexPURR) (assumed 1e18-scaled USDC per 1 PURR)
 *  - Let USDC and PURR be live balances in the sovereignVault (NOT pool.getReserves()).
 *  - Compute ratio: R = (USDC_value * spot) / PURR_value
 *      where USDC_value and PURR_value are normalized to 1e18 token units
 *  - Target is R == 1e18.
 *  - For every 0.1% deviation (10 bps) => add 0.1% fee (10 bps).
 *    => feeAddBps = floor(devBps / 10) * 10
 *
 * Liquidity safety:
 *  - Estimate output at spot and REQUIRE vault has enough tokenOut (with optional buffer).
 *  - This prevents "quote says you'll receive X but vault can't pay X" at least under spot.
 *
 * NOTE:
 *  - This module can revert (by design) on insufficient vault liquidity or missing balances.
 *  - If your vault payout function does NOT revert on insufficient balance, fix that too
 *    (see notes after the contract).
 */
contract BalanceSeekingSwapFeeModuleV3 is ISwapFeeModule {
    address public immutable sovereignPool;
    address public immutable usdc;
    address public immutable purr;

    // Fee bounds (bips)
    uint256 public immutable baseFeeBips;
    uint256 public immutable minFeeBips;
    uint256 public immutable maxFeeBips;

    // Extra safety buffer on liquidity check
    // requiredOut = estOut * (1 + bufferBps)
    uint256 public immutable liquidityBufferBps;

    // Hyperliquid spot index for PURR spot market
    uint64 public immutable spotIndexPURR;

    // If HL price orientation is inverted for your market, set this true.
    // If price is USDC per PURR, keep false.
    bool public immutable invertPurrPx;

    uint256 private constant BIPS = 10_000;
    uint256 private constant ONE_E18 = 1e18;

    error PoolPairMismatch(address token0, address token1);
    error ZeroVaultBalance(address vault, address token);
    error InsufficientVaultLiquidity(address vault, address tokenOut, uint256 balOut, uint256 neededOut);

    constructor(
        address _sovereignPool,
        address _usdc,
        address _purr,
        uint64 _spotIndexPURR,
        bool _invertPurrPx,
        uint256 _baseFeeBips,
        uint256 _minFeeBips,
        uint256 _maxFeeBips,
        uint256 _liquidityBufferBps
    ) {
        require(_sovereignPool != address(0), "POOL_ZERO");
        require(_usdc != address(0) && _purr != address(0), "TOKEN_ZERO");
        require(_usdc != _purr, "SAME_TOKEN");

        require(_minFeeBips <= _baseFeeBips, "MIN_GT_BASE");
        require(_baseFeeBips <= _maxFeeBips, "BASE_GT_MAX");
        require(_maxFeeBips <= BIPS, "MAX_TOO_HIGH");

        require(_liquidityBufferBps <= 5_000, "BUF_TOO_HIGH");

        sovereignPool = _sovereignPool;
        usdc = _usdc;
        purr = _purr;

        spotIndexPURR = _spotIndexPURR;
        invertPurrPx = _invertPurrPx;

        baseFeeBips = _baseFeeBips;
        minFeeBips = _minFeeBips;
        maxFeeBips = _maxFeeBips;

        liquidityBufferBps = _liquidityBufferBps;
    }

    function getSwapFeeInBips(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address,
        bytes memory
    ) external view override returns (SwapFeeModuleData memory data) {
        data.internalContext = "";

        if (amountIn == 0) {
            data.feeInBips = _clampFee(baseFeeBips);
            return data;
        }

        ISovereignPoolLite pool = ISovereignPoolLite(sovereignPool);
        address vault = pool.sovereignVault();

        address t0 = pool.token0();
        address t1 = pool.token1();

        // Must be the expected pair
        bool pairOk = (t0 == usdc && t1 == purr) || (t0 == purr && t1 == usdc);
        if (!pairOk) revert PoolPairMismatch(t0, t1);

        // Swaps must be between the two tokens
        bool isValidSwap =
            (tokenIn == t0 || tokenIn == t1) &&
            (tokenOut == t0 || tokenOut == t1) &&
            (tokenIn != tokenOut);

        if (!isValidSwap) {
            data.feeInBips = _clampFee(baseFeeBips);
            return data;
        }

        // --- Live vault balances (raw token units) ---
        uint256 usdcBalRaw = IERC20Metadata(usdc).balanceOf(vault);
        uint256 purrBalRaw = IERC20Metadata(purr).balanceOf(vault);

        if (usdcBalRaw == 0) revert ZeroVaultBalance(vault, usdc);
        if (purrBalRaw == 0) revert ZeroVaultBalance(vault, purr);

        // --- Spot price (assumed 1e18 USDC per 1 PURR unless inverted) ---
        uint256 rawPx = PrecompileLib.normalizedSpotPx(spotIndexPURR);
        require(rawPx > 0, "PX_0");

        uint256 pxUSDCperPURR_1e18 = invertPurrPx ? _invert1e18(rawPx) : rawPx;

        // --- Liquidity check: estimate amountOut at spot and require vault can pay ---
        uint256 estOutRaw = _estimateOutAtSpotRaw(tokenIn, tokenOut, amountIn, pxUSDCperPURR_1e18);
        if (estOutRaw > 0) {
            uint256 needed = Math.mulDiv(estOutRaw, (BIPS + liquidityBufferBps), BIPS);
            uint256 balOut = IERC20Metadata(tokenOut).balanceOf(vault);
            if (balOut < needed) revert InsufficientVaultLiquidity(vault, tokenOut, balOut, needed);
        }

        // --- Compute imbalance fee from vault holdings only ---
        // Normalize balances to 1e18 token units (NOT USD) for your equation
        uint256 usdcAmt1e18 = _to1e18(usdcBalRaw, IERC20Metadata(usdc).decimals());
        uint256 purrAmt1e18 = _to1e18(purrBalRaw, IERC20Metadata(purr).decimals());

        // Your ratio: R = (USDC_amount * spot_price) / PURR_amount
        // With both amounts and price 1e18-scaled, R is 1e18-scaled.
        uint256 ratio1e18 = Math.mulDiv(usdcAmt1e18, pxUSDCperPURR_1e18, purrAmt1e18);

        // devBps = |R - 1| in basis points
        uint256 devAbs = ratio1e18 >= ONE_E18 ? (ratio1e18 - ONE_E18) : (ONE_E18 - ratio1e18);
        uint256 devBps = Math.mulDiv(devAbs, BIPS, ONE_E18);

        // for each 0.1% (10 bps) deviation => +0.1% fee (10 bps)
        uint256 feeAddBps = (devBps / 10) * 10;

        uint256 fee = baseFeeBips + feeAddBps;
        data.feeInBips = _clampFee(fee);
        return data;
    }

    // Universal callback (unused)
    function callbackOnSwapEnd(
        uint256,
        int24,
        uint256,
        uint256,
        SwapFeeModuleData memory
    ) external pure override {}

    // Sovereign callback (unused)
    function callbackOnSwapEnd(
        uint256,
        uint256,
        uint256,
        SwapFeeModuleData memory
    ) external pure override {}

    // ------------------------
    // Internals
    // ------------------------

    function _clampFee(uint256 fee) internal view returns (uint256) {
        if (fee < minFeeBips) return minFeeBips;
        if (fee > maxFeeBips) return maxFeeBips;
        return fee;
    }

    function _invert1e18(uint256 x) internal pure returns (uint256) {
        // 1e18 / x scaled to 1e18 => 1e36 / x
        return Math.mulDiv(1e36, 1, x);
    }

    function _to1e18(uint256 amountRaw, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amountRaw;
        if (decimals < 18) return amountRaw * (10 ** uint256(18 - decimals));
        // decimals > 18
        return amountRaw / (10 ** uint256(decimals - 18));
    }

    function _from1e18(uint256 amount1e18, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount1e18;
        if (decimals < 18) return amount1e18 / (10 ** uint256(18 - decimals));
        // decimals > 18
        return amount1e18 * (10 ** uint256(decimals - 18));
    }

    /// @dev Estimate output at spot, returned in raw tokenOut units.
    /// Assumes px = (USDC per PURR) scaled to 1e18.
    function _estimateOutAtSpotRaw(
        address tokenIn,
        address tokenOut,
        uint256 amountInRaw,
        uint256 pxUSDCperPURR_1e18
    ) internal view returns (uint256) {
        uint8 dIn = IERC20Metadata(tokenIn).decimals();
        uint8 dOut = IERC20Metadata(tokenOut).decimals();

        // normalize amountIn to 1e18 token units
        uint256 in1e18 = _to1e18(amountInRaw, dIn);

        if (tokenIn == usdc && tokenOut == purr) {
            // USDC -> PURR : purr = usdc / px
            uint256 out1e18 = Math.mulDiv(in1e18, ONE_E18, pxUSDCperPURR_1e18);
            return _from1e18(out1e18, dOut);
        }

        if (tokenIn == purr && tokenOut == usdc) {
            // PURR -> USDC : usdc = purr * px
            uint256 out1e18 = Math.mulDiv(in1e18, pxUSDCperPURR_1e18, ONE_E18);
            return _from1e18(out1e18, dOut);
        }

        return 0;
    }
}