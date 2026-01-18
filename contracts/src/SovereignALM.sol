// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {ISovereignALM} from "./ALM/interfaces/ISovereignALM.sol";
import {ALMLiquidityQuoteInput, ALMLiquidityQuote} from "./ALM/structs/SovereignALMStructs.sol";
import {ISovereignPool} from "./SovereignPool.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";

/// @title SovereignALM - Hyperliquid Spot Price ALM (USDC/PURR)
/// @notice Returns quotes using HL spot price and REVERTS if vault cannot pay amountOut.
/// @dev Assumes PrecompileLib.normalizedSpotPx(spotIndexPURR) returns USDC-per-PURR
///      scaled to USDC decimals (you observed 6 decimals).
contract SovereignALM is ISovereignALM {
    uint256 private constant BIPS = 10_000;

    ISovereignPool public immutable pool;

    /// @dev The two tokens we support
    address public immutable usdc;
    address public immutable purr;

    /// @dev HL spot index for PURR/USDC
    uint64 public immutable spotIndexPURR;

    /// @dev If HL orientation is inverted for your market, set true.
    bool public immutable invertPurrPx;

    /// @dev Extra buffer for vault payout check (bps). Example: 50 = 0.50%.
    uint256 public immutable liquidityBufferBps;

    error SovereignALM__OnlyPool();
    error SovereignALM__ZeroPrice();
    error SovereignALM__UnsupportedPair(address tokenIn, address tokenOut);
    error SovereignALM__InsufficientVaultLiquidity(
        address vault,
        address tokenOut,
        uint256 balOut,
        uint256 neededOut
    );

    constructor(
        address _pool,
        address _usdc,
        address _purr,
        uint64 _spotIndexPURR,
        bool _invertPurrPx,
        uint256 _liquidityBufferBps
    ) {
        require(_pool != address(0), "POOL_0");
        require(_usdc != address(0) && _purr != address(0), "TOKEN_0");
        require(_usdc != _purr, "SAME_TOKEN");
        require(_liquidityBufferBps <= 5_000, "BUF_TOO_HIGH");

        pool = ISovereignPool(_pool);
        usdc = _usdc;
        purr = _purr;

        spotIndexPURR = _spotIndexPURR;
        invertPurrPx = _invertPurrPx;
        liquidityBufferBps = _liquidityBufferBps;
    }

    modifier onlyPool() {
        if (msg.sender != address(pool)) revert SovereignALM__OnlyPool();
        _;
    }

    /// @notice Returns USDC-per-PURR price scaled to USDC decimals (typically 6).
    function getSpotPriceUSDCperPURR() public view returns (uint256 pxUSDCperPURR) {
        uint256 raw = PrecompileLib.normalizedSpotPx(spotIndexPURR);
        if (raw == 0) revert SovereignALM__ZeroPrice();

        // Based on observed data: raw ~= 4.67e8 when 1 USDC ~= 4.67 PURR
        // => raw is PURR per USDC scaled by 1e8
        uint256 RAW_SCALE = 1e8;

        uint8 usdcDec = IERC20Metadata(usdc).decimals(); // should be 6
        uint256 USDC_SCALE = 10 ** uint256(usdcDec);

        // Convert to USDC per PURR scaled to USDC decimals:
        // px = USDC_SCALE / (raw / RAW_SCALE) = USDC_SCALE * RAW_SCALE / raw
        pxUSDCperPURR = Math.mulDiv(USDC_SCALE * RAW_SCALE, 1, raw);
    }

    /// @notice Quote function used by the pool during swaps
    function getLiquidityQuote(
        ALMLiquidityQuoteInput memory input,
        bytes calldata,
        bytes calldata
    ) external view override returns (ALMLiquidityQuote memory quote) {
        // Determine tokenIn/tokenOut from pool ordering and isZeroToOne
        address t0 = pool.token0();
        address t1 = pool.token1();

        address tokenIn = input.isZeroToOne ? t0 : t1;
        address tokenOut = input.isZeroToOne ? t1 : t0;

        // Only support USDC <-> PURR
        bool ok =
            (tokenIn == usdc && tokenOut == purr) ||
            (tokenIn == purr && tokenOut == usdc);

        if (!ok) revert SovereignALM__UnsupportedPair(tokenIn, tokenOut);

        uint256 pxUSDCperPURR = getSpotPriceUSDCperPURR();

        uint256 amountOut = _quoteOutAtSpot(
            tokenIn,
            tokenOut,
            input.amountInMinusFee,
            pxUSDCperPURR
        );

        // HARD liquidity check against vault live balance
        address vault = pool.sovereignVault();
        uint256 balOut = IERC20Metadata(tokenOut).balanceOf(vault);

        // needed = amountOut * (1 + buffer)
        uint256 needed = Math.mulDiv(amountOut, (BIPS + liquidityBufferBps), BIPS);

        if (balOut < needed) {
            revert SovereignALM__InsufficientVaultLiquidity(vault, tokenOut, balOut, needed);
        }

        // Return quote
        quote.isCallbackOnSwap = false;
        quote.amountOut = amountOut;
        quote.amountInFilled = input.amountInMinusFee;
    }

    function onDepositLiquidityCallback(uint256, uint256, bytes memory) external override onlyPool {}
    function onSwapCallback(bool, uint256, uint256) external override onlyPool {}

    /// @dev Spot quoting assuming px = (USDC per 1 PURR) scaled to USDC decimals.
    ///      Works with arbitrary token decimals by using raw math.
    function _quoteOutAtSpot(
        address tokenIn,
        address tokenOut,
        uint256 amountInRaw,
        uint256 pxUSDCperPURR
    ) internal view returns (uint256 amountOutRaw) {
        uint8 usdcDec = 6;   // typically 6
        uint8 purrDec = 5;   // often 18

        uint256 pScale = 10 ** uint256(usdcDec); // price scale

        if (tokenIn == purr && tokenOut == usdc) {
            // PURR -> USDC
            // amountOutUSDC_raw = amountInPURR_raw * px(USDC_raw per 1 PURR) / 10^purrDec
            // pxUSDCperPURR is scaled to USDC decimals, so it already represents "USDC raw" per 1 PURR.
            amountOutRaw = Math.mulDiv(amountInRaw, pxUSDCperPURR, 10 ** uint256(purrDec));
            return amountOutRaw;
        }

        if (tokenIn == usdc && tokenOut == purr) {
            // USDC -> PURR
            // amountOutPURR_raw = amountInUSDC_raw * 10^purrDec / pxUSDCperPURR
            // amountInUSDC_raw is already in USDC raw units.
            amountOutRaw = Math.mulDiv(amountInRaw, 10 ** uint256(purrDec), pxUSDCperPURR);
            return amountOutRaw;
        }

        // should be unreachable due to earlier require
        revert SovereignALM__UnsupportedPair(tokenIn, tokenOut);
    }
}