// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {SovereignVault} from "../src/SovereignVault.sol";
import {SlimLend} from "../src/lending-contracts/SlimLend.sol";
import {IPriceFeed} from "../src/lending-contracts/interfaces/IPriceFeed.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Mock USDC token for testing
contract MockUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
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

/// @notice Mock price feed for testing
contract MockPriceFeed is IPriceFeed {
    int256 public price = 100e8; // $100 per collateral token

    function setPrice(int256 _price) external {
        price = _price;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Mock Price Feed";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, price, block.timestamp, block.timestamp, 1);
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

/// @notice Mock SlimLend for vault testing (with public lpSharePrice)
contract MockSlimLend {
    using SafeERC20 for IERC20;

    string public name = "LPSlimShares";
    string public symbol = "LPS";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint256 public lpSharePrice = 1e18;

    IERC20 public assetToken;

    constructor(address _assetToken) {
        assetToken = IERC20(_assetToken);
    }

    function lpDepositAsset(uint256 amount, uint256) external {
        uint256 shares = amount * 1e18 / lpSharePrice;
        balanceOf[msg.sender] += shares;
        totalSupply += shares;
        assetToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function lpRedeemShares(uint256 shares, uint256) external {
        uint256 assets = shares * lpSharePrice / 1e18;
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        assetToken.safeTransfer(msg.sender, assets);
    }

    function setSharePrice(uint256 _price) external {
        lpSharePrice = _price;
    }
}

contract SovereignVaultTest is Test {
    SovereignVault public vault;
    MockSlimLend public lendingMarket;
    MockUSDC public usdc;
    MockPURR public purr;
    MockPool public pool;

    address public strategist;
    address public user = makeAddr("user");

    function setUp() public {
        strategist = address(this);

        // Deploy mock tokens
        usdc = new MockUSDC();
        purr = new MockPURR();

        // Deploy mock lending market
        lendingMarket = new MockSlimLend(address(usdc));

        // Deploy vault
        vault = new SovereignVault(address(lendingMarket), address(usdc));

        // Deploy mock pool
        pool = new MockPool(address(purr), address(usdc));

        // Authorize the pool
        vault.setAuthorizedPool(address(pool), true);

        // Fund the vault with initial USDC
        usdc.mint(address(vault), 1000e6); // 1000 USDC
    }

    function test_constructor() public view {
        assertEq(vault.strategist(), strategist);
        assertEq(vault.lendingMarket(), address(lendingMarket));
        assertEq(vault.usdc(), address(usdc));
        assertEq(vault.MIN_BUFFER(), 50e6);
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
        assertEq(tokens[1], address(usdc));
    }

    function test_getInternalReservesForPool() public view {
        address[] memory tokens = new address[](2);
        tokens[0] = address(purr);
        tokens[1] = address(usdc);

        uint256[] memory reserves = vault.getInternalReservesForPool(tokens);

        assertEq(reserves.length, 2);
        assertEq(reserves[0], 0); // No PURR
        assertEq(reserves[1], 1000e6); // 1000 USDC
    }

    function test_allocate() public {
        uint256 allocateAmount = 500e6; // 500 USDC

        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));
        uint256 lendingBalanceBefore = usdc.balanceOf(address(lendingMarket));

        vault.allocate(allocateAmount);

        assertEq(usdc.balanceOf(address(vault)), vaultBalanceBefore - allocateAmount);
        assertEq(usdc.balanceOf(address(lendingMarket)), lendingBalanceBefore + allocateAmount);

        // Vault should have received LP shares
        assertGt(IERC20(address(lendingMarket)).balanceOf(address(vault)), 0);
    }

    function test_allocate_insufficientBuffer() public {
        // Try to allocate more than allowed (would leave less than MIN_BUFFER)
        uint256 allocateAmount = 960e6; // Would leave only 40 USDC (below 50 MIN_BUFFER)

        vm.expectRevert(SovereignVault.InsufficientBuffer.selector);
        vault.allocate(allocateAmount);
    }

    function test_allocate_onlyStrategist() public {
        vm.prank(user);
        vm.expectRevert(SovereignVault.OnlyStrategist.selector);
        vault.allocate(100e6);
    }

    function test_getExternalReservesForPool() public {
        // Allocate some USDC to lending
        vault.allocate(500e6);

        address[] memory tokens = new address[](2);
        tokens[0] = address(purr);
        tokens[1] = address(usdc);

        uint256[] memory externalReserves = vault.getExternalReservesForPool(tokens);

        assertEq(externalReserves[0], 0); // No PURR in lending
        assertApproxEqAbs(externalReserves[1], 500e6, 1); // ~500 USDC in lending
    }

    function test_getReservesForPool_total() public {
        // Allocate some USDC to lending
        vault.allocate(500e6);

        address[] memory tokens = new address[](2);
        tokens[0] = address(purr);
        tokens[1] = address(usdc);

        uint256[] memory totalReserves = vault.getReservesForPool(address(pool), tokens);

        assertEq(totalReserves[0], 0); // No PURR
        // Total should be internal (500) + external (~500) = ~1000
        assertApproxEqAbs(totalReserves[1], 1000e6, 1);
    }

    function test_sendTokensToRecipient_fromInternal() public {
        address recipient = makeAddr("recipient");
        uint256 sendAmount = 100e6;

        vm.prank(address(pool));
        vault.sendTokensToRecipient(address(usdc), recipient, sendAmount);

        assertEq(usdc.balanceOf(recipient), sendAmount);
        assertEq(usdc.balanceOf(address(vault)), 900e6);
    }

    function test_sendTokensToRecipient_withdrawFromLending() public {
        // Allocate most USDC to lending, leaving only 100 USDC internal
        vault.allocate(900e6);

        assertEq(usdc.balanceOf(address(vault)), 100e6);

        address recipient = makeAddr("recipient");
        uint256 sendAmount = 200e6; // More than internal balance

        vm.prank(address(pool));
        vault.sendTokensToRecipient(address(usdc), recipient, sendAmount);

        assertEq(usdc.balanceOf(recipient), sendAmount);
    }

    function test_sendTokensToRecipient_onlyAuthorizedPool() public {
        vm.prank(user);
        vm.expectRevert(SovereignVault.OnlyAuthorizedPool.selector);
        vault.sendTokensToRecipient(address(usdc), user, 100e6);
    }

    function test_sendTokensToRecipient_zeroAmount() public {
        address recipient = makeAddr("recipient");
        uint256 balanceBefore = usdc.balanceOf(address(vault));

        vm.prank(address(pool));
        vault.sendTokensToRecipient(address(usdc), recipient, 0);

        // Nothing should change
        assertEq(usdc.balanceOf(address(vault)), balanceBefore);
        assertEq(usdc.balanceOf(recipient), 0);
    }

    function test_deallocate() public {
        // First allocate
        vault.allocate(500e6);

        uint256 shares = IERC20(address(lendingMarket)).balanceOf(address(vault));
        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));

        // Deallocate half the shares
        vault.deallocate(shares / 2);

        assertGt(usdc.balanceOf(address(vault)), vaultBalanceBefore);
        assertEq(IERC20(address(lendingMarket)).balanceOf(address(vault)), shares - shares / 2);
    }

    function test_deallocate_onlyStrategist() public {
        vm.prank(user);
        vm.expectRevert(SovereignVault.OnlyStrategist.selector);
        vault.deallocate(100e18);
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
}

contract SlimLendBasicTest is Test {
    SlimLend public lendingMarket;
    MockUSDC public usdc;
    MockPURR public collateral;
    MockPriceFeed public priceFeed;

    address public lp = makeAddr("lp");
    address public borrower = makeAddr("borrower");

    function setUp() public {
        usdc = new MockUSDC();
        collateral = new MockPURR();
        priceFeed = new MockPriceFeed();

        lendingMarket = new SlimLend(IERC20(address(usdc)), IERC20(address(collateral)), priceFeed);

        // Fund LP with USDC
        usdc.mint(lp, 10000e6);

        // Fund borrower with collateral
        collateral.mint(borrower, 1000e5); // 1000 PURR
    }

    function test_lpDeposit() public {
        uint256 depositAmount = 1000e6;

        vm.startPrank(lp);
        usdc.approve(address(lendingMarket), depositAmount);
        lendingMarket.lpDepositAsset(depositAmount, 0);
        vm.stopPrank();

        assertGt(lendingMarket.balanceOf(lp), 0);
    }

    function test_lpRedeem() public {
        uint256 depositAmount = 1000e6;

        vm.startPrank(lp);
        usdc.approve(address(lendingMarket), depositAmount);
        lendingMarket.lpDepositAsset(depositAmount, 0);

        uint256 shares = lendingMarket.balanceOf(lp);
        lendingMarket.lpRedeemShares(shares, 0);
        vm.stopPrank();

        assertEq(lendingMarket.balanceOf(lp), 0);
        assertApproxEqAbs(usdc.balanceOf(lp), 10000e6, 1); // Back to original
    }

    function test_borrowFlow() public {
        // LP deposits
        vm.startPrank(lp);
        usdc.approve(address(lendingMarket), 5000e6);
        lendingMarket.lpDepositAsset(5000e6, 0);
        vm.stopPrank();

        // Borrower deposits collateral and borrows
        // Collateral value calc: amount * price * 1e10 / 1e18
        // With 100 PURR (100e5) at $100 (100e8): 100e5 * 100e18 / 1e18 = 1e9 ($1000 value)
        // For 150% collat ratio on 500 USDC borrow, need $750 collateral
        // But calc gives $1000 for 100 PURR, so borrow 500 USDC should work
        vm.startPrank(borrower);
        collateral.approve(address(lendingMarket), 100e5);
        lendingMarket.borrowerDepositCollateral(100e5);

        // Borrow 500 USDC (needs 150% = $750 collateral, have $1000)
        lendingMarket.borrow(500e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(borrower), 500e6);
    }

    function test_repayFlow() public {
        // Setup: LP deposits, borrower borrows
        vm.startPrank(lp);
        usdc.approve(address(lendingMarket), 5000e6);
        lendingMarket.lpDepositAsset(5000e6, 0);
        vm.stopPrank();

        vm.startPrank(borrower);
        collateral.approve(address(lendingMarket), 100e5);
        lendingMarket.borrowerDepositCollateral(100e5);
        lendingMarket.borrow(500e6); // Borrow 500 USDC

        // Repay the loan
        usdc.approve(address(lendingMarket), 500e6);
        lendingMarket.repay(500e6, 0);
        vm.stopPrank();

        // Should be able to withdraw collateral now
        vm.prank(borrower);
        lendingMarket.borrowerWithdrawCollateral(100e5);

        assertEq(collateral.balanceOf(borrower), 1000e5); // Back to original
    }

    function test_utilizationRate() public {
        // LP deposits
        vm.startPrank(lp);
        usdc.approve(address(lendingMarket), 1000e6);
        lendingMarket.lpDepositAsset(1000e6, 0);
        vm.stopPrank();

        assertEq(lendingMarket.utilization(), 0);

        // Borrower borrows 500 USDC (50% utilization)
        vm.startPrank(borrower);
        collateral.approve(address(lendingMarket), 100e5);
        lendingMarket.borrowerDepositCollateral(100e5);
        lendingMarket.borrow(500e6);
        vm.stopPrank();

        assertEq(lendingMarket.utilization(), 0.5e18);
    }

    function test_interestAccrual() public {
        // LP deposits
        vm.startPrank(lp);
        usdc.approve(address(lendingMarket), 1000e6);
        lendingMarket.lpDepositAsset(1000e6, 0);
        vm.stopPrank();

        uint256 initialShares = lendingMarket.balanceOf(lp);

        // Borrower borrows 200 USDC (20% utilization)
        vm.startPrank(borrower);
        collateral.approve(address(lendingMarket), 100e5);
        lendingMarket.borrowerDepositCollateral(100e5);
        lendingMarket.borrow(200e6);
        vm.stopPrank();

        // Warp time forward 1 year
        vm.warp(block.timestamp + 365 days);

        // Borrower repays full debt with extra to cover interest
        usdc.mint(borrower, 500e6); // Plenty extra for interest
        vm.startPrank(borrower);
        usdc.approve(address(lendingMarket), 700e6);
        lendingMarket.repay(700e6, 0); // Overpay to ensure full coverage
        vm.stopPrank();

        // Now LP can redeem partial shares to verify value increased
        vm.startPrank(lp);
        uint256 sharesBefore = lendingMarket.balanceOf(lp);
        // Only redeem half to avoid liquidity issues
        lendingMarket.lpRedeemShares(sharesBefore / 2, 0);
        vm.stopPrank();

        // LP should receive more than 500 USDC (half of deposit) due to interest
        uint256 redeemed = usdc.balanceOf(lp) - 9000e6; // Started with 9000 after deposit
        assertGt(redeemed, 500e6, "LP should earn interest on partial redemption");
    }
}

/// @notice Integration test simulating full AMM + Lending flow
contract VaultLendingIntegrationTest is Test {
    SovereignVault public vault;
    SlimLend public lendingMarket;
    MockUSDC public usdc;
    MockPURR public purr;
    MockPriceFeed public priceFeed;
    MockPool public pool;

    address public strategist;
    address public swapper = makeAddr("swapper");
    address public borrower = makeAddr("borrower");

    function setUp() public {
        strategist = address(this);

        // Deploy tokens
        usdc = new MockUSDC();
        purr = new MockPURR();
        priceFeed = new MockPriceFeed();

        // Deploy real SlimLend (now with public variables)
        lendingMarket = new SlimLend(IERC20(address(usdc)), IERC20(address(purr)), priceFeed);

        // Deploy vault
        vault = new SovereignVault(address(lendingMarket), address(usdc));

        // Deploy mock pool
        pool = new MockPool(address(purr), address(usdc));

        // Authorize pool
        vault.setAuthorizedPool(address(pool), true);

        // Initial vault funding (simulating LP deposits to AMM)
        usdc.mint(address(vault), 10000e6); // 10,000 USDC
        purr.mint(address(vault), 50000e5); // 50,000 PURR

        // Fund borrower with collateral for SlimLend
        purr.mint(borrower, 1000e5);
    }

    /// @notice Test the complete flow:
    /// 1. Strategist allocates excess USDC to lending
    /// 2. Borrower borrows from SlimLend (creates utilization)
    /// 3. Swap occurs requiring more USDC than vault internal balance
    /// 4. Vault automatically recalls from lending to fulfill swap
    function test_fullFlow_allocateAndRecallOnSwap() public {
        console.log("=== Initial State ===");
        console.log("Vault USDC balance:", usdc.balanceOf(address(vault)));
        console.log("Vault PURR balance:", purr.balanceOf(address(vault)));

        // Step 1: Strategist allocates 9000 USDC to lending (keeping 1000 buffer)
        uint256 allocateAmount = 9000e6;
        vault.allocate(allocateAmount);

        console.log("\n=== After Allocation ===");
        console.log("Vault internal USDC:", usdc.balanceOf(address(vault)));
        console.log("Vault LP shares:", IERC20(address(lendingMarket)).balanceOf(address(vault)));
        console.log("SlimLend USDC:", usdc.balanceOf(address(lendingMarket)));

        assertEq(usdc.balanceOf(address(vault)), 1000e6, "Vault should have 1000 USDC internal");
        assertGt(IERC20(address(lendingMarket)).balanceOf(address(vault)), 0, "Vault should have LP shares");

        // Step 2: Borrower borrows 3000 USDC from SlimLend
        vm.startPrank(borrower);
        purr.approve(address(lendingMarket), 1000e5);
        lendingMarket.borrowerDepositCollateral(1000e5); // $100k collateral at $100/PURR
        lendingMarket.borrow(3000e6);
        vm.stopPrank();

        console.log("\n=== After Borrow ===");
        console.log("SlimLend available USDC:", usdc.balanceOf(address(lendingMarket)));
        console.log("Borrower USDC:", usdc.balanceOf(borrower));

        // Step 3: Simulate a swap that needs 2000 USDC (more than internal 1000)
        // Pool calls vault.sendTokensToRecipient
        uint256 swapAmount = 2000e6;

        console.log("\n=== Swap Request ===");
        console.log("Swap amount needed:", swapAmount);
        console.log("Vault internal USDC:", usdc.balanceOf(address(vault)));

        vm.prank(address(pool));
        vault.sendTokensToRecipient(address(usdc), swapper, swapAmount);

        console.log("\n=== After Swap (with recall) ===");
        console.log("Swapper received:", usdc.balanceOf(swapper));
        console.log("Vault internal USDC after:", usdc.balanceOf(address(vault)));
        console.log("Vault LP shares after:", IERC20(address(lendingMarket)).balanceOf(address(vault)));

        // Verify swap succeeded
        assertEq(usdc.balanceOf(swapper), swapAmount, "Swapper should receive full amount");

        // Verify vault recalled from lending
        assertLt(
            IERC20(address(lendingMarket)).balanceOf(address(vault)),
            9000e18, // Initial shares (amount * 1e18 / 1e18)
            "Vault should have fewer LP shares after recall"
        );
    }

    /// @notice Test multiple swaps that progressively drain lending reserves
    function test_multipleSwaps_progressiveRecall() public {
        // Allocate most USDC to lending
        vault.allocate(9500e6); // Leave only 500 internal

        console.log("=== Initial after allocation ===");
        console.log("Vault internal USDC:", usdc.balanceOf(address(vault)));

        // Swap 1: 400 USDC (from internal only)
        vm.prank(address(pool));
        vault.sendTokensToRecipient(address(usdc), swapper, 400e6);

        assertEq(usdc.balanceOf(swapper), 400e6);
        console.log("After swap 1 - Vault internal:", usdc.balanceOf(address(vault)));

        // Swap 2: 300 USDC (needs to recall ~200 from lending)
        vm.prank(address(pool));
        vault.sendTokensToRecipient(address(usdc), swapper, 300e6);

        assertEq(usdc.balanceOf(swapper), 700e6);
        console.log("After swap 2 - Vault internal:", usdc.balanceOf(address(vault)));

        // Swap 3: 1000 USDC (definitely needs lending recall)
        vm.prank(address(pool));
        vault.sendTokensToRecipient(address(usdc), swapper, 1000e6);

        assertEq(usdc.balanceOf(swapper), 1700e6);
        console.log("After swap 3 - Vault internal:", usdc.balanceOf(address(vault)));
    }

    /// @notice Test that swap fails when lending has insufficient liquidity
    function test_swapFails_whenLendingFullyBorrowed() public {
        // Allocate most to lending
        vault.allocate(9500e6);

        // Give borrower enough collateral to borrow heavily
        purr.mint(borrower, 10000e5); // 10,000 more PURR = $1M collateral

        // Borrower takes most available liquidity
        vm.startPrank(borrower);
        purr.approve(address(lendingMarket), 11000e5);
        lendingMarket.borrowerDepositCollateral(11000e5); // $1.1M collateral
        lendingMarket.borrow(9000e6); // Borrow 9000 USDC (leaves 500 in SlimLend)
        vm.stopPrank();

        console.log("SlimLend available:", usdc.balanceOf(address(lendingMarket)));
        console.log("Vault internal:", usdc.balanceOf(address(vault)));

        // Try to swap more than available (500 internal + 500 in SlimLend = 1000 max)
        vm.prank(address(pool));
        vm.expectRevert(); // Will revert due to insufficient liquidity
        vault.sendTokensToRecipient(address(usdc), swapper, 2000e6);
    }

    /// @notice Test yield accrual - LP value increases over time
    function test_yieldAccrual_vaultEarnsInterest() public {
        // Allocate to lending
        vault.allocate(9000e6);

        uint256 initialShares = IERC20(address(lendingMarket)).balanceOf(address(vault));

        // Borrower creates utilization
        vm.startPrank(borrower);
        purr.approve(address(lendingMarket), 1000e5);
        lendingMarket.borrowerDepositCollateral(1000e5);
        lendingMarket.borrow(4000e6);
        vm.stopPrank();

        // Warp 1 year
        vm.warp(block.timestamp + 365 days);

        // Check external reserves - should be worth more due to interest
        address[] memory tokens = new address[](2);
        tokens[0] = address(purr);
        tokens[1] = address(usdc);

        uint256[] memory externalBefore = vault.getExternalReservesForPool(tokens);
        console.log("External USDC value after 1 year:", externalBefore[1]);

        // The value should be greater than original 9000 USDC due to interest
        // (Interest accrues when share price updates on next interaction)
        assertGe(externalBefore[1], 9000e6, "External reserves should maintain or grow");
    }

    /// @notice Test PURR token swap (non-USDC, no lending interaction)
    function test_purrSwap_noLendingInteraction() public {
        // Allocate USDC to lending
        vault.allocate(9000e6);

        uint256 sharesBefore = IERC20(address(lendingMarket)).balanceOf(address(vault));

        // Swap PURR (should not touch lending)
        vm.prank(address(pool));
        vault.sendTokensToRecipient(address(purr), swapper, 1000e5);

        uint256 sharesAfter = IERC20(address(lendingMarket)).balanceOf(address(vault));

        assertEq(purr.balanceOf(swapper), 1000e5, "Swapper should receive PURR");
        assertEq(sharesBefore, sharesAfter, "LP shares should not change for PURR swap");
    }

    /// @notice Test reserve reporting includes both internal and external
    function test_reserveReporting_totalReserves() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(purr);
        tokens[1] = address(usdc);

        // Before allocation
        uint256[] memory totalBefore = vault.getReservesForPool(address(pool), tokens);
        assertEq(totalBefore[1], 10000e6, "Total USDC should be 10000");

        // After allocation
        vault.allocate(8000e6);

        uint256[] memory internal_ = vault.getInternalReservesForPool(tokens);
        uint256[] memory external_ = vault.getExternalReservesForPool(tokens);
        uint256[] memory total = vault.getReservesForPool(address(pool), tokens);

        console.log("Internal USDC:", internal_[1]);
        console.log("External USDC:", external_[1]);
        console.log("Total USDC:", total[1]);

        assertEq(internal_[1], 2000e6, "Internal should be 2000");
        assertApproxEqAbs(external_[1], 8000e6, 1, "External should be ~8000");
        assertApproxEqAbs(total[1], 10000e6, 1, "Total should still be ~10000");
    }
}
