// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ISwapFeeModule, SwapFeeModuleData} from "./swap-fee-modules/interfaces/ISwapFeeModule.sol";
import {ISovereignPool} from "./interfaces/ISovereignPool.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";

/// @notice Balance-seeking swap fee module (PURR/USDC only):
///         - swaps that worsen imbalance pay more
///         - swaps that reduce imbalance pay less
///
/// Imbalance is measured by USD-value share distance from 50/50:
///   imbalance = |shareUSDC - 0.5|, where shareUSDC = V_USDC / (V_USDC + V_PURR)
///
/// Notes:
/// - USDC is treated as $1 => price = 1e18
/// - PURR price comes from HyperEVM precompile normalizedSpotPx(spotIndexPURR)
/// - If the precompile returns the inverse orientation for PURR, set invertPurrPx=true.
contract BalanceSeekingSwapFeeModule is ISwapFeeModule {
    address public immutable sovereignPool;

    // Pool tokens we expect
    address public immutable usdc;
    address public immutable purr;

    // ---- Fee params (bips) ----
    uint256 public immutable baseFeeBips;     // e.g. 15 = 0.15%
    uint256 public immutable minFeeBips;      // e.g. 5  = 0.05%
    uint256 public immutable maxFeeBips;      // e.g. 100 = 1.00%

    // Deadzone: percent away from 50/50 in bips (e.g. 200 = 2%)
    uint256 public immutable deadzoneImbalanceBips;

    // Slopes: fee change per 1% change in imbalance beyond deadzone
    uint256 public immutable penaltySlopeBipsPerPct;
    uint256 public immutable discountSlopeBipsPerPct;

    // HyperEVM spot index for PURR (USDC price is fixed to 1e18)
    uint64 public immutable spotIndexPURR;
    bool public immutable invertPurrPx;

    uint256 private constant SHARE_SCALE = 1e18;
    uint256 private constant HALF_SHARE  = 5e17; // 0.5e18
    uint256 private constant BIPS        = 10_000;
    uint256 private constant ONE_E18     = 1e18;

    constructor(
        address _sovereignPool,
        address _usdc,
        address _purr,
        uint64 _spotIndexPURR,
        bool _invertPurrPx,
        uint256 _baseFeeBips,
        uint256 _minFeeBips,
        uint256 _maxFeeBips,
        uint256 _deadzoneImbalanceBips,
        uint256 _penaltySlopeBipsPerPct,
        uint256 _discountSlopeBipsPerPct
    ) {
        require(_sovereignPool != address(0), "POOL_ZERO");
        require(_usdc != address(0) && _purr != address(0), "TOKEN_ZERO");
        require(_usdc != _purr, "SAME_TOKEN");

        require(_minFeeBips <= _baseFeeBips, "MIN_GT_BASE");
        require(_baseFeeBips <= _maxFeeBips, "BASE_GT_MAX");
        require(_maxFeeBips <= BIPS, "MAX_TOO_HIGH");

        sovereignPool = _sovereignPool;
        usdc = _usdc;
        purr = _purr;

        spotIndexPURR = _spotIndexPURR;
        invertPurrPx = _invertPurrPx;

        baseFeeBips = _baseFeeBips;
        minFeeBips = _minFeeBips;
        maxFeeBips = _maxFeeBips;

        deadzoneImbalanceBips = _deadzoneImbalanceBips;
        penaltySlopeBipsPerPct = _penaltySlopeBipsPerPct;
        discountSlopeBipsPerPct = _discountSlopeBipsPerPct;
    }

    function getSwapFeeInBips(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address,
        bytes memory
    ) external view override returns (SwapFeeModuleData memory data) {
        // Default fallback: base fee (never revert swaps from fee logic)
        data.feeInBips = baseFeeBips;
        data.internalContext = "";

        ISovereignPool pool = ISovereignPool(sovereignPool);
        address t0 = pool.token0();
        address t1 = pool.token1();

        // Ensure the pool is actually the pair we expect (PURR/USDC).
        // If not, just return base fee.
        bool poolMatches =
            (t0 == usdc && t1 == purr) || (t0 == purr && t1 == usdc);
        if (!poolMatches) return data;

        // Only apply dynamic logic for swaps between token0/token1
        bool inIs0 = tokenIn == t0;
        bool inIs1 = tokenIn == t1;
        bool outIs0 = tokenOut == t0;
        bool outIs1 = tokenOut == t1;

        if (!((inIs0 || inIs1) && (outIs0 || outIs1) && tokenIn != tokenOut)) {
            return data;
        }

        (uint256 r0, uint256 r1) = pool.getReserves();
        if (r0 == 0 || r1 == 0) return data;

        // Prices (1e18 scaled)
        // USDC is fixed at 1e18
        uint256 pxUSDC = ONE_E18;

        // PURR price from precompile
        uint256 rawPurrPx = PrecompileLib.normalizedSpotPx(spotIndexPURR);
        if (rawPurrPx == 0) return data;

        uint256 pxPURR = invertPurrPx ? _invert1e18(rawPurrPx) : rawPurrPx;

        // Token decimals
        uint8 d0 = IERC20Metadata(t0).decimals();
        uint8 d1 = IERC20Metadata(t1).decimals();

        // Map token->price
        uint256 p0 = (t0 == usdc) ? pxUSDC : pxPURR;
        uint256 p1 = (t1 == usdc) ? pxUSDC : pxPURR;

        // USD values
        uint256 v0 = _usdValue(r0, p0, d0);
        uint256 v1 = _usdValue(r1, p1, d1);
        if (v0 == 0 || v1 == 0) return data;

        uint256 imbBefore = _imbalance(v0, v1);

        // Directional pressure approximation: add tokenIn value
        if (inIs0) v0 += _usdValue(amountIn, p0, d0);
        else       v1 += _usdValue(amountIn, p1, d1);

        uint256 imbAfter = _imbalance(v0, v1);

        uint256 fee = baseFeeBips;
        uint256 deadzone = (deadzoneImbalanceBips * SHARE_SCALE) / BIPS;

        if (imbBefore <= deadzone && imbAfter <= deadzone) {
            data.feeInBips = _clampFee(fee);
            return data;
        }

        if (imbAfter > imbBefore) {
            uint256 ref = imbBefore > deadzone ? imbBefore : deadzone;
            uint256 worsen = imbAfter > ref ? (imbAfter - ref) : 0;
            uint256 worsenPct = worsen / 1e16; // 1% = 1e16 on 1e18 scale
            if (worsenPct > 0) fee += worsenPct * penaltySlopeBipsPerPct;
        } else if (imbAfter < imbBefore) {
            uint256 ref = imbBefore > deadzone ? imbBefore : deadzone;
            uint256 improve = ref > imbAfter ? (ref - imbAfter) : 0;
            uint256 improvePct = improve / 1e16;
            if (improvePct > 0) {
                uint256 discount = improvePct * discountSlopeBipsPerPct;
                fee = (discount >= fee) ? 0 : (fee - discount);
            }
        }

        data.feeInBips = _clampFee(fee);
        return data;
    }

    // Universal pool callback (unused)
    function callbackOnSwapEnd(
        uint256,
        int24,
        uint256,
        uint256,
        SwapFeeModuleData memory
    ) external pure override {}

    // Sovereign pool callback (unused)
    function callbackOnSwapEnd(
        uint256,
        uint256,
        uint256,
        SwapFeeModuleData memory
    ) external pure override {}

    // -------------------------
    // Internal helpers
    // -------------------------

    function _invert1e18(uint256 x) internal pure returns (uint256) {
        // returns (1e18 / x) scaled to 1e18: (1e18 * 1e18) / x = 1e36 / x
        // x must be > 0 (checked by caller)
        return Math.mulDiv(1e36, 1, x);
    }

    function _usdValue(uint256 amount, uint256 price1e18, uint8 decimals) internal pure returns (uint256) {
        uint256 denom = 10 ** uint256(decimals);
        return Math.mulDiv(amount, price1e18, denom);
    }

    function _imbalance(uint256 v0, uint256 v1) internal pure returns (uint256) {
        uint256 total = v0 + v1;
        if (total == 0) return 0;
        uint256 share0 = Math.mulDiv(v0, SHARE_SCALE, total);
        return share0 >= HALF_SHARE ? (share0 - HALF_SHARE) : (HALF_SHARE - share0);
    }

    function _clampFee(uint256 fee) internal view returns (uint256) {
        if (fee < minFeeBips) return minFeeBips;
        if (fee > maxFeeBips) return maxFeeBips;
        return fee;
    }
}