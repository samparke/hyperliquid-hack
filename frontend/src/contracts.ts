// ═══════════════════════════════════════════════════════════════════════════
// Sovereign AMM Contract Configuration - Hyperliquid Testnet
// ═══════════════════════════════════════════════════════════════════════════

// Chain ID for Hyperliquid Testnet
export const HYPERLIQUID_TESTNET_CHAIN_ID = 998;

// ═══════════════════════════════════════════════════════════════════════════
// Contract Addresses
// ═══════════════════════════════════════════════════════════════════════════
export const ADDRESSES = {
  // Core Contracts - Hyperliquid Testnet
  POOL: "0x0000000000000000000000000000000000000000" as const, // TODO: Deploy pool
  VAULT: "0x6eE714F8B322c7074Bc827D57685A0502e9c97CB" as const, // SovereignVault
  ALM: "0x0000000000000000000000000000000000000000" as const, // TODO: Deploy ALM

  // Tokens
  USDC: "0x2B3370eE501B4a559b57D449569354196457D8Ab" as const, // Hyperliquid Testnet USDC
  PURR: "0xa9056c15938f9aff34CD497c722Ce33dB0C2fD57" as const, // PURR Token

  // HyperCore
  HLP_VAULT: "0xa15099a30BBf2e68942d6F4c43d70D04FAEab0A0" as const,
} as const;

// ═══════════════════════════════════════════════════════════════════════════
// Token Metadata
// ═══════════════════════════════════════════════════════════════════════════
export const TOKENS = {
  PURR: {
    address: ADDRESSES.PURR,
    symbol: "PURR",
    decimals: 5,
    name: "PURR",
  },
  USDC: {
    address: ADDRESSES.USDC,
    symbol: "USDC",
    decimals: 6,
    name: "USD Coin",
  },
} as const;

// ═══════════════════════════════════════════════════════════════════════════
// ABIs
// ═══════════════════════════════════════════════════════════════════════════

// Minimal ERC20 ABI for token interactions
export const ERC20_ABI = [
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "allowance",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "approve",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "symbol",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
  {
    name: "decimals",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
  {
    name: "name",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
  {
    name: "totalSupply",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "transfer",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

// SovereignPool ABI - Main swap/AMM contract
export const SOVEREIGN_POOL_ABI = [
  // View Functions - Token Info
  {
    name: "token0",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "token1",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "getTokens",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "tokens", type: "address[]" }],
  },
  // View Functions - Reserves & Fees
  {
    name: "getReserves",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "reserve0", type: "uint256" },
      { name: "reserve1", type: "uint256" },
    ],
  },
  {
    name: "getPoolManagerFees",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "fee0", type: "uint256" },
      { name: "fee1", type: "uint256" },
    ],
  },
  {
    name: "defaultSwapFeeBips",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "poolManagerFeeBips",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  // View Functions - Module Addresses
  {
    name: "sovereignVault",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "alm",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "poolManager",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "gauge",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "protocolFactory",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "swapFeeModule",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "sovereignOracleModule",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "verifierModule",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  // View Functions - State
  {
    name: "isLocked",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "isRebaseTokenPool",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "bool" }],
  },
  // Swap Function
  {
    name: "swap",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "_swapParams",
        type: "tuple",
        components: [
          { name: "isSwapCallback", type: "bool" },
          { name: "isZeroToOne", type: "bool" },
          { name: "amountIn", type: "uint256" },
          { name: "amountOutMin", type: "uint256" },
          { name: "deadline", type: "uint256" },
          { name: "recipient", type: "address" },
          { name: "swapTokenOut", type: "address" },
          {
            name: "swapContext",
            type: "tuple",
            components: [
              { name: "externalContext", type: "bytes" },
              { name: "verifierContext", type: "bytes" },
              { name: "swapFeeModuleContext", type: "bytes" },
              { name: "swapCallbackContext", type: "bytes" },
            ],
          },
        ],
      },
    ],
    outputs: [
      { name: "amountInUsed", type: "uint256" },
      { name: "amountOut", type: "uint256" },
    ],
  },
  // Liquidity Functions
  {
    name: "depositLiquidity",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "_amount0", type: "uint256" },
      { name: "_amount1", type: "uint256" },
      { name: "_sender", type: "address" },
      { name: "_verificationContext", type: "bytes" },
      { name: "_depositData", type: "bytes" },
    ],
    outputs: [
      { name: "amount0Deposited", type: "uint256" },
      { name: "amount1Deposited", type: "uint256" },
    ],
  },
  {
    name: "withdrawLiquidity",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "_amount0", type: "uint256" },
      { name: "_amount1", type: "uint256" },
      { name: "_sender", type: "address" },
      { name: "_recipient", type: "address" },
      { name: "_verificationContext", type: "bytes" },
    ],
    outputs: [],
  },
  // Events
  {
    name: "Swap",
    type: "event",
    inputs: [
      { name: "sender", type: "address", indexed: true },
      { name: "isZeroToOne", type: "bool", indexed: false },
      { name: "amountIn", type: "uint256", indexed: false },
      { name: "fee", type: "uint256", indexed: false },
      { name: "amountOut", type: "uint256", indexed: false },
    ],
  },
] as const;

// SovereignVault ABI - Liquidity container
export const SOVEREIGN_VAULT_ABI = [
  // View Functions
  {
    name: "strategist",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "usdc",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "defaultVault",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "authorizedPools",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "pool", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "getTokensForPool",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "_pool", type: "address" }],
    outputs: [{ name: "", type: "address[]" }],
  },
  {
    name: "getReservesForPool",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "_pool", type: "address" },
      { name: "_tokens", type: "address[]" },
    ],
    outputs: [{ name: "", type: "uint256[]" }],
  },
  {
    name: "getTotalAllocatedUSDC",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "getUSDCBalance",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  // Write Functions
  {
    name: "allocate",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "vault", type: "address" },
      { name: "usdcAmount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    name: "deallocate",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "vault", type: "address" },
      { name: "usdcAmount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    name: "setAuthorizedPool",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "_pool", type: "address" },
      { name: "_authorized", type: "bool" },
    ],
    outputs: [],
  },
  {
    name: "changeDefaultVault",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "newVault", type: "address" }],
    outputs: [],
  },
] as const;

// SovereignALM ABI - Spot price oracle
export const SOVEREIGN_ALM_ABI = [
  {
    name: "pool",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "token0",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "getSpotPrice",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "spotPrice", type: "uint64" }],
  },
  {
    name: "getToken0Info",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "spotIndex", type: "uint32" },
          { name: "szDecimals", type: "uint8" },
          { name: "tokenAddress", type: "address" },
        ],
      },
    ],
  },
  {
    name: "getLiquidityQuote",
    type: "function",
    stateMutability: "view",
    inputs: [
      {
        name: "_almLiquidityQuoteInput",
        type: "tuple",
        components: [
          { name: "isZeroToOne", type: "bool" },
          { name: "amountInMinusFee", type: "uint256" },
          { name: "feeInBips", type: "uint256" },
          { name: "sender", type: "address" },
          { name: "recipient", type: "address" },
          { name: "tokenOutSwap", type: "address" },
        ],
      },
      { name: "_externalContext", type: "bytes" },
      { name: "_verifierData", type: "bytes" },
    ],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "isCallbackOnSwap", type: "bool" },
          { name: "amountOut", type: "uint256" },
          { name: "amountInFilled", type: "uint256" },
        ],
      },
    ],
  },
] as const;

// ═══════════════════════════════════════════════════════════════════════════
// Type Exports
// ═══════════════════════════════════════════════════════════════════════════
export type TokenKey = keyof typeof TOKENS;
export type Token = (typeof TOKENS)[TokenKey];
