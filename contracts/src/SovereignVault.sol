// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ISovereignVaultMinimal} from "./interfaces/ISovereignVaultMinimal.sol";
import {ISovereignPool} from "./SovereignPool.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {CoreWriterLib} from "@hyper-evm-lib/src/CoreWriterLib.sol";
import {HLConversions} from "@hyper-evm-lib/src/CoreWriterLib.sol";

contract SovereignVault is ISovereignVaultMinimal {
    using SafeERC20 for IERC20;

    address public immutable strategist;
    uint256 public constant MIN_BUFFER = 50e6; // 50 USDC
    address public immutable usdc;
    address public defaultVault;

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

    // Interface required function - returns total reserves (internal + external)
    function getReservesForPool(address _pool, address[] calldata _tokens) external view returns (uint256[] memory) {
        uint256[] memory internalReserves = getInternalReservesForPool(_tokens);
        uint256[] memory totalReserves = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            totalReserves[i] = internalReserves[i];
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

        if (_token == usdc) {
            uint256 amountNeeded = _amount - internalBalance;
            withdrawFromVaultAndSend(defaultVault, address(this), uint64(amountNeeded));
        }
    }

    function changeDefaultVault(address newVault) external onlyStrategist {
        defaultVault = newVault;
    }

    /**
     * @notice Withdraws USDC from vault and sends to recipient
     * @dev vaultTransfer checks if funds are withdrawable and reverts if locked
     * @param vault Address of the vault to withdraw from
     * @param recipient Address to send the withdrawn USDC to
     * @param coreAmount Amount of USDC to withdraw and send
     */
    function withdrawFromVaultAndSend(address vault, address recipient, uint64 coreAmount) public {
        uint64 usdcPerpAmount = HLConversions.weiToPerp(coreAmount);

        CoreWriterLib.vaultTransfer(vault, false, usdcPerpAmount);

        CoreWriterLib.transferUsdClass(usdcPerpAmount, false);
        // 0 usdc token id
        CoreWriterLib.spotSend(recipient, 0, coreAmount);
    }

    // Allocate excess USDC to lending market for yield
    function allocate(address vault, uint256 usdAmount) external onlyStrategist {
        uint256 usdcBalance = IERC20(usdc).balanceOf(address(this));
        if (usdcBalance < MIN_BUFFER + usdAmount) revert InsufficientBuffer();

        CoreWriterLib.vaultTransfer(vault, true, uint64(usdAmount));
    }

    // Withdraw from lending market back to vault
    function deallocate(address vault, uint256 usdAmount) external onlyStrategist {
        // ISlimLend(lendingMarket).lpRedeemShares(_shares, 0);
        CoreWriterLib.vaultTransfer(vault, false, uint64(usdAmount));
    }

    function claimPoolManagerFees(uint256 _feePoolManager0, uint256 _feePoolManager1) external onlyAuthorizedPool {
        // Pool manager fees are tracked in the pool, this is called to claim them
        // In this implementation, fees stay in the vault as part of reserves
    }
}
