// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {SovereignVault} from "../src/SovereignVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";

/**
 * @title DeploySovereignVault
 * @notice Deployment script for SovereignVault on Hyperliquid testnet
 *
 * Usage:
 *   Deploy only:
 *     forge script script/DeploySovereignVault.s.sol:DeploySovereignVault --rpc-url $RPC_URL --broadcast
 *
 *   Deploy and verify:
 *     forge script script/DeploySovereignVault.s.sol:DeploySovereignVault --rpc-url $RPC_URL --broadcast --verify
 */
contract DeploySovereignVault is Script {
    // Testnet USDC
    address constant TESTNET_USDC = 0x2B3370eE501B4a559b57D449569354196457D8Ab;

    // HLP Vault address (same on testnet and mainnet)
    address constant HLP_VAULT = 0xa15099a30BBf2e68942d6F4c43d70D04FAEab0A0;

    function run() external {
        console.log("=== SovereignVault Deployment ===");

        console.log("Chain ID:", block.chainid);

        // Get correct USDC address based on chain
        address usdcAddress = block.chainid == 998 ? TESTNET_USDC : HLConstants.usdc();
        console.log("USDC Address:", usdcAddress);

        vm.startBroadcast();

        // Deploy SovereignVault
        SovereignVault vault = new SovereignVault(usdcAddress);

        console.log("\n=== Deployment Complete ===");
        console.log("SovereignVault deployed at:", address(vault));
        console.log("Strategist:", vault.strategist());
        console.log("Default Vault (HLP):", vault.defaultVault());

        vm.stopBroadcast();

        console.log("\n=== Next Steps ===");
        console.log("1. Fund the vault with USDC");
        console.log("2. Authorize your pool: vault.setAuthorizedPool(poolAddress, true)");
        console.log("3. Test allocate(): vault.allocate(HLP_VAULT, amount)");
        console.log("4. Check vault equity via precompile or UI");
    }
}

/**
 * @title TestVaultAllocation
 * @notice Test script to allocate USDC from vault to HLP
 *
 * Usage:
 *   forge script script/DeploySovereignVault.s.sol:TestVaultAllocation \
 *     --rpc-url $RPC_URL --broadcast \
 *     --sig "run(address,uint256)" <VAULT_ADDRESS> <AMOUNT_USDC_6_DECIMALS>
 *
 * Example (allocate 100 USDC):
 *   forge script script/DeploySovereignVault.s.sol:TestVaultAllocation \
 *     --rpc-url $RPC_URL --broadcast \
 *     --sig "run(address,uint256)" 0xYourVaultAddress 100000000
 */
contract TestVaultAllocation is Script {
    address constant HLP_VAULT = 0xa15099a30BBf2e68942d6F4c43d70D04FAEab0A0;
    address constant TESTNET_USDC = 0x2B3370eE501B4a559b57D449569354196457D8Ab;

    function run(address vaultAddress, uint256 amount) external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        SovereignVault vault = SovereignVault(vaultAddress);
        address usdcAddress = vault.usdc();

        console.log("=== Test Vault Allocation ===");
        console.log("Vault:", vaultAddress);
        console.log("Amount to allocate:", amount / 1e6, "USDC");

        // Check current state
        uint256 vaultUsdcBalance = IERC20(usdcAddress).balanceOf(vaultAddress);
        console.log("\nCurrent vault USDC balance:", vaultUsdcBalance / 1e6, "USDC");

        // Check vault equity before
        PrecompileLib.UserVaultEquity memory equityBefore = PrecompileLib.userVaultEquity(vaultAddress, HLP_VAULT);
        console.log("Current HLP equity:", equityBefore.equity);

        vm.startBroadcast(deployerPrivateKey);

        // Allocate to HLP
        vault.allocate(HLP_VAULT, amount);

        vm.stopBroadcast();

        // Check state after
        uint256 vaultUsdcAfter = IERC20(usdcAddress).balanceOf(vaultAddress);
        console.log("\n=== After Allocation ===");
        console.log("Vault USDC balance:", vaultUsdcAfter / 1e6, "USDC");
        console.log("USDC bridged to Core:", (vaultUsdcBalance - vaultUsdcAfter) / 1e6, "USDC");

        console.log("\n=== Verify on HyperCore ===");
        console.log("Check vault equity for address:", vaultAddress);
        console.log("In HLP vault:", HLP_VAULT);
        console.log("Use the Hyperliquid UI or call userVaultEquity precompile after a few blocks");
    }
}

/**
 * @title TestVaultDeallocation
 * @notice Test script to deallocate USDC from HLP back to vault
 *
 * Usage:
 *   forge script script/DeploySovereignVault.s.sol:TestVaultDeallocation \
 *     --rpc-url $RPC_URL --broadcast \
 *     --sig "run(address,uint256)" <VAULT_ADDRESS> <AMOUNT_USDC_6_DECIMALS>
 */
contract TestVaultDeallocation is Script {
    address constant HLP_VAULT = 0xa15099a30BBf2e68942d6F4c43d70D04FAEab0A0;

    function run(address vaultAddress, uint256 amount) external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        SovereignVault vault = SovereignVault(vaultAddress);
        address usdcAddress = vault.usdc();

        console.log("=== Test Vault Deallocation ===");
        console.log("Vault:", vaultAddress);
        console.log("Amount to deallocate:", amount / 1e6, "USDC");

        // Check vault equity before
        PrecompileLib.UserVaultEquity memory equityBefore = PrecompileLib.userVaultEquity(vaultAddress, HLP_VAULT);
        console.log("\nCurrent HLP equity:", equityBefore.equity);
        console.log("Lock until timestamp:", equityBefore.lockedUntilTimestamp);
        console.log("Current timestamp (ms):", block.timestamp * 1000);

        if (equityBefore.lockedUntilTimestamp > block.timestamp * 1000) {
            console.log("\nWARNING: Funds are still locked!");
            console.log("Wait until:", equityBefore.lockedUntilTimestamp / 1000, "(unix timestamp)");
            return;
        }

        uint256 vaultUsdcBefore = IERC20(usdcAddress).balanceOf(vaultAddress);
        console.log("Vault USDC balance before:", vaultUsdcBefore / 1e6, "USDC");

        vm.startBroadcast(deployerPrivateKey);

        // Deallocate from HLP
        vault.deallocate(HLP_VAULT, amount);

        vm.stopBroadcast();

        console.log("\n=== Deallocation Submitted ===");
        console.log("Check vault USDC balance after a few blocks");
        console.log("The funds will bridge back from Core to EVM");
    }
}

/**
 * @title CheckVaultStatus
 * @notice Check the current status of a deployed vault
 *
 * Usage:
 *   forge script script/DeploySovereignVault.s.sol:CheckVaultStatus \
 *     --rpc-url $RPC_URL \
 *     --sig "run(address)" <VAULT_ADDRESS>
 */
contract CheckVaultStatus is Script {
    address constant HLP_VAULT = 0xa15099a30BBf2e68942d6F4c43d70D04FAEab0A0;

    function run(address vaultAddress) external view {
        SovereignVault vault = SovereignVault(vaultAddress);
        address usdcAddress = vault.usdc();

        console.log("=== Vault Status ===");
        console.log("Vault Address:", vaultAddress);
        console.log("Strategist:", vault.strategist());
        console.log("USDC:", usdcAddress);
        console.log("Default Vault:", vault.defaultVault());

        // EVM Balance
        uint256 evmBalance = IERC20(usdcAddress).balanceOf(vaultAddress);
        console.log("\n=== Balances ===");
        console.log("EVM USDC Balance:", evmBalance / 1e6, "USDC");

        // Core Spot Balance
        PrecompileLib.SpotBalance memory spotBalance = PrecompileLib.spotBalance(vaultAddress, 0);
        console.log("Core Spot USDC (wei):", spotBalance.total);

        // Vault Equity
        PrecompileLib.UserVaultEquity memory hlpEquity = PrecompileLib.userVaultEquity(vaultAddress, HLP_VAULT);
        console.log("\n=== HLP Vault Position ===");
        console.log("Equity:", hlpEquity.equity);
        console.log("Locked Until:", hlpEquity.lockedUntilTimestamp);

        if (hlpEquity.lockedUntilTimestamp > 0) {
            if (hlpEquity.lockedUntilTimestamp > block.timestamp * 1000) {
                console.log("Status: LOCKED");
                uint256 remainingMs = hlpEquity.lockedUntilTimestamp - (block.timestamp * 1000);
                console.log("Time remaining:", remainingMs / 1000, "seconds");
            } else {
                console.log("Status: UNLOCKED");
            }
        }
    }
}

/**
 * @title FundVault
 * @notice Fund the vault with USDC from deployer
 *
 * Usage:
 *   forge script script/DeploySovereignVault.s.sol:FundVault \
 *     --rpc-url $RPC_URL --broadcast \
 *     --sig "run(address,uint256)" <VAULT_ADDRESS> <AMOUNT_USDC_6_DECIMALS>
 */
contract FundVault is Script {
    address constant TESTNET_USDC = 0x2B3370eE501B4a559b57D449569354196457D8Ab;

    function run(address vaultAddress, uint256 amount) external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address usdcAddress = block.chainid == 998 ? TESTNET_USDC : HLConstants.usdc();

        console.log("=== Fund Vault ===");
        console.log("From:", deployer);
        console.log("To:", vaultAddress);
        console.log("Amount:", amount / 1e6, "USDC");

        uint256 deployerBalance = IERC20(usdcAddress).balanceOf(deployer);
        console.log("Deployer USDC balance:", deployerBalance / 1e6, "USDC");

        require(deployerBalance >= amount, "Insufficient USDC balance");

        vm.startBroadcast(deployerPrivateKey);

        bool success = IERC20(usdcAddress).transfer(vaultAddress, amount);
        require(success, "Transfer failed");

        vm.stopBroadcast();

        uint256 vaultBalance = IERC20(usdcAddress).balanceOf(vaultAddress);
        console.log("\nVault USDC balance after:", vaultBalance / 1e6, "USDC");
    }
}

/**
 * @title AuthorizePool
 * @notice Authorize a pool to interact with the vault
 *
 * Usage:
 *   forge script script/DeploySovereignVault.s.sol:AuthorizePool \
 *     --rpc-url $RPC_URL --broadcast \
 *     --sig "run(address,address)" <VAULT_ADDRESS> <POOL_ADDRESS>
 */
contract AuthorizePool is Script {
    function run(address vaultAddress, address poolAddress) external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        SovereignVault vault = SovereignVault(vaultAddress);

        console.log("=== Authorize Pool ===");
        console.log("Vault:", vaultAddress);
        console.log("Pool:", poolAddress);
        console.log("Currently authorized:", vault.authorizedPools(poolAddress));

        vm.startBroadcast(deployerPrivateKey);

        vault.setAuthorizedPool(poolAddress, true);

        vm.stopBroadcast();

        console.log("Pool authorized:", vault.authorizedPools(poolAddress));
    }
}
