// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ISovereignVaultMinimal} from "./interfaces/ISovereignVaultMinimal.sol";
import {ISovereignPool} from "./SovereignPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CoreWriterLib} from "@hyper-evm-lib/src/CoreWriterLib.sol";
import {HLConversions} from "@hyper-evm-lib/src/CoreWriterLib.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";

contract SovereignVault is ISovereignVaultMinimal {
    using SafeERC20 for IERC20;

    address public immutable strategist;
    address public immutable usdc;
    address public defaultVault;
    uint256 totalAllocatedUSDC;
    uint256 usdcBalance;


    mapping(address => bool) public authorizedPools;

    error OnlyAuthorizedPool();
    error OnlyStrategist();
    error InsufficientBuffer();
    error InsufficientFundsAfterWithdraw();

    constructor(address _usdc) {
        strategist = msg.sender;
        defaultVault = 0xa15099a30BBf2e68942d6F4c43d70D04FAEab0A0; // HLP
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

    function _toU64(uint256 x) internal pure returns (uint64) {
        require(x <= type(uint64).max, "AMOUNT_TOO_LARGE");
        return uint64(x);
    }

    function getTokensForPool(address _pool) external view returns (address[] memory) {
        ISovereignPool pool = ISovereignPool(_pool);
        address[] memory tokens = new address[](2);
        tokens[0] = pool.token0();
        tokens[1] = pool.token1();
        return tokens;
    }

    // Interface required function - returns total reserves (internal + external)
    function getReservesForPool(address _pool, address[] calldata _tokens) external view returns (uint256[] memory) {
        PrecompileLib.SpotBalance memory externalUSDCReserves = PrecompileLib.spotBalance(address(this), 0);
        uint256 usdcSpotTotal = externalUSDCReserves.total;
        uint256 spotToEvm = HLConversions.perpToWei(uint64(usdcSpotTotal));
        uint256 token0Reserves = _tokens[0] == usdc
            ? IERC20(usdc).balanceOf(address(this)) + spotToEvm
            : IERC20(_tokens[0]).balanceOf(address(this));
        uint256 token1Reserves = _tokens[1] == usdc
            ? IERC20(usdc).balanceOf(address(this)) + spotToEvm
            : IERC20(_tokens[1]).balanceOf(address(this));

        uint256[] memory tokenReserves = new uint256[](_tokens.length);
        tokenReserves[0] = token0Reserves;
        tokenReserves[1] = token1Reserves;
        return tokenReserves;
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

        if (_token == usdc) {
            uint256 amountNeeded = _amount - internalBalance;

            // transfers from vault to core and bridges to evm
            CoreWriterLib.vaultTransfer(defaultVault, false, uint64(amountNeeded));
            CoreWriterLib.bridgeToEvm(usdc, amountNeeded);
            uint256 finalBalance = token.balanceOf(address(this));
            if (finalBalance < _amount) revert InsufficientFundsAfterWithdraw();
            IERC20(usdc).safeTransfer(recipient, _amount);
        }
    }

    function changeDefaultVault(address newVault) external onlyStrategist {
        defaultVault = newVault;
    }

    // ============ VAULT ALLOCATION ============

    /// @notice Allocate excess USDC to a HyperCore vault for yield
    /// @param vault The vault address to deposit into
    /// @param usdcAmount Amount of USDC to allocate (in EVM decimals, 6)
    function allocate(address vault, uint256 usdcAmount) external onlyStrategist {
        usdcBalance = IERC20(usdc).balanceOf(address(this));
        totalAllocatedUSDC += usdcAmount;

        CoreWriterLib.bridgeToCore(usdc, usdcAmount);
        CoreWriterLib.vaultTransfer(vault, true, _toU64(usdcAmount));
    }

    /// @notice Withdraw USDC from a HyperCore vault back to this contract
    /// @param vault The vault address to withdraw from
    /// @param usdcAmount Amount of USDC to deallocate (in EVM decimals, 6)
    function deallocate(address vault, uint256 usdcAmount) external onlyStrategist {
        CoreWriterLib.vaultTransfer(vault, false, _toU64(usdcAmount));
        CoreWriterLib.bridgeToEvm(usdc, usdcAmount);
        usdcBalance = IERC20(usdc).balanceOf(address(this));
        totalAllocatedUSDC -= usdcAmount;  
    }

    function getTotalAllocatedUSDC() external view returns (uint256) {
        return totalAllocatedUSDC;
    }
    
    function getUSDCBalance() external view returns (uint256) {
        return usdcBalance;
    }

    function claimPoolManagerFees(uint256 _feePoolManager0, uint256 _feePoolManager1) external onlyAuthorizedPool {
        // Pool manager fees are tracked in the pool, this is called to claim them
        // In this implementation, fees stay in the vault as part of reserves
    }
}
