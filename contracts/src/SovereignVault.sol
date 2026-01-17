// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ISovereignVaultMinimal} from "./interfaces/ISovereignVaultMinimal.sol";
import {ISovereignPool} from "./SovereignPool.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISlimLend} from "./lending-contracts/interfaces/ISlimLend.sol";

contract SovereignVault is ISovereignVaultMinimal {
    using SafeERC20 for IERC20;

    address public immutable strategist;
    address public immutable lendingMarket;
    uint256 public constant MIN_BUFFER = 50e6; // 50 USDC
    address public immutable usdc;

    mapping(address => bool) public authorizedPools;

    error OnlyAuthorizedPool();
    error OnlyStrategist();
    error InsufficientBuffer();
    error InsufficientFundsAfterWithdraw();

    constructor(address _lendingMarket, address _usdc) {
        strategist = msg.sender;
        lendingMarket = _lendingMarket;
        usdc = _usdc;
    }

    modifier onlyAuthorizedPool() {
        if (!authorizedPools[msg.sender]) revert OnlyAuthorizedPool();
        _;
    }

    modifier onlyStrategist() {
        if (msg.sender != strategist) revert OnlyStrategist();
        _;
    }

    function setAuthorizedPool(address _pool, bool _authorized) external onlyStrategist {
        authorizedPools[_pool] = _authorized;
    }

    function getTokensForPool(address _pool) external view returns (address[] memory) {
        ISovereignPool pool = ISovereignPool(_pool);
        address[] memory tokens = new address[](2);
        tokens[0] = pool.token0();
        tokens[1] = pool.token1();
        return tokens;
    }

    // reserves not deployed to lending protocols (held in vault)
    function getInternalReservesForPool(address[] calldata _tokens) public view returns (uint256[] memory) {
        uint256[] memory reserves = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            reserves[i] = IERC20(_tokens[i]).balanceOf(address(this));
        }
        return reserves;
    }

    // reserves deployed to lending protocols
    function getExternalReservesForPool(address[] calldata _tokens) public view returns (uint256[] memory) {
        uint256[] memory reserves = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (_tokens[i] == usdc) {
                // Calculate USDC value from LP shares in lending market
                uint256 lpShares = IERC20(lendingMarket).balanceOf(address(this));
                uint256 sharePrice = ISlimLend(lendingMarket).lpSharePrice();
                reserves[i] = lpShares * sharePrice / 1e18;
            } else {
                reserves[i] = 0; // Only USDC is deployed to lending
            }
        }
        return reserves;
    }

    // Interface required function - returns total reserves (internal + external)
    function getReservesForPool(address _pool, address[] calldata _tokens) external view returns (uint256[] memory) {
        uint256[] memory internalReserves = getInternalReservesForPool(_tokens);
        uint256[] memory externalReserves = getExternalReservesForPool(_tokens);
        uint256[] memory totalReserves = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            totalReserves[i] = internalReserves[i] + externalReserves[i];
        }
        return totalReserves;
    }

    // Sends tokens to recipient, withdrawing from lending market if needed
    function sendTokensToRecipient(address _token, address recipient, uint256 _amount) external onlyAuthorizedPool {
        if (_amount == 0) return;

        IERC20 token = IERC20(_token);
        uint256 internalBalance = token.balanceOf(address(this));

        if (internalBalance >= _amount) {
            token.safeTransfer(recipient, _amount);
            return;
        }

        // Only withdraw from lending if token is USDC
        if (_token == usdc) {
            uint256 shortfall = _amount - internalBalance;
            uint256 sharePrice = ISlimLend(lendingMarket).lpSharePrice();

            if (sharePrice > 0) {
                // Calculate shares needed with ceiling division
                uint256 sharesToRedeem = (shortfall * 1e18 + sharePrice - 1) / sharePrice;
                uint256 availableShares = IERC20(lendingMarket).balanceOf(address(this));

                if (sharesToRedeem > availableShares) {
                    sharesToRedeem = availableShares;
                }

                if (sharesToRedeem > 0) {
                    ISlimLend(lendingMarket).lpRedeemShares(sharesToRedeem, 0);
                }
            }
        }

        if (token.balanceOf(address(this)) < _amount) revert InsufficientFundsAfterWithdraw();
        token.safeTransfer(recipient, _amount);
    }

    // Allocate excess USDC to lending market for yield
    function allocate(uint256 _amount) external onlyStrategist {
        uint256 usdcBalance = IERC20(usdc).balanceOf(address(this));
        if (usdcBalance < MIN_BUFFER + _amount) revert InsufficientBuffer();

        // Approve lending market to spend USDC
        IERC20(usdc).approve(lendingMarket, _amount);
        ISlimLend(lendingMarket).lpDepositAsset(_amount, 0);
    }

    // Withdraw from lending market back to vault
    function deallocate(uint256 _shares) external onlyStrategist {
        ISlimLend(lendingMarket).lpRedeemShares(_shares, 0);
    }

    function claimPoolManagerFees(uint256 _feePoolManager0, uint256 _feePoolManager1) external onlyAuthorizedPool {
        // Pool manager fees are tracked in the pool, this is called to claim them
        // In this implementation, fees stay in the vault as part of reserves
    }
}
