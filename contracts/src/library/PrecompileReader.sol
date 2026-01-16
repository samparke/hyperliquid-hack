// lib/PrecompileReader.sol
library PrecompileReader {
    address constant POSITION_PRECOMPILE = 0x0000000000000000000000000000000000000800;
    address constant SPOT_BALANCE_PRECOMPILE = 0x0000000000000000000000000000000000000801;
    address constant SPOT_PX_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000808;

    function getSpotPrice(uint32 index) external view returns (uint64) {
        bool success;
        bytes memory result;
        (success, result) = SPOT_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(index));
        require(success, "Spot price precompile call failed");
        return abi.decode(result, (uint64));
    }
}
