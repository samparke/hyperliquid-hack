"use client";

import { useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { parseUnits } from "viem";
import { CONTRACTS, POOL_ABI, ERC20_ABI } from "../lib/contracts";

export interface SwapParams {
  isZeroToOne: boolean; // true = PURR->USDC, false = USDC->PURR
  amountIn: string;
  amountOutMin: string;
  recipient: `0x${string}`;
}

// Hook for approving tokens
export function useApprove() {
  const {
    writeContract,
    data: hash,
    isPending,
    error,
    reset,
  } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash,
  });

  const approve = async (
    tokenAddress: `0x${string}`,
    spender: `0x${string}`,
    amount: bigint
  ) => {
    writeContract({
      address: tokenAddress,
      abi: ERC20_ABI,
      functionName: "approve",
      args: [spender, amount],
    });
  };

  return {
    approve,
    hash,
    isPending,
    isConfirming,
    isSuccess,
    error,
    reset,
  };
}

// Hook for executing swaps
export function useSwap() {
  const {
    writeContract,
    data: hash,
    isPending,
    error,
    reset,
  } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash,
  });

  const swap = async (params: SwapParams) => {
    const { isZeroToOne, amountIn, amountOutMin, recipient } = params;

    // Parse amounts based on direction
    const tokenInDecimals = isZeroToOne ? 5 : 6; // PURR=5, USDC=6
    const tokenOutDecimals = isZeroToOne ? 6 : 5;
    const tokenOut = isZeroToOne ? CONTRACTS.USDC : CONTRACTS.PURR;

    const amountInParsed = parseUnits(amountIn, tokenInDecimals);
    const amountOutMinParsed = parseUnits(amountOutMin || "0", tokenOutDecimals);

    // Deadline: 20 minutes from now
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 1200);

    const swapParams = {
      isSwapCallback: false,
      isZeroToOne,
      amountIn: amountInParsed,
      amountOutMin: amountOutMinParsed,
      deadline,
      recipient,
      swapTokenOut: tokenOut,
      swapContext: {
        externalContext: "0x" as `0x${string}`,
        verifierContext: "0x" as `0x${string}`,
        swapCallbackContext: "0x" as `0x${string}`,
        swapFeeModuleContext: "0x" as `0x${string}`,
      },
    };

    writeContract({
      address: CONTRACTS.POOL,
      abi: POOL_ABI,
      functionName: "swap",
      args: [swapParams],
    });
  };

  return {
    swap,
    hash,
    isPending,
    isConfirming,
    isSuccess,
    error,
    reset,
  };
}

// Calculate expected output amount
export function calculateExpectedOutput(
  amountIn: string,
  spotPrice: number,
  isZeroToOne: boolean,
  feeBips: number = 30
): string {
  if (!amountIn || isNaN(Number(amountIn)) || Number(amountIn) <= 0) {
    return "0";
  }

  const amount = Number(amountIn);
  const feeMultiplier = 1 - feeBips / 10000;

  if (isZeroToOne) {
    // PURR -> USDC
    // amountOut = amountIn * price * (1 - fee)
    const output = amount * spotPrice * feeMultiplier;
    return output.toFixed(6);
  } else {
    // USDC -> PURR
    // amountOut = amountIn / price * (1 - fee)
    const output = (amount / spotPrice) * feeMultiplier;
    return output.toFixed(5);
  }
}
