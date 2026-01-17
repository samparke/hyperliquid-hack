// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol"; 
import {ISovereignVault} from "./interfaces/Interfaces.sol";
import {IRefPriceOracle} from "./oracles/interfaces/IRefPriceOracle.sol";

contract OrderbookModule {
    // --- Roles ---
    address public owner;
    address public strategist;
    address public guardian;
    bool    public paused;

    // --- External components ---
    ISovereignVault  public immutable vault;
    IRefPriceOracle public priceOracle;

    address public immutable token0;
    address public immutable token1;

    // --- Strategy params ---
    // Maker quotes around ref price:
    // bid = P * (1 - bidOffsetBps/1e4)
    // ask = P * (1 + askOffsetBps/1e4)
    uint16 public bidOffsetBps;   // e.g., 6 = 6 bps
    uint16 public askOffsetBps;   // e.g., 6 = 6 bps
    uint16 public maxSpreadBps;   // safety cap against crazy quoting

    // Order sizes (in token0 units for spot maker)
    uint256 public makerSizeToken0;     // size per side
    uint256 public maxMakerNotionalE18; // cap in token1 per order, 1e18

    // Hedging
    int256  public hedgeDeltaThresholdToken0; // when abs(netDelta) exceeds this, hedge
    uint16  public hedgePctBps;               // hedge only a portion, e.g. 7000=70%
    uint256 public maxHedgeNotionalE18;        // cap per hedge action

    // Markets identifiers for executor (opaque to contract)
    // Your off-chain executor maps these to Hyperliquid assetIndex / perpIndex.
    bytes32 public spotMarketId;
    bytes32 public perpMarketId;

    uint16 public constant MAX_BPS = 10_000;

    // --- Events consumed by off-chain Executor (API wallet) ---
    event SpotMakerIntent(
        bytes32 indexed intentId,
        bytes32 indexed marketId,
        uint256 refPriceE18,
        uint256 bidPriceE18,
        uint256 askPriceE18,
        uint256 sizeToken0,
        uint64  ttlSeconds
    );

    event PerpHedgeIntent(
        bytes32 indexed intentId,
        bytes32 indexed marketId,
        bool isBuy,                 // true=buy perp, false=sell perp
        uint256 refPriceE18,
        uint256 hedgeNotionalE18,   // notional in token1 terms, 1e18
        bool reduceOnly,
        uint64 ttlSeconds
    );

    event CancelAllIntent(bytes32 indexed intentId, bytes32 indexed marketId, bytes32 reason);

    event Paused(bool isPaused);
    event RolesUpdated(address owner, address strategist, address guardian);
    event ParamsUpdated(
        uint16 bidOffsetBps,
        uint16 askOffsetBps,
        uint16 maxSpreadBps,
        uint256 makerSizeToken0,
        uint256 maxMakerNotionalE18,
        int256 hedgeDeltaThresholdToken0,
        uint16 hedgePctBps,
        uint256 maxHedgeNotionalE18
    );
    event SourcesUpdated(address vault, address priceOracle);
    event MarketsUpdated(bytes32 spotMarketId, bytes32 perpMarketId);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }
    modifier onlyStrategist() {
        require(msg.sender == strategist || msg.sender == owner, "NOT_STRATEGIST");
        _;
    }
    modifier onlyGuardian() {
        require(msg.sender == guardian || msg.sender == owner, "NOT_GUARDIAN");
        _;
    }
    modifier notPaused() {
        require(!paused, "PAUSED");
        _;
    }

    constructor(
        ISovereignVault _vault,
        address _token0,
        address _token1,
        address _owner,
        address _strategist,
        address _guardian
    ) {
        require(address(_vault) != address(0), "VAULT_0");
        require(_token0 != address(0) && _token1 != address(0), "TOKEN_0");
        vault = _vault;
        token0 = _token0;
        token1 = _token1;

        owner = _owner;
        strategist = _strategist;
        guardian = _guardian;

        // defaults
        bidOffsetBps = 6;
        askOffsetBps = 6;
        maxSpreadBps = 50;

        makerSizeToken0 = 1e18; // adjust to token0 decimals in real impl
        maxMakerNotionalE18 = 50_000e18;

        hedgeDeltaThresholdToken0 = int256(5e18); // 5 token0 units (scale appropriately)
        hedgePctBps = 7000; // 70%
        maxHedgeNotionalE18 = 100_000e18;

        emit RolesUpdated(owner, strategist, guardian);
        emit ParamsUpdated(
            bidOffsetBps, askOffsetBps, maxSpreadBps,
            makerSizeToken0, maxMakerNotionalE18,
            hedgeDeltaThresholdToken0, hedgePctBps, maxHedgeNotionalE18
        );
    }

    // --- Admin wiring ---
    function setRoles(address _owner, address _strategist, address _guardian) external onlyOwner {
        require(_owner != address(0) && _strategist != address(0) && _guardian != address(0), "ROLE_0");
        owner = _owner;
        strategist = _strategist;
        guardian = _guardian;
        emit RolesUpdated(owner, strategist, guardian);
    }

    function setSources(IRefPriceOracle _priceOracle) external onlyOwner {
        priceOracle = _priceOracle;
        emit SourcesUpdated(address(vault), address(_priceOracle));
    }

    function setMarkets(bytes32 _spotMarketId, bytes32 _perpMarketId) external onlyOwner {
        spotMarketId = _spotMarketId;
        perpMarketId = _perpMarketId;
        emit MarketsUpdated(_spotMarketId, _perpMarketId);
    }

    function setParams(
        uint16 _bidOffsetBps,
        uint16 _askOffsetBps,
        uint16 _maxSpreadBps,
        uint256 _makerSizeToken0,
        uint256 _maxMakerNotionalE18,
        int256  _hedgeDeltaThresholdToken0,
        uint16  _hedgePctBps,
        uint256 _maxHedgeNotionalE18
    ) external onlyStrategist {
        require(_bidOffsetBps + _askOffsetBps <= _maxSpreadBps * 2, "OFFSET_TOO_WIDE");
        require(_maxSpreadBps <= 500, "SPREAD_CAP"); // 5%
        require(_hedgePctBps <= MAX_BPS, "HEDGE_PCT");
        bidOffsetBps = _bidOffsetBps;
        askOffsetBps = _askOffsetBps;
        maxSpreadBps = _maxSpreadBps;
        makerSizeToken0 = _makerSizeToken0;
        maxMakerNotionalE18 = _maxMakerNotionalE18;
        hedgeDeltaThresholdToken0 = _hedgeDeltaThresholdToken0;
        hedgePctBps = _hedgePctBps;
        maxHedgeNotionalE18 = _maxHedgeNotionalE18;

        emit ParamsUpdated(
            bidOffsetBps, askOffsetBps, maxSpreadBps,
            makerSizeToken0, maxMakerNotionalE18,
            hedgeDeltaThresholdToken0, hedgePctBps, maxHedgeNotionalE18
        );
    }

    function pause() external onlyGuardian {
        paused = true;
        emit Paused(true);
        _emitCancelAll("PAUSE");
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Paused(false);
    }

    // --- Intent emission entrypoints ---
    /// @notice Called by keeper/strategist on cadence, or by pool after large swaps.
    function emitMakerAndHedgeIntents(uint64 ttlSeconds) external notPaused onlyStrategist {
        require(address(priceOracle) != address(0), "ORACLE_0");
        uint256 p = priceOracle.refPriceE18();

        // sanity: offsets not insane
        require(bidOffsetBps <= maxSpreadBps && askOffsetBps <= maxSpreadBps, "OFFSET_CAP");

        uint256 bidP = (p * (MAX_BPS - bidOffsetBps)) / MAX_BPS;
        uint256 askP = (p * (MAX_BPS + askOffsetBps)) / MAX_BPS;

        // cap maker order by notional
        uint256 notionalE18 = (makerSizeToken0 * p) / 1e18;
        uint256 size = makerSizeToken0;
        if (notionalE18 > maxMakerNotionalE18) {
            // scale size down
            size = (makerSizeToken0 * maxMakerNotionalE18) / notionalE18;
        }

        bytes32 makerIntentId = keccak256(abi.encodePacked("MAKER", block.number, p, size));
        emit SpotMakerIntent(makerIntentId, spotMarketId, p, bidP, askP, size, ttlSeconds);

        // Hedge if needed
        int256 d = _netDeltaToken0(p);
        if (_abs(d) > _abs(hedgeDeltaThresholdToken0)) {
            _emitHedgeIntent(p, d, ttlSeconds);
        }
    }

    // --- internal hedge intent ---
    function _emitHedgeIntent(uint256 p, int256 netDeltaToken0, uint64 ttlSeconds) internal {
        // positive delta means long token0 -> hedge by selling perp (isBuy=false)
        bool isBuy = netDeltaToken0 < 0;

        // hedge amount in token0 = abs(delta) * hedgePct
        uint256 amtToken0 = (uint256(_abs(netDeltaToken0)) * hedgePctBps) / MAX_BPS;

        // convert to notional token1: amtToken0 * price
        uint256 notionalE18 = (amtToken0 * p) / 1e18;
        if (notionalE18 > maxHedgeNotionalE18) notionalE18 = maxHedgeNotionalE18;

        bytes32 hedgeIntentId = keccak256(abi.encodePacked("HEDGE", block.number, p, netDeltaToken0, notionalE18));
        emit PerpHedgeIntent(
            hedgeIntentId,
            perpMarketId,
            isBuy,
            p,
            notionalE18,
            true, // reduceOnly in PoC
            ttlSeconds
        );
    }

    function _emitCancelAll(bytes32 reason) internal {
        bytes32 intentId = keccak256(abi.encodePacked("CANCEL_ALL", block.number, reason));
        emit CancelAllIntent(intentId, spotMarketId, reason);
        emit CancelAllIntent(intentId, perpMarketId, reason);
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    function _netDeltaToken0(uint256 priceE18) internal view returns (int256) {
        // token0 held on EVM side
        uint256 r0 = IERC20(token0).balanceOf(address(vault));

        // token1 is USDC in your pool; vault holds some + allocated to HyperCore
        uint256 u = IERC20(token1).balanceOf(address(vault)) + vault.totalAllocatedUsd();

        // implied token0 value for neutral book (equal value on both sides)
        uint256 impliedToken0 = (u * 1e18) / priceE18;

        if (r0 >= impliedToken0) return int256(r0 - impliedToken0);
        return -int256(impliedToken0 - r0);
    }
}