// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {ISovereignALM} from "./ALM/interfaces/ISovereignALM.sol";
import {ALMLiquidityQuoteInput, ALMLiquidityQuote} from "./ALM/structs/SovereignALMStructs.sol";
import {ISovereignPool} from "./SovereignPool.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";

/// @title SovereignALM - Hyperliquid Spot Price Oracle ALM
/// @notice ALM that uses Hyperliquid's spot price precompile for token/USDC swaps
/// @dev Reads spot prices directly from Hyperliquid L1 using hyper-evm-lib
contract SovereignALM is ISovereignALM {
    /// @notice Hyperliquid spot price precision (8 decimals)
    uint256 private constant PRICE_DECIMALS = 8;

    /// @notice USDC decimals
    uint256 private constant USDC_DECIMALS = 6;

    /// @notice The sovereign pool this ALM serves
    ISovereignPool public immutable pool;

    /// @notice Token0 address (the non-USDC token)
    address public immutable token0;

    error SovereignALM__OnlyPool();
    error SovereignALM__ZeroPrice();

    constructor(address _pool) {
        pool = ISovereignPool(_pool);
        token0 = pool.token0();
    }

    modifier onlyPool() {
        if (msg.sender != address(pool)) revert SovereignALM__OnlyPool();
        _;
    }

    /// @notice Get the current spot price from Hyperliquid for token0/USDC
    /// @return spotPrice The spot price with 8 decimal precision
    function getSpotPrice() public view returns (uint64 spotPrice) {
        // Uses PrecompileLib to read spot price directly by token address
        spotPrice = PrecompileLib.spotPx(token0);
    }

    /// @notice Get token0 info from Hyperliquid
    /// @return info Token information including decimals
    function getToken0Info() public view returns (PrecompileLib.TokenInfo memory info) {
        info = PrecompileLib.tokenInfo(token0);
    }

    /// @notice Calculate the output amount for a swap using Hyperliquid spot price
    function getLiquidityQuote(
        ALMLiquidityQuoteInput memory _almLiquidityQuoteInput,
        bytes calldata,
        bytes calldata
    ) external view override returns (ALMLiquidityQuote memory) {
        // Get token0 info from precompile
        PrecompileLib.TokenInfo memory tokenInfo = getToken0Info();

        // Get normalized spot price (accounts for szDecimals)
        // Raw spotPx needs to be multiplied by 10^szDecimals to get actual price
        uint64 rawSpotPrice = getSpotPrice();
        if (rawSpotPrice == 0) revert SovereignALM__ZeroPrice();

        // Normalize price: multiply by 10^szDecimals to get price with 8 decimal precision
        uint256 normalizedPrice = uint256(rawSpotPrice) * (10 ** tokenInfo.szDecimals);

        uint256 amountOut = _calculateSwapOut(
            _almLiquidityQuoteInput.amountInMinusFee,
            normalizedPrice,
            tokenInfo.weiDecimals,
            _almLiquidityQuoteInput.isZeroToOne
        );

        return ALMLiquidityQuote({
            isCallbackOnSwap: false,
            amountOut: amountOut,
            amountInFilled: _almLiquidityQuoteInput.amountInMinusFee
        });
    }

    /// @notice Callback after liquidity deposit
    function onDepositLiquidityCallback(uint256, uint256, bytes memory) external override onlyPool {}

    /// @notice Callback after swap execution
    function onSwapCallback(bool, uint256, uint256) external override onlyPool {}

    /// @notice Calculate output amount based on normalized spot price and swap direction
    /// @dev normalizedPrice is the price of token0 in USDC with 8 decimal precision
    /// @param amountIn Input amount in respective token decimals
    /// @param normalizedPrice Normalized spot price (raw price * 10^szDecimals)
    /// @param token0Decimals weiDecimals of token0
    /// @param isZeroToOne True if swapping token0 -> USDC
    function _calculateSwapOut(
        uint256 amountIn,
        uint256 normalizedPrice,
        uint8 token0Decimals,
        bool isZeroToOne
    ) internal pure returns (uint256 amountOut) {
        // Scaling factor: 10^(token0Decimals + priceDecimals - usdcDecimals)
        uint256 scaleFactor = 10 ** (token0Decimals + PRICE_DECIMALS - USDC_DECIMALS);

        if (isZeroToOne) {
            // Token0 -> USDC
            // amountOut (6 decimals) = amountIn (token0 decimals) * price (8 decimals) / scaleFactor
            amountOut = (amountIn * normalizedPrice) / scaleFactor;
        } else {
            // USDC -> Token0
            // amountOut (token0 decimals) = amountIn (6 decimals) * scaleFactor / price (8 decimals)
            amountOut = (amountIn * scaleFactor) / normalizedPrice;
        }
    }
}
