// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/Interfaces.sol";

contract CapitalRouter {
    // --- Roles ---
    address public owner;        // admin
    address public strategist;   // bounded operator
    address public guardian;     // can pause
    bool    public paused;

    // --- External components ---
    ISovereignVault public immutable vault;
    address public immutable token0;
    address public immutable token1;

    // Modules
    address public lendingModule;    // you already have
    address public orderbookModule;  // new

    // --- Allocation targets (bps of total vault balance per token) ---
    // e.g., 2000 = 20% of each token to OB sleeve
    uint16 public targetBpsToOrderbook; // 0..10000
    uint16 public targetBpsToLending;   // 0..10000

    // Keep some buffer in vault for AMM immediate liquidity
    uint16 public minBpsIdleInVault;    // e.g. 3000 = 30% stays idle

    // --- Bounds ---
    uint16 public constant MAX_BPS = 10_000;

    event Paused(bool isPaused);
    event RolesUpdated(address owner, address strategist, address guardian);
    event ModulesUpdated(address lendingModule, address orderbookModule);
    event TargetsUpdated(uint16 bpsOrderbook, uint16 bpsLending, uint16 minIdle);
    event Rebalanced(
        uint256 vaultBal0,
        uint256 vaultBal1,
        uint256 toOrderbook0,
        uint256 toOrderbook1,
        uint256 toLending0,
        uint256 toLending1
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }
    modifier onlyStrategist() {
        require(msg.sender == strategist || msg.sender == owner, "NOT_STRATEGIST");
        _;
    }
    modifier onlyGuardian() {
        require(msg.sender == guardian || msg.sender == owner, "NOT_GUARDIAN");
        _;
    }
    modifier notPaused() {
        require(!paused, "PAUSED");
        _;
    }

    constructor(
        ISovereignVault _vault,
        address _token0,
        address _token1,
        address _owner,
        address _strategist,
        address _guardian
    ) {
        require(address(_vault) != address(0), "VAULT_0");
        require(_token0 != address(0) && _token1 != address(0), "TOKEN_0");
        vault = _vault;
        token0 = _token0;
        token1 = _token1;

        owner = _owner;
        strategist = _strategist;
        guardian = _guardian;

        // sensible defaults
        targetBpsToOrderbook = 1500; // 15%
        targetBpsToLending   = 4000; // 40%
        minBpsIdleInVault    = 3000; // 30%

        emit RolesUpdated(owner, strategist, guardian);
        emit TargetsUpdated(targetBpsToOrderbook, targetBpsToLending, minBpsIdleInVault);
    }

    // --- Admin ---
    function setRoles(address _owner, address _strategist, address _guardian) external onlyOwner {
        require(_owner != address(0) && _strategist != address(0) && _guardian != address(0), "ROLE_0");
        owner = _owner;
        strategist = _strategist;
        guardian = _guardian;
        emit RolesUpdated(owner, strategist, guardian);
    }

    function setModules(address _lending, address _orderbook) external onlyOwner {
        // allow either to be zero in early PoC
        lendingModule = _lending;
        orderbookModule = _orderbook;
        emit ModulesUpdated(_lending, _orderbook);
    }

    function setTargets(uint16 bpsOrderbook, uint16 bpsLending, uint16 minIdle) external onlyStrategist {
        require(bpsOrderbook + bpsLending + minIdle <= MAX_BPS, "BPS_SUM");
        targetBpsToOrderbook = bpsOrderbook;
        targetBpsToLending   = bpsLending;
        minBpsIdleInVault    = minIdle;
        emit TargetsUpdated(bpsOrderbook, bpsLending, minIdle);
    }

    function pause() external onlyGuardian {
        paused = true;
        emit Paused(true);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Paused(false);
    }

    // --- Core rebalancing ---
    /// @notice Pull/push funds so module allocations approximate targets.
    /// @dev For PoC: only pushes out of vault (no recalls). Add recall logic once modules support it cleanly.
    function rebalance() external notPaused onlyStrategist {
        uint256 bal0 = vault.balanceOf(token0);
        uint256 bal1 = vault.balanceOf(token1);

        // compute desired allocations
        uint256 wantOB0 = (bal0 * targetBpsToOrderbook) / MAX_BPS;
        uint256 wantOB1 = (bal1 * targetBpsToOrderbook) / MAX_BPS;

        uint256 wantL0  = (bal0 * targetBpsToLending) / MAX_BPS;
        uint256 wantL1  = (bal1 * targetBpsToLending) / MAX_BPS;

        uint256 toOB0 = 0;
        uint256 toOB1 = 0;
        uint256 toL0  = 0;
        uint256 toL1  = 0;

        // For v0: push up to desired. If you later track already-allocated amounts, use delta allocation.
        if (orderbookModule != address(0)) {
            toOB0 = wantOB0;
            toOB1 = wantOB1;
            if (toOB0 > 0) vault.transferToModule(orderbookModule, token0, toOB0);
            if (toOB1 > 0) vault.transferToModule(orderbookModule, token1, toOB1);
        }

        if (lendingModule != address(0)) {
            toL0 = wantL0;
            toL1 = wantL1;
            if (toL0 > 0) vault.transferToModule(lendingModule, token0, toL0);
            if (toL1 > 0) vault.transferToModule(lendingModule, token1, toL1);
        }

        emit Rebalanced(bal0, bal1, toOB0, toOB1, toL0, toL1);
    }
}