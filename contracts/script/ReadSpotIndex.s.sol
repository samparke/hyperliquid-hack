// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";

contract ReadSpotIndex is Script {
    function run() external view {
        address purr = vm.envAddress("TOKEN0");
        address usdc = vm.envAddress("TOKEN1");

        uint64 idxPurr = PrecompileLib.getSpotIndex(purr);
        uint64 idxUsdc = PrecompileLib.getSpotIndex(usdc);

        console2.log("PURR spotIndex:", idxPurr);
        console2.log("USDC spotIndex:", idxUsdc);
    }
}