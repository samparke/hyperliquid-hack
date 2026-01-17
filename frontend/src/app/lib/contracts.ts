// Contract addresses - UPDATE THESE after deployment
export const CONTRACTS = {
  // Hyperliquid Testnet addresses
  POOL: "0x0000000000000000000000000000000000000000" as `0x${string}`, // TODO: Deploy and update
  ALM: "0x0000000000000000000000000000000000000000" as `0x${string}`, // TODO: Deploy and update
  PURR: "0xa9056c15938f9aff34CD497c722Ce33dB0C2fD57" as `0x${string}`,
  USDC: "0x0000000000000000000000000000000000000000" as `0x${string}`, // TODO: Update with testnet USDC
} as const;

// Token metadata
export const TOKENS = {
  PURR: {
    address: CONTRACTS.PURR,
    symbol: "PURR",
    name: "PURR",
    decimals: 5, // weiDecimals on testnet
    logo: "/purr.png",
  },
  USDC: {
    address: CONTRACTS.USDC,
    symbol: "USDC",
    name: "USD Coin",
    decimals: 6,
    logo: "/usdc.png",
  },
} as const;

// Minimal ERC20 ABI for token operations
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
] as const;

// SovereignALM ABI (only what we need)
export const ALM_ABI = [
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
        name: "info",
        type: "tuple",
        components: [
          { name: "name", type: "string" },
          { name: "spots", type: "uint64[]" },
          { name: "deployerTradingFeeShare", type: "uint64" },
          { name: "deployer", type: "address" },
          { name: "evmContract", type: "address" },
          { name: "szDecimals", type: "uint8" },
          { name: "weiDecimals", type: "uint8" },
          { name: "evmExtraWeiDecimals", type: "int8" },
        ],
      },
    ],
  },
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
] as const;

// SovereignPool ABI (only what we need for swaps)
export const POOL_ABI = [
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
              { name: "swapCallbackContext", type: "bytes" },
              { name: "swapFeeModuleContext", type: "bytes" },
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
    name: "alm",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "defaultSwapFeeBips",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;
