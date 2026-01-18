// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

// --- Your contracts ---
import {SovereignVault} from "../src/SovereignVault.sol";
import {CapitalRouter} from "../src/CapitalRouter.sol";
import {OrderbookModule} from "../src/DeltaBook.sol";
import {SovereignPool} from "../src/SovereignPool.sol";
import {SovereignALM} from "../src/SovereignALM.sol";

// --- New oracle ---
import {HypercoreSpotOracleE18} from "../src/oracles/HypercoreSpotOracleE18.sol";
import {IRefPriceOracle} from "../src/oracles/interfaces/IRefPriceOracle.sol";

// --- Constructor args struct ---
import {SovereignPoolConstructorArgs} from "../src/structs/SovereignPoolStructs.sol";

contract DeployDeltaFlowTestnet is Script {
    // HyperEVM testnet token addresses you provided
    address constant PURR = 0xa9056c15938f9aff34CD497c722Ce33dB0C2fD57;
    address constant USDC = 0x2B3370eE501B4a559b57D449569354196457D8Ab;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // 1) Deploy SovereignVault (holds reserves, allocates USDC to HyperCore vault)
        SovereignVault vault = new SovereignVault(USDC);

        // 2) Deploy Strategy Price Oracle (reads Hyperliquid spot px precompile -> E18)
        HypercoreSpotOracleE18 priceOracle = new HypercoreSpotOracleE18(PURR);

        // 3) Deploy DeltaBook (OrderbookModule)
        // owner/strategist/guardian = deployer for testnet simplicity
        OrderbookModule deltaBook = new OrderbookModule( /*vault*/
            vault,
            /*token0*/
            PURR,
            /*token1*/
            USDC,
            /*owner*/
            deployer,
            /*strategist*/
            deployer,
            /*guardian*/
            deployer
        );

        // Wire oracle into DeltaBook
        deltaBook.setSources(IRefPriceOracle(address(priceOracle)));

        // Set market IDs (arbitrary bytes32 tags for executor routing)
        bytes32 spotMarketId = keccak256("PURR_SPOT");
        bytes32 perpMarketId = keccak256("PURR_PERP");
        deltaBook.setMarkets(spotMarketId, perpMarketId);

        // 4) Deploy CapitalRouter
        CapitalRouter router = new CapitalRouter( /*vault*/
            vault,
            /*token0*/
            PURR,
            /*token1*/
            USDC,
            /*owner*/
            deployer,
            /*strategist*/
            deployer,
            /*guardian*/
            deployer
        );

        // Wire router into vault
        vault.setCapitalRouter(address(router));

        // Router modules: you have lending already, but if not deployed yet, pass address(0)
        router.setModules(address(0), address(deltaBook));

        // Optional: set targets (example: 20% orderbook, 40% lending, 30% idle)
        // router.setTargets(2000, 4000, 3000);

        // 5) Deploy SovereignPool
        SovereignPoolConstructorArgs memory args;
        args.sovereignVault = address(vault);
        args.token0 = PURR;
        args.token1 = USDC;

        // Optional modules
        args.verifierModule = address(0);
        args.protocolFactory = deployer; // for testnet
        args.poolManager = deployer;

        // Rebase flags
        args.isToken0Rebase = false;
        args.isToken1Rebase = false;
        args.token0AbsErrorTolerance = 0;
        args.token1AbsErrorTolerance = 0;

        // default swap fee bips
        args.defaultSwapFeeBips = 30; // 0.30%

        SovereignPool pool = new SovereignPool(args);

        // Authorize pool in vault so pool can call sendTokensToRecipient
        vault.setAuthorizedPool(address(pool), true);

        // 6) Deploy ALM and set it on the pool
        SovereignALM alm = new SovereignALM(address(pool));
        pool.setALM(address(alm));

        vm.stopBroadcast();

        // Print addresses
        console2.log("DEPLOYER:", deployer);
        console2.log("SovereignVault:", address(vault));
        console2.log("PriceOracle:", address(priceOracle));
        console2.log("DeltaBook:", address(deltaBook));
        console2.log("CapitalRouter:", address(router));
        console2.log("SovereignPool:", address(pool));
        console2.log("SovereignALM:", address(alm));
        console2.logBytes32(spotMarketId);
        console2.logBytes32(perpMarketId);
    }
}
