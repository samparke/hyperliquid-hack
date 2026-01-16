// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {SovereignALM} from "../src/SovereignALM.sol";
import {SovereignPool} from "../src/SovereignPool.sol";
import {SovereignPoolConstructorArgs} from "../src/structs/SovereignPoolStructs.sol";
import {ALMLiquidityQuoteInput, ALMLiquidityQuote} from "../src/ALM/structs/SovereignALMStructs.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {PrecompileSimulator} from "@hyper-evm-lib/test/utils/PrecompileSimulator.sol";

/// @notice Fork tests - uses real Hyperliquid mainnet prices
contract SovereignALMForkTest is Test {
    SovereignALM public alm;
    SovereignPool public pool;

    // USDT0 token on Hyperliquid (known to be registered in TokenRegistry)
    address constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    address constant USDC = 0x5555555555555555555555555555555555555555; // Native USDC placeholder

    function setUp() public {
        // Fork Hyperliquid mainnet
        vm.createSelectFork("https://rpc.hyperliquid.xyz/evm");

        // Initialize precompile simulator to enable L1 reads
        PrecompileSimulator.init();

        // Deploy pool with USDT0/USDC
        SovereignPoolConstructorArgs memory args = SovereignPoolConstructorArgs({
            token0: USDT0,
            token1: USDC,
            protocolFactory: address(this),
            poolManager: address(this),
            sovereignVault: address(0),
            verifierModule: address(0),
            isToken0Rebase: false,
            isToken1Rebase: false,
            token0AbsErrorTolerance: 0,
            token1AbsErrorTolerance: 0,
            defaultSwapFeeBips: 30
        });

        pool = new SovereignPool(args);
        alm = new SovereignALM(address(pool));

        // Set ALM on pool
        pool.setALM(address(alm));
    }

    function test_getSpotPrice() public view {
        uint64 price = alm.getSpotPrice();
        console.log("PURR/USDC spot price (8 decimals):", price);

        // Price should be non-zero
        assertGt(price, 0, "Spot price should be non-zero");
    }

    function test_getToken0Info() public view {
        PrecompileLib.TokenInfo memory info = alm.getToken0Info();

        console.log("Token name:", info.name);
        console.log("Wei decimals:", info.weiDecimals);
        console.log("Sz decimals:", info.szDecimals);

        assertEq(info.evmContract, USDT0, "EVM contract should match USDT0");
    }

    function test_getLiquidityQuote_ZeroToOne() public {
        // Swap 1 USDT0 (weiDecimals=8) to USDC
        // Note: USDT0 has evmExtraWeiDecimals=-2, meaning EVM decimals = 6
        uint256 amountIn = 1e8; // 1 USDT0 in wei decimals

        ALMLiquidityQuoteInput memory input = ALMLiquidityQuoteInput({
            isZeroToOne: true,
            amountInMinusFee: amountIn,
            feeInBips: 0,
            sender: address(this),
            recipient: address(this),
            tokenOutSwap: USDC
        });

        vm.prank(address(pool));
        ALMLiquidityQuote memory quote = alm.getLiquidityQuote(input, "", "");

        console.log("Input: 1 USDT0 (1e8 wei)");
        console.log("Output USDC (6 decimals):", quote.amountOut);
        console.log("Spot price:", alm.getSpotPrice());

        // Verify output is non-zero and matches input filled
        assertGt(quote.amountOut, 0, "Amount out should be non-zero");
        assertEq(quote.amountInFilled, amountIn, "Amount in filled should match input");

        // At ~$1 USDT0 price, 1e8 wei USDT0 should give ~1e6 USDC
        assertApproxEqRel(quote.amountOut, 1e6, 0.05e18, "Output should be ~1 USDC");
    }

    function test_getLiquidityQuote_OneToZero() public {
        // Swap 1 USDC (6 decimals) to USDT0
        uint256 amountIn = 1e6; // 1 USDC

        ALMLiquidityQuoteInput memory input = ALMLiquidityQuoteInput({
            isZeroToOne: false,
            amountInMinusFee: amountIn,
            feeInBips: 0,
            sender: address(this),
            recipient: address(this),
            tokenOutSwap: USDT0
        });

        vm.prank(address(pool));
        ALMLiquidityQuote memory quote = alm.getLiquidityQuote(input, "", "");

        console.log("Input: 1 USDC (1e6)");
        console.log("Output USDT0 (8 decimals):", quote.amountOut);
        console.log("Spot price:", alm.getSpotPrice());

        // Verify output is non-zero
        assertGt(quote.amountOut, 0, "Amount out should be non-zero");

        // At ~$1 USDT0 price, 1e6 USDC should give ~1e8 wei USDT0
        assertApproxEqRel(quote.amountOut, 1e8, 0.05e18, "Output should be ~1 USDT0");
    }

    function test_onlyPool_getLiquidityQuote() public {
        ALMLiquidityQuoteInput memory input = ALMLiquidityQuoteInput({
            isZeroToOne: true,
            amountInMinusFee: 1e18,
            feeInBips: 0,
            sender: address(this),
            recipient: address(this),
            tokenOutSwap: USDC
        });

        // Should work - getLiquidityQuote is view, no onlyPool restriction
        alm.getLiquidityQuote(input, "", "");
    }

    function test_onlyPool_onSwapCallback() public {
        // Should revert when called by non-pool
        vm.expectRevert(SovereignALM.SovereignALM__OnlyPool.selector);
        alm.onSwapCallback(true, 1e18, 1e6);

        // Should succeed when called by pool
        vm.prank(address(pool));
        alm.onSwapCallback(true, 1e18, 1e6);
    }

    function test_onlyPool_onDepositLiquidityCallback() public {
        // Should revert when called by non-pool
        vm.expectRevert(SovereignALM.SovereignALM__OnlyPool.selector);
        alm.onDepositLiquidityCallback(1e18, 1e6, "");

        // Should succeed when called by pool
        vm.prank(address(pool));
        alm.onDepositLiquidityCallback(1e18, 1e6, "");
    }
}

/// @notice Simple mock ERC20 for testing
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }
}
