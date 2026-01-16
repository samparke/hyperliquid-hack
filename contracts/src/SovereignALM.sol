// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.30;

import {ISovereignALM} from "./ALM/interfaces/ISovereignALM.sol";
import {ALMLiquidityQuoteInput, ALMLiquidityQuote} from "./ALM/structs/SovereignALMStructs.sol";
import {PrecompileReader} from "./library/PrecompileReader.sol";
import {ISovereignPool} from "./SovereignPool.sol";

contract SovereignAlM is ISovereignALM {
    function getLiquidityQuote(
        ALMLiquidityQuoteInput memory _almLiquidityQuoteInput,
        bytes calldata _externalContext,
        bytes calldata _verifierData
    ) external override returns (ALMLiquidityQuote memory) {
        // index will be 0 for PURR/USDC pool
        uint64 spotPrice = PrecompileReader.getSpotPrice(ISovereignPool(msg.sender).spotIndex());

        uint256 amountOut =
            _calculateSwapOut(_almLiquidityQuoteInput.amountInMinusFee, spotPrice, _almLiquidityQuoteInput.isZeroToOne);
        return ALMLiquidityQuote({
            isCallbackOnSwap: false, amountOut: amountOut, amountInFilled: _almLiquidityQuoteInput.amountInMinusFee
        });
    }

    function onDepositLiquidityCallback(uint256 _amount0, uint256 _amount1, bytes memory _data) external override {}

    function onSwapCallback(bool _isZeroToOne, uint256 _amountIn, uint256 _amountOut) external override {}

    function _calculateSwapOut(uint256 amountIn, uint64 spotPrice, bool isZeroToOne) internal pure returns (uint256) {
        if (isZeroToOne) {
            // PURR (18) -> USDC (6)

            //              (1e18 * 471810000 * 1e6) / (1e18 * 1e8)
            // Type: uint256
            // ├ Hex: 0x47fe14
            // ├ Hex (full word): 0x000000000000000000000000000000000000000000000000000000000047fe14
            // └ Decimal: 4718100 -> correct usdc amount (6 decimals)
            // 1e18 is 1 PURR. 1 PURR = 471810000 spot price (8 decimals)
            // therefore to convert to 6 decimals, we take off two 0s

            return (amountIn * spotPrice * 1e6) / (1e18 * 1e8);
        } else {
            // USDC (6) -> PURR (18)

            // ➜ uint256 result3 = (amountIn1 * 1e18 * 1e8) / (1e6 * 471810000)
            // ➜ result3
            // Type: uint256
            // ├ Hex: 0x2f0ff27042a5b24
            // ├ Hex (full word): 0x00000000000000000000000000000000000000000000000002f0ff27042a5b24
            // └ Decimal: 211949725525105444

            // 211949725525105444 / 10**18 =
            // 0.211949725525105444 PURR
            // reciprocal: 1 / 0.21195 ≈ 4.717 USDC per PURR

            return (amountIn * 1e18 * 1e8) / (1e6 * spotPrice);
        }
    }
}
