// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {ISovereignALM} from "./ALM/interfaces/ISovereignALM.sol";
import {ALMLiquidityQuoteInput, ALMLiquidityQuote} from "./ALM/structs/SovereignALMStructs.sol";
import {ISovereignPool} from "./SovereignPool.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";

/// @title SovereignALM - Hyperliquid Spot Price ALM (USDC/PURR)
/// @notice Returns spot quotes using HL price and REVERTS if vault cannot pay amountOut.
/// @dev Canonical internal price is always:
///      pxUSDCperPURR = (USDC raw units per 1 PURR), scaled to USDC decimals.
///      Example: if USDC decimals=6 and 1 PURR = 4.69 USDC,
///      pxUSDCperPURR ≈ 4_690_000.
contract SovereignALM is ISovereignALM {
    uint256 private constant BIPS = 10_000;

    ISovereignPool public immutable pool;

    address public immutable usdc;
    address public immutable purr;

    uint8 public immutable usdcDec;
    uint8 public immutable purrDec;

    /// @dev HL spot index for the PURR/USDC market
    uint64 public immutable spotIndexPURR;

    /// @dev Scale factor for PrecompileLib.normalizedSpotPx(spotIndexPURR).
    /// Example: if precompile returns 4.69000000 as 469000000 with 8 decimals => rawPxScale = 1e8.
    uint256 public immutable rawPxScale;

    /// @dev If true, raw precompile price is PURR per 1 USDC and must be inverted.
    /// If false, raw precompile price is USDC per 1 PURR (normal).
    bool public immutable rawIsPurrPerUsdc;

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
        uint256 _rawPxScale,
        bool _rawIsPurrPerUsdc,
        uint256 _liquidityBufferBps
    ) {
        require(_pool != address(0), "POOL_0");
        require(_usdc != address(0) && _purr != address(0), "TOKEN_0");
        require(_usdc != _purr, "SAME_TOKEN");
        require(_rawPxScale > 0, "SCALE_0");
        require(_liquidityBufferBps <= 5_000, "BUF_TOO_HIGH");

        pool = ISovereignPool(_pool);
        usdc = _usdc;
        purr = _purr;

        usdcDec = IERC20Metadata(_usdc).decimals();
        purrDec = IERC20Metadata(_purr).decimals();

        spotIndexPURR = _spotIndexPURR;
        rawPxScale = _rawPxScale;
        rawIsPurrPerUsdc = _rawIsPurrPerUsdc;
        liquidityBufferBps = _liquidityBufferBps;
    }

    modifier onlyPool() {
        if (msg.sender != address(pool)) revert SovereignALM__OnlyPool();
        _;
    }

    /// @notice Returns canonical USDC-per-PURR price scaled to USDC decimals.
    function getSpotPriceUSDCperPURR() public view returns (uint256 pxUSDCperPURR) {
        uint256 raw = PrecompileLib.normalizedSpotPx(spotIndexPURR);
        if (raw == 0) revert SovereignALM__ZeroPrice();

        uint256 USDC_SCALE = 10 ** uint256(usdcDec);

        if (!rawIsPurrPerUsdc) {
            // raw = (USDC per PURR) scaled by rawPxScale
            // want pxUSDCperPURR scaled by USDC decimals:
            // px = raw * USDC_SCALE / rawPxScale
            pxUSDCperPURR = Math.mulDiv(raw, USDC_SCALE, rawPxScale);
        } else {
            // raw = (PURR per USDC) scaled by rawPxScale
            // invert to get (USDC per PURR):
            // (USDC/PURR) = 1 / (PURR/USDC)
            // scaled to USDC decimals:
            // px = USDC_SCALE * rawPxScale / raw
            pxUSDCperPURR = Math.mulDiv(USDC_SCALE, rawPxScale, raw);
        }

        if (pxUSDCperPURR == 0) revert SovereignALM__ZeroPrice();
    }

    /// @notice Quote function used by the pool during swaps
    function getLiquidityQuote(
        ALMLiquidityQuoteInput memory input,
        bytes calldata,
        bytes calldata
    ) external view override returns (ALMLiquidityQuote memory quote) {
        address t0 = pool.token0();
        address t1 = pool.token1();

        address tokenIn = input.isZeroToOne ? t0 : t1;
        address tokenOut = input.isZeroToOne ? t1 : t0;

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

        uint256 needed = Math.mulDiv(amountOut, (BIPS + liquidityBufferBps), BIPS);

        if (balOut < needed) {
            revert SovereignALM__InsufficientVaultLiquidity(vault, tokenOut, balOut, needed);
        }

        quote.isCallbackOnSwap = false;
        quote.amountOut = amountOut;
        quote.amountInFilled = input.amountInMinusFee;
    }

    function onDepositLiquidityCallback(uint256, uint256, bytes memory) external override onlyPool {}
    function onSwapCallback(bool, uint256, uint256) external override onlyPool {}

    /// @dev Spot quoting assuming pxUSDCperPURR is:
    ///      (USDC raw units per 1 PURR), scaled to USDC decimals.
    function _quoteOutAtSpot(
        address tokenIn,
        address tokenOut,
        uint256 amountInRaw,
        uint256 pxUSDCperPURR
    ) internal view returns (uint256 amountOutRaw) {
        uint256 PURR_SCALE = 10 ** uint256(purrDec);

        if (tokenIn == purr && tokenOut == usdc) {
            // PURR -> USDC
            // amountOutUSDC_raw = amountInPURR_raw * (USDC_raw per 1 PURR) / 10^purrDec
            return Math.mulDiv(amountInRaw, pxUSDCperPURR, PURR_SCALE);
        }

        if (tokenIn == usdc && tokenOut == purr) {
            // USDC -> PURR
            // amountOutPURR_raw = amountInUSDC_raw * 10^purrDec / (USDC_raw per 1 PURR)
            return Math.mulDiv(amountInRaw, PURR_SCALE, pxUSDCperPURR);
        }

        revert SovereignALM__UnsupportedPair(tokenIn, tokenOut);
    }
}