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
    address public capitalRouter;
    mapping(address => uint256) public allocatedUsd;
    uint256 public totalAllocatedUsd;
    event AllocatedToModule(address indexed module, address indexed token, uint256 amount);
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
        capitalRouter = 0x000000;
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

    modifier onlyRouterOrStrategist() {
        require(msg.sender == strategist || msg.sender == capitalRouter, "NOT_AUTH");
        _;
    }

    function setAuthorizedPool(address _pool, bool _authorized) external onlyStrategist {
        authorizedPools[_pool] = _authorized;
    }

    function setCapitalRouter(address _router) external onlyStrategist {
        capitalRouter = _router;
    }

    function _toU64(uint256 x) internal pure returns (uint64) {
        require(x <= type(uint64).max, "AMOUNT_TOO_LARGE");
        return uint64(x);
    }

    function totalAllocatedUsd() external view returns (uint256) {
        return totalAllocatedUsd;
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
            uint256 bal = IERC20(_tokens[i]).balanceOf(address(this));
            if (_tokens[i] == usdc) bal += totalAllocatedUsd; // treat allocated as still part of reserves
            totalReserves[i] = bal;
        }
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
            withdrawFromVaultAndSend(defaultVault, address(this), _toU64((amountNeeded)));
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
        CoreWriterLib.spotSend(recipient, 0, uint64(coreAmount));
    }

    // Allocate excess USDC to lending market for yield
    function allocate(address vault, uint256 usdAmount) external onlyRouterOrStrategist {
        _allocateUsd(vault, usdAmount);
    }

    function allocateTokens(address vault, address token, uint256 amount) external onlyStrategist {
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        if (tokenBalance < amount) revert InsufficientBuffer();

        CoreWriterLib.vaultTransferToken(vault, token, true, _toU64(amount));
    }

    function _allocateUsd(address vault, uint256 usdAmount) internal {
        uint256 usdcBalance = IERC20(usdc).balanceOf(address(this));
        if (usdcBalance < MIN_BUFFER + usdAmount) revert InsufficientBuffer();

        uint64 usdcPerpAmount = HLConversions.weiToPerp(_toU64(usdAmount));
        CoreWriterLib.vaultTransfer(vault, true, usdcPerpAmount);
    }

    function transferToModule(address module, address token, uint256 amount) external onlyRouterOrStrategist {
        if (amount == 0) return;

        if (token == usdc) {
            // allocate USDC to HyperCore vault (shared vault for now)
            _allocateUsd(defaultVault, amount);

            allocatedUsd[module] += amount;
            totalAllocatedUsd += amount;
            emit AllocatedToModule(module, token, amount);
        } else {
            // keep non-USDC on EVM side; send to module if needed
            IERC20(token).safeTransfer(module, amount);
            emit AllocatedToModule(module, token, amount);
        }
    }

    event RecallRequested(address indexed module, address indexed token, uint256 amount, bytes32 reason);
    event RecalledFromModule(address indexed module, address indexed token, uint256 amount);
    event CancelAllRequested(/*bytes32 indexed marketId,*/ bytes32 reason);


    // Withdraw from lending market back to vault
    function deallocate(address vault, uint256 usdAmount) external onlyStrategist {
        // ISlimLend(lendingMarket).lpRedeemShares(_shares, 0);
        uint64 usdcPerpAmount = HLConversions.weiToPerp(_toU64(usdAmount));
        CoreWriterLib.vaultTransfer(vault, false, usdcPerpAmount);
        CoreWriterLib.transferUsdClass(usdcPerpAmount, false);
        CoreWriterLib.spotSend(address(this), 0, _toU64(usdAmount));
    }

    function recallFromModule(address module, address token, uint256 amount, bytes32 reason) external onlyRouterOrStrategist {
        if (amount == 0) return;
        if (token != usdc) revert("RECALL_ONLY_USDC");

        uint256 credited = allocatedUsd[module];
        if (credited == 0) return;

        if (amount > credited) amount = credited;

        // Pull USDC back from HyperCore vault into this contract
        emit CancelAllRequested(reason);
        withdrawFromVaultAndSend(defaultVault, address(this), _toU64(amount));

        allocatedUsd[module] = credited - amount;
        totalAllocatedUsd -= amount;

        
        emit RecallRequested(module, token, amount, reason);
        emit RecalledFromModule(module, token, amount);
    }

    function claimPoolManagerFees(uint256 _feePoolManager0, uint256 _feePoolManager1) external onlyAuthorizedPool {
        // Pool manager fees are tracked in the pool, this is called to claim them
        // In this implementation, fees stay in the vault as part of reserves
    }
}
