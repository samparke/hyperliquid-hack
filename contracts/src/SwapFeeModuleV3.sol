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
 * BalanceSeekingSwapFeeModuleV3 (decimals-correct, vault-based)
 *
 * - Spot price S = USDC per 1 PURR, scaled by 10^SPOT_DECIMALS (you said 6).
 * - Uses LIVE vault balances for USDC/PURR.
 * - Liquidity check: estimates output at spot and REVERTS if vault can't pay tokenOut (+buffer).
 * - Fee rule:
 *      Balanced when USDC_value == PURR_value * spot
 *      In raw units: U * 10^dp * 10^ds  ~=  P * S * 10^du
 *      deviationBps = |left-right| / right * 10_000
 *      feeAddBps = floor(deviationBps / 10) * 10  (each 0.1% adds 0.1%)
 *      fee = baseFeeBips + feeAddBps, clamped to [min,max]
 */
contract BalanceSeekingSwapFeeModuleV3 is ISwapFeeModule {
    address public immutable sovereignPool;
    address public immutable usdc;
    address public immutable purr;

    uint256 public immutable baseFeeBips;
    uint256 public immutable minFeeBips;
    uint256 public immutable maxFeeBips;

    uint256 public immutable liquidityBufferBps;

    uint64 public immutable spotIndexPURR;
    bool public immutable invertPurrPx;

    uint256 private constant BIPS = 10_000;
    uint8 private constant SPOT_DECIMALS = 6; // <--- your HL spot decimals

    error PoolPairMismatch(address token0, address token1);
    error ZeroVaultBalance(address vault, address token);
    error InsufficientVaultLiquidity(address vault, address tokenOut, uint256 balOut, uint256 neededOut);
    error PriceZero();

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

        // default
        if (amountIn == 0) {
            data.feeInBips = _clampFee(baseFeeBips);
            return data;
        }

        ISovereignPoolLite pool = ISovereignPoolLite(sovereignPool);
        address vault = pool.sovereignVault();

        address t0 = pool.token0();
        address t1 = pool.token1();

        bool pairOk = (t0 == usdc && t1 == purr) || (t0 == purr && t1 == usdc);
        if (!pairOk) revert PoolPairMismatch(t0, t1);

        bool isValidSwap =
            (tokenIn == t0 || tokenIn == t1) &&
            (tokenOut == t0 || tokenOut == t1) &&
            (tokenIn != tokenOut);

        if (!isValidSwap) {
            data.feeInBips = _clampFee(baseFeeBips);
            return data;
        }

        // --- live vault balances ---
        uint256 U = IERC20Metadata(usdc).balanceOf(vault);
        uint256 P = IERC20Metadata(purr).balanceOf(vault);
        if (U == 0) revert ZeroVaultBalance(vault, usdc);
        if (P == 0) revert ZeroVaultBalance(vault, purr);

        // --- spot price S (USDC per PURR), 10^SPOT_DECIMALS ---
        uint256 raw = PrecompileLib.normalizedSpotPx(spotIndexPURR); // PURR/USDC @ 1e8
        uint256 S = (10**SPOT_DECIMALS) * 1e8 / raw;

        // --- liquidity check (estimate out at spot, require vault can pay) ---
        uint256 estOutRaw = _estimateOutAtSpotRaw(tokenIn, tokenOut, amountIn, S);
        if (estOutRaw > 0) {
            uint256 needed = Math.mulDiv(estOutRaw, (BIPS + liquidityBufferBps), BIPS);
            uint256 balOut = IERC20Metadata(tokenOut).balanceOf(vault);
            if (balOut < needed) revert InsufficientVaultLiquidity(vault, tokenOut, balOut, needed);
        }

        // --- fee from vault imbalance ---
        uint8 du = IERC20Metadata(usdc).decimals();
        uint8 dp = 5;

        // Balanced: U * 10^dp * 10^ds  ~=  P * S * 10^du
        // left/right are in the same "units", so deviation is dimensionless.
        uint256 left  = Math.mulDiv(U, _pow10(dp) * _pow10(SPOT_DECIMALS), 1);
        uint256 right = Math.mulDiv(P, Math.mulDiv(S, _pow10(du), 1), 1);

        // protect (shouldn't be zero because P and S nonzero)
        if (right == 0) {
            data.feeInBips = _clampFee(baseFeeBips);
            return data;
        }

        uint256 diff = left > right ? (left - right) : (right - left);
        uint256 devBps = Math.mulDiv(diff, BIPS, right);

        uint256 feeAddBps = (devBps / 10); // 0.1% steps
        uint256 fee = baseFeeBips + feeAddBps;

        data.feeInBips = _clampFee(fee);
        return data;
    }

    // callbacks unused
    function callbackOnSwapEnd(uint256, int24, uint256, uint256, SwapFeeModuleData memory) external pure override {}
    function callbackOnSwapEnd(uint256, uint256, uint256, SwapFeeModuleData memory) external pure override {}

    // ------------------ internals ------------------

    function _clampFee(uint256 fee) internal view returns (uint256) {
        if (fee < minFeeBips) return minFeeBips;
        if (fee > maxFeeBips) return maxFeeBips;
        return fee;
    }

    function _pow10(uint8 n) internal pure returns (uint256) {
        return 10 ** uint256(n);
    }

    /// invert a price with SPOT_DECIMALS scaling:
    /// S' = (10^ds * 10^ds) / S  -> still ds decimals
    function _invertPx(uint256 px) internal pure returns (uint256) {
        uint256 scale = 10 ** uint256(SPOT_DECIMALS);
        return Math.mulDiv(scale * scale, 1, px);
    }

    /// Estimate output at spot, returned in raw tokenOut units.
    /// S is USDC per PURR, scaled by 10^SPOT_DECIMALS.
    function _estimateOutAtSpotRaw(
        address tokenIn,
        address tokenOut,
        uint256 amountInRaw,
        uint256 S
    ) internal view returns (uint256) {
        uint8 dIn = IERC20Metadata(tokenIn).decimals();
        uint8 dOut = IERC20Metadata(tokenOut).decimals();

        uint256 du = _pow10(IERC20Metadata(usdc).decimals());
        uint256 dp = _pow10(5);
        uint256 ds = _pow10(SPOT_DECIMALS);

        // USDC -> PURR:
        // outPurr = inUsdc * 10^dp * 10^ds / (S * 10^du)
        if (tokenIn == usdc && tokenOut == purr) {
            // amountInRaw is in 10^du units already
            return Math.mulDiv(amountInRaw, dp * ds, S * du);
        }

        // PURR -> USDC:
        // outUsdc = inPurr * S * 10^du / (10^dp * 10^ds)
        if (tokenIn == purr && tokenOut == usdc) {
            // amountInRaw is in 10^dp units already
            return Math.mulDiv(amountInRaw, S * du, dp * ds);
        }

        // unknown pair
        return 0;
    }
}