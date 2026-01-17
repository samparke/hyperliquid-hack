"use client";

import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { defineChain } from "viem";

// Hyperliquid Testnet (HyperEVM)
const hyperliquidTestnet = defineChain({
  id: 998,
  name: "Hyperliquid Testnet",
  nativeCurrency: {
    name: "HYPE",
    symbol: "HYPE",
    decimals: 18,
  },
  rpcUrls: {
    default: {
      http: ["https://rpc.hyperliquid-testnet.xyz/evm"],
    },
  },
  blockExplorers: {
    default: {
      name: "Hyperliquid Explorer",
      url: "https://explorer.hyperliquid-testnet.xyz",
    },
  },
  testnet: true,
});

export default getDefaultConfig({
  appName: "Sovereign AMM",
  projectId: process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID!,
  chains: [hyperliquidTestnet],
  ssr: false,
});
