// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {SovereignPool} from "../../contracts/src/SovereignPool.sol";
import {SovereignALM} from "../../contracts/src/SovereignALM.sol";
import {BalanceSeekingSwapFeeModule} from "../../contracts/src/SwapFeeModule.sol";
import {SovereignPoolConstructorArgs} from "../../contracts/src/structs/SovereignPoolStructs.sol";

interface ISovereignVaultAuthorizer {
    function setAuthorizedPool(address pool, bool ok) external;
}

contract DeployAll is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address purr = vm.envAddress("PURR");
        address usdc = vm.envAddress("USDC");

        // If you want pool custody, set SOVEREIGN_VAULT to 0x000... in .env
        address sovereignVault = vm.envAddress("SOVEREIGN_VAULT");

        // If you don’t use these yet, you can set them to deployer / zero in .env
        address protocolFactory = vm.envAddress("PROTOCOL_FACTORY");
        address verifierModule  = vm.envAddress("VERIFIER_MODULE");

        uint256 defaultSwapFeeBips = vm.envUint("DEFAULT_SWAP_FEE_BIPS");

        // Fee module params (PURR-specific)
        uint64  spotIndexPURR = uint64(vm.envUint("SPOT_INDEX_PURR"));
        bool    invertPurrPx  = vm.envBool("INVERT_PURR_PX");

        uint256 baseFeeBips = vm.envUint("BASE_FEE_BIPS");
        uint256 minFeeBips = vm.envUint("MIN_FEE_BIPS");
        uint256 maxFeeBips = vm.envUint("MAX_FEE_BIPS");
        uint256 deadzoneImbalanceBips = vm.envUint("DEADZONE_IMBALANCE_BIPS");
        uint256 penaltySlopeBipsPerPct = vm.envUint("PENALTY_SLOPE_BIPS_PER_PCT");
        uint256 discountSlopeBipsPerPct = vm.envUint("DISCOUNT_SLOPE_BIPS_PER_PCT");

        // IMPORTANT:
        // poolManager must be the caller of setALM and setSwapFeeModule.
        // Use deployer for deployment, then change later if needed.
        address poolManager = deployer;

        SovereignPoolConstructorArgs memory args = SovereignPoolConstructorArgs({
            token0: purr,
            token1: usdc,
            sovereignVault: sovereignVault,
            protocolFactory: protocolFactory,
            poolManager: poolManager,
            verifierModule: verifierModule,
            defaultSwapFeeBips: defaultSwapFeeBips,
            isToken0Rebase: false,
            isToken1Rebase: false,
            token0AbsErrorTolerance: 0,
            token1AbsErrorTolerance: 0
        });

        vm.startBroadcast(pk);

        // 1) Deploy pool
        SovereignPool pool = new SovereignPool(args);
        console2.log("SovereignPool:", address(pool));

        // 2) Deploy ALM (adjust if your constructor differs)
        SovereignALM alm = new SovereignALM(address(pool));
        console2.log("SovereignALM:", address(alm));

        // 3) Deploy fee module (11 args)
        BalanceSeekingSwapFeeModule feeModule = new BalanceSeekingSwapFeeModule(
            address(pool),
            usdc,
            purr,
            spotIndexPURR,
            invertPurrPx,
            baseFeeBips,
            minFeeBips,
            maxFeeBips,
            deadzoneImbalanceBips,
            penaltySlopeBipsPerPct,
            discountSlopeBipsPerPct
        );
        console2.log("SwapFeeModule:", address(feeModule));

        // 4) Wire pool modules (must be poolManager = deployer)
        pool.setALM(address(alm));
        pool.setSwapFeeModule(address(feeModule));

        // 5) Authorize pool in vault if vault != pool custody
        if (sovereignVault != address(0) && sovereignVault != address(pool)) {
            ISovereignVaultAuthorizer(sovereignVault).setAuthorizedPool(address(pool), true);
            console2.log("Vault authorized pool");
        }

        vm.stopBroadcast();

        console2.log("DEPLOYER:", deployer);
    }
}