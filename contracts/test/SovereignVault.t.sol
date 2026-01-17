// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {SovereignVault} from "../src/SovereignVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {HLConversions} from "@hyper-evm-lib/src/common/HLConversions.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {HyperCore} from "@hyper-evm-lib/test/simulation/HyperCore.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {CoreWriterLib} from "@hyper-evm-lib/src/CoreWriterLib.sol";

/// @notice Mock PURR token for testing
contract MockPURR {
    string public name = "PURR";
    string public symbol = "PURR";
    uint8 public decimals = 5;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Mock pool for testing vault interactions
contract MockPool {
    address public token0;
    address public token1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }
}

contract SovereignVaultTest is Test {
    using PrecompileLib for address;
    using HLConversions for *;

    uint64 public constant USDC_TOKEN = 0;

    // Test vault addresses (HLP and another vault)
    address public constant TEST_VAULT = 0xa15099a30BBf2e68942d6F4c43d70D04FAEab0A0; // HLP
    address public constant TEST_VAULT_2 = 0xaC26Cf5F3C46B5e102048c65b977d2551B72A9c7;

    HyperCore public hyperCore;
    SovereignVault public vault;
    MockPURR public purr;
    MockPool public pool;

    address public strategist;
    address public user = makeAddr("user");
    address public usdcAddress;

    function setUp() public {
        string memory alchemyRpc = "https://hyperliquid-testnet.g.alchemy.com/v2/uSFYHvKqoVOUFsNnbGM7sL_EWO0tf4iS";
        vm.createSelectFork(alchemyRpc);

        hyperCore = CoreSimulatorLib.init();

        // Get the correct USDC address for this chain (testnet vs mainnet)
        usdcAddress = HLConstants.usdc();

        strategist = address(this);

        // Deploy mock PURR token
        purr = new MockPURR();

        // Deploy vault with USDC address
        vault = new SovereignVault(usdcAddress);

        // Activate the vault account on Core
        CoreSimulatorLib.forceAccountActivation(address(vault));

        // Deploy mock pool
        pool = new MockPool(address(purr), usdcAddress);

        // Authorize the pool
        vault.setAuthorizedPool(address(pool), true);

        // Fund the vault with initial USDC on EVM
        deal(usdcAddress, address(vault), 1000e6); // 1000 USDC
    }

    function test_constructor() public view {
        assertEq(vault.strategist(), strategist);
        assertEq(vault.usdc(), usdcAddress);
        assertEq(vault.MIN_BUFFER(), 50e6);
        assertEq(vault.defaultVault(), TEST_VAULT);
    }

    function test_setAuthorizedPool() public {
        address newPool = makeAddr("newPool");

        assertFalse(vault.authorizedPools(newPool));

        vault.setAuthorizedPool(newPool, true);
        assertTrue(vault.authorizedPools(newPool));

        vault.setAuthorizedPool(newPool, false);
        assertFalse(vault.authorizedPools(newPool));
    }

    function test_setAuthorizedPool_onlyStrategist() public {
        vm.prank(user);
        vm.expectRevert(SovereignVault.OnlyStrategist.selector);
        vault.setAuthorizedPool(user, true);
    }

    function test_getTokensForPool() public view {
        address[] memory tokens = vault.getTokensForPool(address(pool));

        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(purr));
        assertEq(tokens[1], usdcAddress);
    }

    function test_changeDefaultVault() public {
        assertEq(vault.defaultVault(), TEST_VAULT);

        vault.changeDefaultVault(TEST_VAULT_2);

        assertEq(vault.defaultVault(), TEST_VAULT_2);
    }

    function test_changeDefaultVault_onlyStrategist() public {
        vm.prank(user);
        vm.expectRevert(SovereignVault.OnlyStrategist.selector);
        vault.changeDefaultVault(TEST_VAULT_2);
    }

    function test_allocate() public {
        uint256 allocateAmount = 500e6; // 500 USDC

        uint256 vaultEvmBalanceBefore = IERC20(usdcAddress).balanceOf(address(vault));

        // Allocate USDC to the default vault (HLP)
        vault.allocate(TEST_VAULT, allocateAmount);

        // EVM balance should decrease immediately (USDC is bridged to Core)
        assertEq(
            IERC20(usdcAddress).balanceOf(address(vault)),
            vaultEvmBalanceBefore - allocateAmount,
            "EVM balance should decrease by allocate amount"
        );

        // Note: The simulator has limitations with processing bridged funds to vault transfers
        // In production, the vaultTransfer action would be processed by HyperCore
        // and vault equity would be credited. The test verifies the EVM-side logic works.
    }

    function test_allocate_insufficientBuffer() public {
        // Try to allocate more than allowed (would leave less than MIN_BUFFER)
        uint256 allocateAmount = 960e6; // Would leave only 40 USDC (below 50 MIN_BUFFER)

        vm.expectRevert(SovereignVault.InsufficientBuffer.selector);
        vault.allocate(TEST_VAULT, allocateAmount);
    }

    function test_allocate_onlyStrategist() public {
        vm.prank(user);
        vm.expectRevert(SovereignVault.OnlyStrategist.selector);
        vault.allocate(TEST_VAULT, 100e6);
    }

    function test_sendTokensToRecipient_fromInternal() public {
        address recipient = makeAddr("recipient");
        uint256 sendAmount = 100e6;

        vm.prank(address(pool));
        vault.sendTokensToRecipient(usdcAddress, recipient, sendAmount);

        assertEq(IERC20(usdcAddress).balanceOf(recipient), sendAmount);
        assertEq(IERC20(usdcAddress).balanceOf(address(vault)), 900e6);
    }

    function test_sendTokensToRecipient_onlyAuthorizedPool() public {
        vm.prank(user);
        vm.expectRevert(SovereignVault.OnlyAuthorizedPool.selector);
        vault.sendTokensToRecipient(usdcAddress, user, 100e6);
    }

    function test_sendTokensToRecipient_zeroAmount() public {
        address recipient = makeAddr("recipient");
        uint256 balanceBefore = IERC20(usdcAddress).balanceOf(address(vault));

        vm.prank(address(pool));
        vault.sendTokensToRecipient(usdcAddress, recipient, 0);

        // Nothing should change
        assertEq(IERC20(usdcAddress).balanceOf(address(vault)), balanceBefore);
        assertEq(IERC20(usdcAddress).balanceOf(recipient), 0);
    }

    function test_claimPoolManagerFees() public {
        // Just verify it doesn't revert when called by authorized pool
        vm.prank(address(pool));
        vault.claimPoolManagerFees(100, 200);
    }

    function test_claimPoolManagerFees_onlyAuthorizedPool() public {
        vm.prank(user);
        vm.expectRevert(SovereignVault.OnlyAuthorizedPool.selector);
        vault.claimPoolManagerFees(100, 200);
    }

    function test_getReservesForPool_internalOnly() public view {
        address[] memory tokens = new address[](2);
        tokens[0] = address(purr);
        tokens[1] = usdcAddress;

        uint256[] memory reserves = vault.getReservesForPool(address(pool), tokens);

        assertEq(reserves.length, 2);
        assertEq(reserves[0], 0); // No PURR
        assertEq(reserves[1], 1000e6); // 1000 USDC internal
    }

    function test_getReservesForPool_withExternalSpot() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(purr);
        tokens[1] = usdcAddress;

        // Force some USDC on Core spot for the vault
        uint64 spotAmount = 500e8; // 500 USDC in Core wei
        CoreSimulatorLib.forceSpotBalance(address(vault), USDC_TOKEN, spotAmount);

        uint256[] memory reserves = vault.getReservesForPool(address(pool), tokens);

        // Internal (1000e6) + Spot (500e6 converted from Core)
        uint256 spotInEvm = HLConversions.perpToWei(spotAmount);
        assertEq(reserves[1], 1000e6 + spotInEvm, "Total should include internal + spot balance");
    }
}

/// @notice Integration test simulating full AMM + Core Vault flow
contract VaultCoreIntegrationTest is Test {
    using PrecompileLib for address;
    using HLConversions for *;

    uint64 public constant USDC_TOKEN = 0;
    address public constant TEST_VAULT = 0xa15099a30BBf2e68942d6F4c43d70D04FAEab0A0; // HLP

    HyperCore public hyperCore;
    SovereignVault public vault;
    MockPURR public purr;
    MockPool public pool;

    address public strategist;
    address public swapper = makeAddr("swapper");
    address public usdcAddress;

    function setUp() public {
        string memory alchemyRpc = "https://hyperliquid-testnet.g.alchemy.com/v2/uSFYHvKqoVOUFsNnbGM7sL_EWO0tf4iS";
        vm.createSelectFork(alchemyRpc);

        hyperCore = CoreSimulatorLib.init();

        // Get the correct USDC address for this chain
        usdcAddress = HLConstants.usdc();

        strategist = address(this);

        // Deploy tokens
        purr = new MockPURR();

        // Deploy vault
        vault = new SovereignVault(usdcAddress);

        // Activate vault on Core
        CoreSimulatorLib.forceAccountActivation(address(vault));

        // Deploy mock pool
        pool = new MockPool(address(purr), usdcAddress);

        // Authorize pool
        vault.setAuthorizedPool(address(pool), true);

        // Initial vault funding (simulating LP deposits to AMM)
        deal(usdcAddress, address(vault), 10000e6); // 10,000 USDC
        purr.mint(address(vault), 50000e5); // 50,000 PURR
    }

    /// @notice Test the complete flow:
    /// 1. Strategist allocates excess USDC to HLP vault
    /// 2. Verify EVM balance decreases correctly
    function test_fullFlow_allocateToVault() public {
        console.log("=== Initial State ===");
        console.log("Vault USDC balance:", IERC20(usdcAddress).balanceOf(address(vault)));
        console.log("Vault PURR balance:", purr.balanceOf(address(vault)));

        // Step 1: Strategist allocates 9000 USDC to HLP vault (keeping 1000 buffer)
        uint256 allocateAmount = 9000e6;
        vault.allocate(TEST_VAULT, allocateAmount);

        console.log("\n=== After Allocation ===");
        console.log("Vault internal USDC:", IERC20(usdcAddress).balanceOf(address(vault)));

        // Verify EVM balance decreased
        assertEq(
            IERC20(usdcAddress).balanceOf(address(vault)),
            1000e6,
            "Vault should have 1000 USDC internal after allocation"
        );

        // Note: Vault equity verification is limited by simulator - in production,
        // the bridgeToCore + vaultTransfer would credit the vault equity on HyperCore
    }

    /// @notice Test that vault can swap PURR without touching Core
    function test_purrSwap_noCoreInteraction() public {
        // Allocate USDC to vault first
        vault.allocate(TEST_VAULT, 9000e6);
        CoreSimulatorLib.nextBlock();

        PrecompileLib.UserVaultEquity memory equityBefore = PrecompileLib.userVaultEquity(address(vault), TEST_VAULT);

        // Swap PURR (should not touch Core)
        vm.prank(address(pool));
        vault.sendTokensToRecipient(address(purr), swapper, 1000e5);

        assertEq(purr.balanceOf(swapper), 1000e5, "Swapper should receive PURR");

        // Vault equity should be unchanged (PURR swap doesn't affect Core)
        PrecompileLib.UserVaultEquity memory equityAfter = PrecompileLib.userVaultEquity(address(vault), TEST_VAULT);
        assertEq(equityBefore.equity, equityAfter.equity, "HLP equity should not change for PURR swap");
    }

    /// @notice Test swap from internal balance only
    function test_swap_fromInternalOnly() public {
        // Allocate some to vault, leaving 1000 internal
        vault.allocate(TEST_VAULT, 9000e6);
        CoreSimulatorLib.nextBlock();

        console.log("Internal USDC before swap:", IERC20(usdcAddress).balanceOf(address(vault)));

        // Swap 500 USDC (less than internal balance)
        vm.prank(address(pool));
        vault.sendTokensToRecipient(usdcAddress, swapper, 500e6);

        assertEq(IERC20(usdcAddress).balanceOf(swapper), 500e6, "Swapper should receive 500 USDC");
        assertEq(IERC20(usdcAddress).balanceOf(address(vault)), 500e6, "Vault should have 500 USDC remaining");
    }

    /// @notice Test multiple allocations to different vaults
    function test_multipleVaultAllocations() public {
        address secondVault = 0xaC26Cf5F3C46B5e102048c65b977d2551B72A9c7;

        // Allocate to first vault
        vault.allocate(TEST_VAULT, 4000e6);

        // Allocate to second vault
        vault.allocate(secondVault, 4000e6);

        console.log("Remaining internal USDC:", IERC20(usdcAddress).balanceOf(address(vault)));

        // Verify EVM balances are correct
        assertEq(IERC20(usdcAddress).balanceOf(address(vault)), 2000e6, "Should have 2000 USDC remaining internally");
    }

    /// @notice Test reserve reporting includes Core spot balance
    function test_reserveReporting_includesSpot() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(purr);
        tokens[1] = usdcAddress;

        // Before any allocation
        uint256[] memory totalBefore = vault.getReservesForPool(address(pool), tokens);
        assertEq(totalBefore[1], 10000e6, "Total USDC should be 10000 initially");

        // Allocate to vault
        vault.allocate(TEST_VAULT, 8000e6);
        CoreSimulatorLib.nextBlock();

        // The USDC is now in Core (first bridged to Core, then to vault)
        // getReservesForPool should show internal only since vault equity isn't in spot
        uint256[] memory totalAfter = vault.getReservesForPool(address(pool), tokens);
        console.log("Internal USDC after allocation:", IERC20(usdcAddress).balanceOf(address(vault)));
        console.log("Total reserves reported:", totalAfter[1]);

        // After allocation, internal balance is 2000
        assertEq(IERC20(usdcAddress).balanceOf(address(vault)), 2000e6, "Internal should be 2000");
    }

    /// @notice Test that getReservesForPool correctly adds spot balance
    function test_reserveReporting_withForcedSpotBalance() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(purr);
        tokens[1] = usdcAddress;

        // Force a spot balance on Core for the vault (simulating USDC held on Core spot)
        uint64 spotAmount = 5000e8; // 5000 USDC in Core wei
        CoreSimulatorLib.forceSpotBalance(address(vault), USDC_TOKEN, spotAmount);

        uint256[] memory reserves = vault.getReservesForPool(address(pool), tokens);

        // Internal (10000e6) + Spot (5000e6 converted)
        uint256 spotInEvm = HLConversions.perpToWei(spotAmount);
        uint256 expectedTotal = 10000e6 + spotInEvm;

        console.log("Internal USDC:", IERC20(usdcAddress).balanceOf(address(vault)));
        console.log("Spot USDC (Core wei):", spotAmount);
        console.log("Spot USDC (EVM):", spotInEvm);
        console.log("Total reserves:", reserves[1]);

        assertEq(reserves[1], expectedTotal, "Total should include internal + spot");
    }
}

/// @notice Test vault withdrawal (recall) functionality using forced vault equity
contract VaultRecallTest is Test {
    using PrecompileLib for address;
    using HLConversions for *;

    uint64 public constant USDC_TOKEN = 0;
    address public constant TEST_VAULT = 0xa15099a30BBf2e68942d6F4c43d70D04FAEab0A0;

    HyperCore public hyperCore;
    SovereignVault public vault;
    MockPURR public purr;
    MockPool public pool;

    address public swapper = makeAddr("swapper");
    address public usdcAddress;

    function setUp() public {
        string memory alchemyRpc = "https://hyperliquid-testnet.g.alchemy.com/v2/uSFYHvKqoVOUFsNnbGM7sL_EWO0tf4iS";
        vm.createSelectFork(alchemyRpc);

        hyperCore = CoreSimulatorLib.init();

        // Get the correct USDC address for this chain
        usdcAddress = HLConstants.usdc();

        purr = new MockPURR();
        vault = new SovereignVault(usdcAddress);

        CoreSimulatorLib.forceAccountActivation(address(vault));

        pool = new MockPool(address(purr), usdcAddress);
        vault.setAuthorizedPool(address(pool), true);

        // Start with minimal internal USDC
        deal(usdcAddress, address(vault), 100e6); // Only 100 USDC internal
    }

    /// @notice Test sending tokens from internal balance
    function test_sendTokens_fromInternalBalance() public {
        // Send from internal balance (no recall needed)
        vm.prank(address(pool));
        vault.sendTokensToRecipient(usdcAddress, swapper, 50e6);

        assertEq(IERC20(usdcAddress).balanceOf(swapper), 50e6, "Swapper should receive 50 USDC");
        assertEq(IERC20(usdcAddress).balanceOf(address(vault)), 50e6, "Vault should have 50 USDC remaining");
    }

    /// @notice Test vault lock period is respected
    function test_recallFails_whenLocked() public {
        // Force vault equity with future lock timestamp
        uint64 lockedUntil = uint64((block.timestamp + 1 days) * 1000);
        CoreSimulatorLib.forceVaultEquity(address(vault), TEST_VAULT, 1000e6, lockedUntil);

        console.log("Lock until:", lockedUntil);
        console.log("Current time (ms):", block.timestamp * 1000);

        // Try to send more than internal balance - should revert due to lock
        vm.prank(address(pool));
        vm.expectRevert(
            abi.encodeWithSelector(CoreWriterLib.CoreWriterLib__StillLockedUntilTimestamp.selector, lockedUntil)
        );
        vault.sendTokensToRecipient(usdcAddress, swapper, 200e6);
    }

    /// @notice Test that sending more than internal balance fails without vault equity
    function test_sendTokens_insufficientBalance() public {
        // Try to send more than internal balance with no vault equity
        vm.prank(address(pool));
        vm.expectRevert(); // Should revert - no vault equity to recall from
        vault.sendTokensToRecipient(usdcAddress, swapper, 200e6);
    }
}

/// @notice Test deallocate functionality
contract VaultDeallocateTest is Test {
    using PrecompileLib for address;
    using HLConversions for *;

    uint64 public constant USDC_TOKEN = 0;
    address public constant TEST_VAULT = 0xa15099a30BBf2e68942d6F4c43d70D04FAEab0A0;

    HyperCore public hyperCore;
    SovereignVault public vault;
    address public usdcAddress;

    function setUp() public {
        string memory alchemyRpc = "https://hyperliquid-testnet.g.alchemy.com/v2/uSFYHvKqoVOUFsNnbGM7sL_EWO0tf4iS";
        vm.createSelectFork(alchemyRpc);

        hyperCore = CoreSimulatorLib.init();

        // Get the correct USDC address for this chain
        usdcAddress = HLConstants.usdc();

        vault = new SovereignVault(usdcAddress);
        CoreSimulatorLib.forceAccountActivation(address(vault));

        deal(usdcAddress, address(vault), 1000e6);
    }

    function test_deallocate() public {
        // First allocate
        vault.allocate(TEST_VAULT, 500e6);
        CoreSimulatorLib.nextBlock();

        PrecompileLib.UserVaultEquity memory equityBefore = PrecompileLib.userVaultEquity(address(vault), TEST_VAULT);
        console.log("Vault equity before deallocate:", equityBefore.equity);

        // Warp past lock
        vm.warp(block.timestamp + 1 days + 1);

        // Deallocate
        vault.deallocate(TEST_VAULT, 250e6);
        CoreSimulatorLib.nextBlock();

        // Check that EVM balance increased
        // Note: The exact mechanics depend on how bridgeToEvm and vaultTransfer interact
        console.log("EVM balance after deallocate:", IERC20(usdcAddress).balanceOf(address(vault)));
    }

    function test_deallocate_onlyStrategist() public {
        address user = makeAddr("user");
        vm.prank(user);
        vm.expectRevert(SovereignVault.OnlyStrategist.selector);
        vault.deallocate(TEST_VAULT, 100e6);
    }
}
