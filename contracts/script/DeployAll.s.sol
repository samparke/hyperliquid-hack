// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {SovereignPool} from "../src/SovereignPool.sol";
import {SovereignALM} from "../src/SovereignALM.sol";
import {SovereignVault} from "../src/SovereignVault.sol";
import {BalanceSeekingSwapFeeModule} from "../src/SwapFeeModule.sol";
import {SovereignPoolConstructorArgs} from "../src/structs/SovereignPoolStructs.sol";

interface ISovereignVaultAuthorizer {
    function setAuthorizedPool(address pool, bool ok) external;
}

// NOTE: add this function to SovereignVault.sol:
// function approveAgent(address agent, string calldata name) external onlyStrategist { CoreWriterLib.approveAgent(agent, name); }
interface ISovereignVaultAgentApprover {
    function approveAgent(address agent, string calldata name) external;
}

contract DeployAll is Script {
    struct Params {
        uint256 pk;
        address deployer;

        // agent wallet that signs HL orders (private key lives in .env for your python server)
        uint256 hlAgentPk;
        address hlAgentAddr;
        string hlAgentName;

        address purr;
        address usdc;

        // always deploy a NEW vault (ignore env)
        address protocolFactory;
        address verifierModule;

        address poolManager;

        uint256 defaultSwapFeeBips;

        // fee module specifics
        uint64 spotIndexPURR;
        bool invertPurrPx;

        uint256 baseFeeBips;
        uint256 minFeeBips;
        uint256 maxFeeBips;
        uint256 deadzoneImbalanceBips;
        uint256 penaltySlopeBipsPerPct;
        uint256 discountSlopeBipsPerPct;
    }

    function run() external {
        Params memory p = _load();

        console2.log("ChainId:", block.chainid);
        console2.log("Deployer:", p.deployer);
        console2.log("PoolManager:", p.poolManager);
        console2.log("PURR:", p.purr);
        console2.log("USDC:", p.usdc);
        console2.log("HL Agent:", p.hlAgentAddr);

        vm.startBroadcast(p.pk);

        // 0) ALWAYS deploy a fresh vault
        SovereignVault vault = new SovereignVault(p.usdc);
        console2.log("Deployed SovereignVault:", address(vault));

        // 0.1) Approve HL agent wallet to trade the VAULT's Core balances
        //      Requires SovereignVault.approveAgent(...) to be implemented (see note above).
        ISovereignVaultAgentApprover(address(vault)).approveAgent(p.hlAgentAddr, p.hlAgentName);
        console2.log("Vault approved HL agent:", p.hlAgentAddr);

        // 1) Deploy pool in external-vault mode
        SovereignPool pool = _deployPool(p, address(vault));
        console2.log("Deployed SovereignPool:", address(pool));

        // 2) Authorize pool on vault ASAP
        vault.setAuthorizedPool(address(pool), true);
        console2.log("Vault authorized pool");

        // 3) Deploy modules
        SovereignALM alm = new SovereignALM(address(pool));
        console2.log("Deployed SovereignALM:", address(alm));

        BalanceSeekingSwapFeeModule feeModule = _deployFeeModule(p, pool);
        console2.log("Deployed SwapFeeModule:", address(feeModule));

        // 4) Wire pool -> modules
        pool.setALM(address(alm));
        pool.setSwapFeeModule(address(feeModule));

        vm.stopBroadcast();

        console2.log("=== FINAL ADDRS ===");
        console2.log("SOVEREIGN_VAULT_ADDRESS=", address(vault));
        console2.log("WATCH_POOL=", address(pool));
        console2.log("SOVEREIGN_ALM=", address(alm));
        console2.log("SWAP_FEE_MODULE=", address(feeModule));
        console2.log("HL_ACCOUNT_ADDRESS (vault) =", address(vault));
        console2.log("HL_AGENT_ADDRESS =", p.hlAgentAddr);
    }

    function _load() internal view returns (Params memory p) {
        // EVM deployer
        p.pk = vm.envUint("PRIVATE_KEY");
        p.deployer = vm.addr(p.pk);

        // HL agent wallet private key (the one your python server will use as HL_SECRET_KEY)
        // Put this in .env as HL_AGENT_PRIVATE_KEY
        p.hlAgentPk = vm.envUint("HL_AGENT_PRIVATE_KEY");
        p.hlAgentAddr = vm.addr(p.hlAgentPk);
        p.hlAgentName = vm.envOr("HL_AGENT_NAME", string("hedge-bot"));

        // tokens
        p.purr = vm.envAddress("PURR");
        p.usdc = vm.envAddress("USDC");

        // optional / can be 0
        p.protocolFactory = vm.envAddress("PROTOCOL_FACTORY");
        p.verifierModule = vm.envAddress("VERIFIER_MODULE");

        // pool config
        p.poolManager = vm.envAddress("POOL_MANAGER");
        p.defaultSwapFeeBips = vm.envUint("DEFAULT_SWAP_FEE_BIPS");

        // fee module config
        p.spotIndexPURR = uint64(vm.envUint("SPOT_INDEX_PURR"));
        p.invertPurrPx = vm.envBool("INVERT_PURR_PX");

        p.baseFeeBips = vm.envUint("BASE_FEE_BIPS");
        p.minFeeBips = vm.envUint("MIN_FEE_BIPS");
        p.maxFeeBips = vm.envUint("MAX_FEE_BIPS");
        p.deadzoneImbalanceBips = vm.envUint("DEADZONE_IMBALANCE_BIPS");
        p.penaltySlopeBipsPerPct = vm.envUint("PENALTY_SLOPE_BIPS_PER_PCT");
        p.discountSlopeBipsPerPct = vm.envUint("DISCOUNT_SLOPE_BIPS_PER_PCT");

        require(p.purr != address(0) && p.usdc != address(0), "TOKENS_0");
        require(p.poolManager != address(0), "PM_0");
        require(p.defaultSwapFeeBips <= 10_000, "SWAP_FEE_TOO_HIGH");
        require(p.minFeeBips <= p.maxFeeBips, "MIN_GT_MAX");
        require(p.hlAgentAddr != address(0), "HL_AGENT_0");
    }

    function _deployPool(Params memory p, address vaultAddr) internal returns (SovereignPool pool) {
        SovereignPoolConstructorArgs memory args = SovereignPoolConstructorArgs({
            token0: p.purr,
            token1: p.usdc,
            sovereignVault: vaultAddr,
            protocolFactory: p.protocolFactory, // can be 0
            poolManager: p.poolManager,
            verifierModule: p.verifierModule,   // can be 0
            defaultSwapFeeBips: p.defaultSwapFeeBips,
            isToken0Rebase: false,
            isToken1Rebase: false,
            token0AbsErrorTolerance: 0,
            token1AbsErrorTolerance: 0
        });

        pool = new SovereignPool(args);
    }

    function _deployFeeModule(Params memory p, SovereignPool pool)
        internal
        returns (BalanceSeekingSwapFeeModule feeModule)
    {
        feeModule = new BalanceSeekingSwapFeeModule(
            address(pool),
            p.usdc,
            p.purr,
            p.spotIndexPURR,
            p.invertPurrPx,
            p.baseFeeBips,
            p.minFeeBips,
            p.maxFeeBips,
            p.deadzoneImbalanceBips,
            p.penaltySlopeBipsPerPct,
            p.discountSlopeBipsPerPct
        );
    }
}