#!/usr/bin/env python3
"""
SovereignVault Contract Deployer

Deploys the SovereignVault system and its components to Hyperliquid EVM.

Available Contracts:
  1. SovereignVault - Main vault that manages USDC allocation to HyperCore
  2. SovereignALM - Automated Liquidity Manager using Hyperliquid spot prices
  3. BalanceSeekingSwapFeeModule - Dynamic swap fee module

Usage:
  # Deploy just the vault
  python deploy.py --vault

  # Deploy ALM for existing pool
  python deploy.py --alm --pool-address 0x...

  # Deploy swap fee module for existing pool
  python deploy.py --fee-module --pool-address 0x...

  # Deploy vault and then authorize a pool
  python deploy.py --vault --authorize-pool 0x...

  # Deploy to mainnet (default is testnet)
  python deploy.py --vault --mainnet

Environment variables (or .env file):
  PRIVATE_KEY        - Deployer private key (with 0x prefix)
  RPC_URL            - Optional override for RPC URL
"""

import os
import sys
import json
import argparse
import subprocess
from pathlib import Path
from typing import Optional, Dict, Any, Tuple
from dataclasses import dataclass, field

try:
    from eth_account import Account
    from web3 import Web3
    from dotenv import load_dotenv
except ImportError:
    print("Installing required packages...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "web3", "python-dotenv", "eth-account"])
    from eth_account import Account
    from web3 import Web3
    from dotenv import load_dotenv

# Load environment
load_dotenv()

# ==============================================================================
# Configuration
# ==============================================================================

@dataclass
class NetworkConfig:
    """Network-specific configuration"""
    name: str
    chain_id: int
    rpc_url: str
    usdc_address: str
    hlp_vault: str  # Default HLP vault for yield
    explorer_url: Optional[str] = None

NETWORKS: Dict[str, NetworkConfig] = {
    "testnet": NetworkConfig(
        name="Hyperliquid Testnet",
        chain_id=998,
        rpc_url="https://api.hyperliquid-testnet.xyz/evm",
        usdc_address="0x2B3370eE501B4a559b57D449569354196457D8Ab",
        hlp_vault="0xa15099a30BBf2e68942d6F4c43d70D04FAEab0A0",
        explorer_url="https://testnet.hyperliquid.xyz"
    ),
    "mainnet": NetworkConfig(
        name="Hyperliquid Mainnet",
        chain_id=999,
        rpc_url="https://api.hyperliquid.xyz/evm",
        usdc_address="0x0000000000000000000000000000000000000000",  # Native USDC - update when known
        hlp_vault="0xa15099a30BBf2e68942d6F4c43d70D04FAEab0A0",
        explorer_url="https://hyperliquid.xyz"
    ),
}

# Known token addresses on testnet
TESTNET_TOKENS = {
    "PURR": "0xa9056c15938f9aff34CD497c722Ce33dB0C2fD57",
}

# ==============================================================================
# Contract Artifacts
# ==============================================================================

CONTRACTS_DIR = Path(__file__).parent / "contracts"
OUT_DIR = CONTRACTS_DIR / "out"

def get_artifact_path(contract_name: str, source_file: Optional[str] = None) -> Path:
    """Get the path to a compiled contract artifact"""
    source = source_file or f"{contract_name}.sol"
    return OUT_DIR / source / f"{contract_name}.json"

def load_contract_artifact(contract_name: str, source_file: Optional[str] = None) -> Dict[str, Any]:
    """Load compiled contract ABI and bytecode"""
    artifact_path = get_artifact_path(contract_name, source_file)
    if not artifact_path.exists():
        raise FileNotFoundError(
            f"Contract artifact not found: {artifact_path}\n"
            f"Run 'forge build' in the contracts directory first."
        )
    
    with open(artifact_path) as f:
        artifact = json.load(f)
    
    return {
        "abi": artifact["abi"],
        "bytecode": artifact["bytecode"]["object"],
    }

# ==============================================================================
# Deployment Results
# ==============================================================================

@dataclass
class DeploymentResult:
    """Results from a deployment"""
    contract_name: str
    address: str
    tx_hash: str
    constructor_args: Dict[str, Any] = field(default_factory=dict)
    gas_used: int = 0

# ==============================================================================
# Deployer Class
# ==============================================================================

class ContractDeployer:
    """Deploy contracts to Hyperliquid EVM"""
    
    def __init__(self, network: str = "testnet", private_key: Optional[str] = None):
        self.network_config = NETWORKS[network]
        self.network = network
        
        # Override RPC if provided
        rpc_url = os.getenv("RPC_URL", self.network_config.rpc_url)
        self.w3 = Web3(Web3.HTTPProvider(rpc_url))
        
        if not self.w3.is_connected():
            raise ConnectionError(f"Failed to connect to {rpc_url}")
        
        # Load private key
        pk = private_key or os.getenv("PRIVATE_KEY")
        if not pk:
            raise ValueError("PRIVATE_KEY environment variable not set")
        
        if not pk.startswith("0x"):
            pk = "0x" + pk
            
        self.account = Account.from_key(pk)
        self.deployer_address = self.account.address
        
        print(f"\n{'='*60}")
        print(f"SovereignVault Deployer")
        print(f"{'='*60}")
        print(f"Network:  {self.network_config.name} (Chain ID: {self.network_config.chain_id})")
        print(f"RPC:      {rpc_url}")
        print(f"Deployer: {self.deployer_address}")
        
        balance = self.w3.eth.get_balance(self.deployer_address)
        print(f"Balance:  {self.w3.from_wei(balance, 'ether'):.6f} ETH")
        print(f"{'='*60}\n")
    
    def _get_nonce(self) -> int:
        return self.w3.eth.get_transaction_count(self.deployer_address)
    
    def _estimate_gas(self, tx: Dict) -> int:
        try:
            return self.w3.eth.estimate_gas(tx)
        except Exception as e:
            print(f"Gas estimation failed: {e}")
            return 3_000_000  # Default fallback
    
    def _send_transaction(self, tx: Dict) -> Tuple[str, int]:
        """Sign and send a transaction, return (tx_hash, gas_used)"""
        signed = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        
        print(f"  Transaction sent: {tx_hash.hex()}")
        print(f"  Waiting for confirmation...")
        
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
        
        if receipt["status"] != 1:
            raise Exception(f"Transaction failed! Receipt: {receipt}")
        
        return tx_hash.hex(), receipt["gasUsed"]
    
    def deploy_contract(
        self,
        contract_name: str,
        constructor_args: list,
        source_file: Optional[str] = None,
        constructor_arg_names: Optional[Dict[str, Any]] = None,
    ) -> DeploymentResult:
        """Deploy a contract and return the result"""
        print(f"\nDeploying {contract_name}...")
        
        artifact = load_contract_artifact(contract_name, source_file)
        
        contract = self.w3.eth.contract(
            abi=artifact["abi"],
            bytecode=artifact["bytecode"]
        )
        
        # Build constructor transaction
        construct_tx = contract.constructor(*constructor_args)
        
        tx = {
            "from": self.deployer_address,
            "data": construct_tx.data_in_transaction,
            "chainId": self.network_config.chain_id,
            "nonce": self._get_nonce(),
            "gasPrice": self.w3.eth.gas_price,
        }
        tx["gas"] = self._estimate_gas(tx)
        
        tx_hash, gas_used = self._send_transaction(tx)
        
        # Get deployed address from receipt
        receipt = self.w3.eth.get_transaction_receipt(tx_hash)
        contract_address = receipt["contractAddress"]
        
        print(f"  ✓ {contract_name} deployed at: {contract_address}")
        print(f"  Gas used: {gas_used:,}")
        
        return DeploymentResult(
            contract_name=contract_name,
            address=contract_address,
            tx_hash=tx_hash,
            constructor_args=constructor_arg_names or {},
            gas_used=gas_used,
        )
    
    def call_contract_write(self, address: str, abi: list, function_name: str, *args) -> str:
        """Call a contract write function"""
        contract = self.w3.eth.contract(address=address, abi=abi)
        func = getattr(contract.functions, function_name)(*args)
        
        tx = func.build_transaction({
            "from": self.deployer_address,
            "chainId": self.network_config.chain_id,
            "nonce": self._get_nonce(),
            "gasPrice": self.w3.eth.gas_price,
        })
        tx["gas"] = self._estimate_gas(tx)
        
        tx_hash, _ = self._send_transaction(tx)
        return tx_hash

    # =========================================================================
    # Contract-specific deployment methods
    # =========================================================================
    
    def deploy_sovereign_vault(
        self,
        usdc_address: Optional[str] = None,
    ) -> DeploymentResult:
        """
        Deploy the SovereignVault contract.
        
        Constructor: SovereignVault(address _usdc)
        - _usdc: USDC token address
        - defaultVault is hardcoded to HLP (0xa15099a30BBf2e68942d6F4c43d70D04FAEab0A0)
        - strategist is set to msg.sender (deployer)
        """
        usdc = usdc_address or self.network_config.usdc_address
        
        return self.deploy_contract(
            "SovereignVault",
            [usdc],
            source_file="SovereignVault.sol",
            constructor_arg_names={"usdc": usdc}
        )
    
    def deploy_sovereign_alm(self, pool_address: str) -> DeploymentResult:
        """
        Deploy the SovereignALM contract.
        
        Constructor: SovereignALM(address _pool)
        - _pool: The SovereignPool this ALM serves
        - Reads spot prices from Hyperliquid L1 via PrecompileLib
        """
        return self.deploy_contract(
            "SovereignALM",
            [pool_address],
            source_file="SovereignALM.sol",
            constructor_arg_names={"pool": pool_address}
        )
    
    def deploy_swap_fee_module(
        self,
        pool_address: str,
        base_fee_bips: int = 15,
        min_fee_bips: int = 5,
        max_fee_bips: int = 100,
        deadzone_imbalance_bips: int = 200,
        penalty_slope_bips_per_pct: int = 5,
        discount_slope_bips_per_pct: int = 3,
    ) -> DeploymentResult:
        """
        Deploy the BalanceSeekingSwapFeeModule.
        
        Dynamic fee module that adjusts fees based on pool balance:
        - Swaps that worsen imbalance pay more
        - Swaps that reduce imbalance pay less
        """
        return self.deploy_contract(
            "BalanceSeekingSwapFeeModule",
            [
                pool_address,
                base_fee_bips,
                min_fee_bips,
                max_fee_bips,
                deadzone_imbalance_bips,
                penalty_slope_bips_per_pct,
                discount_slope_bips_per_pct,
            ],
            source_file="SwapFeeModule.sol",
            constructor_arg_names={
                "pool": pool_address,
                "baseFeeBips": base_fee_bips,
                "minFeeBips": min_fee_bips,
                "maxFeeBips": max_fee_bips,
            }
        )

    # =========================================================================
    # Post-deployment configuration methods
    # =========================================================================
    
    def authorize_pool_on_vault(self, vault_address: str, pool_address: str) -> str:
        """Call vault.setAuthorizedPool(pool, true)"""
        print(f"\nAuthorizing pool {pool_address} on vault...")
        
        abi = [{
            "type": "function",
            "name": "setAuthorizedPool",
            "inputs": [
                {"name": "_pool", "type": "address"},
                {"name": "_authorized", "type": "bool"}
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        }]
        
        tx_hash = self.call_contract_write(vault_address, abi, "setAuthorizedPool", pool_address, True)
        print(f"  ✓ Pool authorized. TX: {tx_hash}")
        return tx_hash
    
    def set_alm_on_pool(self, pool_address: str, alm_address: str) -> str:
        """Call pool.setALM(alm)"""
        print(f"\nSetting ALM {alm_address} on pool...")
        
        abi = [{
            "type": "function",
            "name": "setALM",
            "inputs": [{"name": "_alm", "type": "address"}],
            "outputs": [],
            "stateMutability": "nonpayable"
        }]
        
        tx_hash = self.call_contract_write(pool_address, abi, "setALM", alm_address)
        print(f"  ✓ ALM set on pool. TX: {tx_hash}")
        return tx_hash
    
    def set_swap_fee_module_on_pool(self, pool_address: str, module_address: str) -> str:
        """Call pool.setSwapFeeModule(module)"""
        print(f"\nSetting SwapFeeModule {module_address} on pool...")
        
        abi = [{
            "type": "function",
            "name": "setSwapFeeModule",
            "inputs": [{"name": "_swapFeeModule", "type": "address"}],
            "outputs": [],
            "stateMutability": "nonpayable"
        }]
        
        tx_hash = self.call_contract_write(pool_address, abi, "setSwapFeeModule", module_address)
        print(f"  ✓ SwapFeeModule set on pool. TX: {tx_hash}")
        return tx_hash
    
    def change_default_vault(self, vault_address: str, new_default_vault: str) -> str:
        """Call vault.changeDefaultVault(newVault)"""
        print(f"\nChanging default vault to {new_default_vault}...")
        
        abi = [{
            "type": "function",
            "name": "changeDefaultVault",
            "inputs": [{"name": "newVault", "type": "address"}],
            "outputs": [],
            "stateMutability": "nonpayable"
        }]
        
        tx_hash = self.call_contract_write(vault_address, abi, "changeDefaultVault", new_default_vault)
        print(f"  ✓ Default vault changed. TX: {tx_hash}")
        return tx_hash

# ==============================================================================
# Helper Functions
# ==============================================================================

def compile_contracts():
    """Compile contracts using forge"""
    print("\nCompiling contracts...")
    contracts_dir = Path(__file__).parent / "contracts"
    
    result = subprocess.run(
        ["forge", "build"],
        cwd=contracts_dir,
        capture_output=True,
        text=True
    )
    
    if result.returncode != 0:
        print(f"Compilation failed:\n{result.stderr}")
        print("\nTip: Make sure you have the correct solc version installed.")
        print("     Try running: forge build --use 0.8.19")
        sys.exit(1)
    
    print("  ✓ Contracts compiled successfully")

def save_deployment(deployment_data: Dict, filename: str):
    """Save deployment data to JSON file"""
    with open(filename, "w") as f:
        json.dump(deployment_data, f, indent=2)
    print(f"\nDeployment info saved to: {filename}")

# ==============================================================================
# Main CLI
# ==============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Deploy SovereignVault contracts to Hyperliquid EVM",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Deploy SovereignVault
  python deploy.py --vault

  # Deploy vault and authorize a pool
  python deploy.py --vault --authorize-pool 0xPoolAddress

  # Deploy ALM for existing pool
  python deploy.py --alm --pool-address 0xPoolAddress

  # Deploy fee module for existing pool
  python deploy.py --fee-module --pool-address 0xPoolAddress

  # Deploy to mainnet
  python deploy.py --vault --mainnet

  # Use custom USDC address
  python deploy.py --vault --usdc 0xCustomUSDC
        """
    )
    
    # What to deploy
    parser.add_argument("--vault", action="store_true", help="Deploy SovereignVault")
    parser.add_argument("--alm", action="store_true", help="Deploy SovereignALM (requires --pool-address)")
    parser.add_argument("--fee-module", action="store_true", help="Deploy BalanceSeekingSwapFeeModule (requires --pool-address)")
    
    # Network
    parser.add_argument("--mainnet", action="store_true", help="Deploy to mainnet (default: testnet)")
    
    # Addresses
    parser.add_argument("--usdc", type=str, help="USDC address override")
    parser.add_argument("--pool-address", type=str, help="Pool address (for ALM/fee-module deployment)")
    parser.add_argument("--vault-address", type=str, help="Existing vault address (for configuration)")
    
    # Post-deployment configuration
    parser.add_argument("--authorize-pool", type=str, help="Authorize a pool on the deployed/specified vault")
    parser.add_argument("--set-alm", type=str, help="Set ALM address on the specified pool")
    parser.add_argument("--set-fee-module", type=str, help="Set fee module address on the specified pool")
    
    # Options
    parser.add_argument("--skip-compile", action="store_true", help="Skip forge build step")
    parser.add_argument("--output", "-o", type=str, help="Output deployment info to JSON file")
    
    args = parser.parse_args()
    
    # Validate arguments
    if not any([args.vault, args.alm, args.fee_module, args.authorize_pool, args.set_alm, args.set_fee_module]):
        parser.error("At least one deployment or configuration action is required")
    
    if args.alm and not args.pool_address:
        parser.error("--pool-address is required for --alm")
    
    if args.fee_module and not args.pool_address:
        parser.error("--pool-address is required for --fee-module")
    
    if (args.authorize_pool or args.set_alm or args.set_fee_module) and not args.pool_address and not args.vault:
        # If we're doing config operations, we need either a deployed vault or pool address
        pass  # We'll handle this logic below
    
    # Compile contracts if needed
    if not args.skip_compile and (args.vault or args.alm or args.fee_module):
        compile_contracts()
    
    # Initialize deployer
    network = "mainnet" if args.mainnet else "testnet"
    deployer = ContractDeployer(network=network)
    
    deployments: Dict[str, Any] = {
        "network": network,
        "deployer": deployer.deployer_address,
        "contracts": {},
        "configurations": [],
    }
    
    try:
        vault_address = args.vault_address
        
        # Deploy SovereignVault
        if args.vault:
            result = deployer.deploy_sovereign_vault(usdc_address=args.usdc)
            deployments["contracts"]["SovereignVault"] = {
                "address": result.address,
                "tx_hash": result.tx_hash,
                "constructor_args": result.constructor_args,
                "gas_used": result.gas_used,
            }
            vault_address = result.address
        
        # Deploy SovereignALM
        if args.alm:
            result = deployer.deploy_sovereign_alm(args.pool_address)
            deployments["contracts"]["SovereignALM"] = {
                "address": result.address,
                "tx_hash": result.tx_hash,
                "constructor_args": result.constructor_args,
                "gas_used": result.gas_used,
            }
            
            # Optionally set ALM on pool
            if args.set_alm is None:  # Auto-set if not explicitly specified
                deployer.set_alm_on_pool(args.pool_address, result.address)
                deployments["configurations"].append({
                    "action": "setALM",
                    "pool": args.pool_address,
                    "alm": result.address,
                })
        
        # Deploy Fee Module
        if args.fee_module:
            result = deployer.deploy_swap_fee_module(args.pool_address)
            deployments["contracts"]["BalanceSeekingSwapFeeModule"] = {
                "address": result.address,
                "tx_hash": result.tx_hash,
                "constructor_args": result.constructor_args,
                "gas_used": result.gas_used,
            }
            
            # Optionally set fee module on pool
            if args.set_fee_module is None:  # Auto-set if not explicitly specified
                deployer.set_swap_fee_module_on_pool(args.pool_address, result.address)
                deployments["configurations"].append({
                    "action": "setSwapFeeModule",
                    "pool": args.pool_address,
                    "module": result.address,
                })
        
        # Configuration actions
        if args.authorize_pool:
            if not vault_address:
                parser.error("--vault-address is required for --authorize-pool (unless deploying vault)")
            deployer.authorize_pool_on_vault(vault_address, args.authorize_pool)
            deployments["configurations"].append({
                "action": "authorizePool",
                "vault": vault_address,
                "pool": args.authorize_pool,
            })
        
        if args.set_alm:
            if not args.pool_address:
                parser.error("--pool-address is required for --set-alm")
            deployer.set_alm_on_pool(args.pool_address, args.set_alm)
            deployments["configurations"].append({
                "action": "setALM",
                "pool": args.pool_address,
                "alm": args.set_alm,
            })
        
        if args.set_fee_module:
            if not args.pool_address:
                parser.error("--pool-address is required for --set-fee-module")
            deployer.set_swap_fee_module_on_pool(args.pool_address, args.set_fee_module)
            deployments["configurations"].append({
                "action": "setSwapFeeModule",
                "pool": args.pool_address,
                "module": args.set_fee_module,
            })
        
        # Print summary
        print(f"\n{'='*60}")
        print("DEPLOYMENT COMPLETE")
        print(f"{'='*60}")
        print(json.dumps(deployments, indent=2))
        
        # Save to file if requested
        if args.output:
            save_deployment(deployments, args.output)
        
        # Print next steps
        print(f"\n{'='*60}")
        print("NEXT STEPS")
        print(f"{'='*60}")
        
        if "SovereignVault" in deployments["contracts"]:
            vault_addr = deployments["contracts"]["SovereignVault"]["address"]
            print(f"1. Fund the vault with USDC:")
            print(f"   USDC.transfer({vault_addr}, amount)")
            print(f"\n2. Authorize your pool (if not already done):")
            print(f"   vault.setAuthorizedPool(poolAddress, true)")
            print(f"\n3. Allocate USDC to HLP for yield:")
            print(f"   vault.allocate(hlpVault, amount)")
        
        print(f"\n4. Update your .env file with the new addresses")
        print(f"\n5. For the backend server, set:")
        if "SovereignVault" in deployments["contracts"]:
            print(f"   SOVEREIGN_VAULT_ADDRESS={deployments['contracts']['SovereignVault']['address']}")
        
    except Exception as e:
        print(f"\n❌ Deployment failed: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    main()
