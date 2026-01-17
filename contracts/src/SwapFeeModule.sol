// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ISwapFeeModule, SwapFeeModuleData} from "./swap-fee-modules/interfaces/ISwapFeeModule.sol";
import {ISovereignPool} from "./interfaces/ISovereignPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";

contract SwapFeeModule is ISwapFeeModule {
    address public immutable sovereignPool;

    // Tunable constants (can be made governance-updatable later)
    uint256 public constant BASE_FEE_BIPS = 15; // 0.15%
    uint256 public constant DEVIATION_THRESHOLD_BIPS = 400; // ~4% imbalance starts penalty
    uint256 public constant EXTRA_MULTIPLIER = 25; // +0.25% per extra 10% deviation
    uint256 public constant MAX_FEE_BIPS = 100; // 1% hard cap

    constructor(address _sovereignPool) {
        sovereignPool = _sovereignPool;
    }

    function getSwapFeeInBips(address tokenIn, address tokenOut, uint256 amountIn, address, bytes calldata)
        external
        view
        override
        returns (SwapFeeModuleData memory data)
    {
        ISovereignPool pool = ISovereignPool(sovereignPool);

        (address token0, address token1) = (pool.token0(), pool.token1());
        (uint256 reserve0, uint256 reserve1) = pool.getReserves();

        bool zeroToOne = (tokenIn == token0 && tokenOut == token1);

        // Spot prices (USD, normalized)
        uint256 price0 = PrecompileLib.normalizedSpotPx(PrecompileLib.getSpotIndex(token0));
        uint256 price1 = PrecompileLib.normalizedSpotPx(PrecompileLib.getSpotIndex(token1));

        // Current pool value
        uint256 value0 = reserve0 * price0;
        uint256 value1 = reserve1 * price1;

        if (value0 == 0 || value1 == 0) {
            data.feeInBips = uint32(BASE_FEE_BIPS);
            return data;
        }

        uint256 ratioBeforeSwap = (value0 * 1e18) / value1;

        // Simulate swap (value impact only)
        if (zeroToOne) {
            value0 += amountIn * price0;
        } else {
            value1 += amountIn * price1;
        }

        uint256 ratioAfterSwap = (value0 * 1e18) / value1;

        uint256 preDeviation = ratioBeforeSwap > 1e18 ? ratioBeforeSwap - 1e18 : 1e18 - ratioBeforeSwap; // absoliute value of deviation, means we account both sides
        uint256 postDeviation = ratioAfterSwap > 1e18 ? ratioAfterSwap - 1e18 : 1e18 - ratioAfterSwap;

        uint256 feeBips = BASE_FEE_BIPS;

        // if post deviation is greater than pre deviation, and it exceeds threshold, apply extra fee
        if (postDeviation > preDeviation) {
            uint256 deviationBps = (postDeviation * 10_000) / 1e18;

            if (deviationBps > DEVIATION_THRESHOLD_BIPS) {
                feeBips += Math.mulDiv(deviationBps - DEVIATION_THRESHOLD_BIPS, EXTRA_MULTIPLIER, 10_000);
            }
        }

        if (feeBips > MAX_FEE_BIPS) {
            feeBips = MAX_FEE_BIPS;
        }

        data.feeInBips = uint32(feeBips);
        data.internalContext = "";
    }

    // No callback required for this logic
    function callbackOnSwapEnd(
        uint256 effectiveFee,
        uint256 amountInUsed,
        uint256 amountOut,
        SwapFeeModuleData calldata data
    ) external override {
        // Empty — no state to update
    }

    function callbackOnSwapEnd(
        uint256 _effectiveFee,
        int24 _spotPriceTick,
        uint256 _amountInUsed,
        uint256 _amountOut,
        SwapFeeModuleData memory _swapFeeModuleData
    ) external {}

    // Helper to get token0/token1 addresses from the pool
    function token0() public view returns (address) {
        return ISovereignPool(sovereignPool).token0();
    }

    function token1() public view returns (address) {
        return ISovereignPool(sovereignPool).token1();
    }
}
