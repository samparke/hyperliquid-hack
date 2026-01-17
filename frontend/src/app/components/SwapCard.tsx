"use client";

import { useState, useEffect } from "react";
import { useAccount } from "wagmi";
import { parseUnits } from "viem";
import { useSpotPrice, useTokenBalances, useTokenAllowance } from "../hooks/usePoolInfo";
import { useSwap, useApprove, calculateExpectedOutput } from "../hooks/useSwap";
import { CONTRACTS, TOKENS } from "../lib/contracts";

export function SwapCard() {
  const { address, isConnected } = useAccount();
  const [isZeroToOne, setIsZeroToOne] = useState(true); // PURR->USDC by default
  const [amountIn, setAmountIn] = useState("");
  const [slippage, setSlippage] = useState("0.5"); // 0.5% default slippage

  // Get spot price
  const { formattedPrice, rawPrice, isLoading: priceLoading, refetch: refetchPrice } = useSpotPrice();

  // Get balances
  const { formattedPurr, formattedUsdc, refetch: refetchBalances } = useTokenBalances(address);

  // Get allowance for the input token
  const inputToken = isZeroToOne ? CONTRACTS.PURR : CONTRACTS.USDC;
  const { allowance, refetch: refetchAllowance } = useTokenAllowance(
    inputToken,
    address,
    CONTRACTS.POOL
  );

  // Swap and approve hooks
  const {
    swap,
    isPending: swapPending,
    isConfirming: swapConfirming,
    isSuccess: swapSuccess,
    error: swapError,
    reset: resetSwap,
  } = useSwap();

  const {
    approve,
    isPending: approvePending,
    isConfirming: approveConfirming,
    isSuccess: approveSuccess,
    error: approveError,
    reset: resetApprove,
  } = useApprove();

  // Calculate expected output
  const expectedOutput = calculateExpectedOutput(amountIn, formattedPrice, isZeroToOne);

  // Calculate minimum output with slippage
  const minOutput = expectedOutput
    ? (Number(expectedOutput) * (1 - Number(slippage) / 100)).toFixed(isZeroToOne ? 6 : 5)
    : "0";

  // Check if approval is needed
  const inputDecimals = isZeroToOne ? 5 : 6;
  const amountInBigInt = amountIn ? parseUnits(amountIn, inputDecimals) : BigInt(0);
  const needsApproval = allowance !== undefined && amountInBigInt > allowance;

  // Refresh data after successful swap
  useEffect(() => {
    if (swapSuccess) {
      refetchBalances();
      refetchPrice();
      setAmountIn("");
      setTimeout(() => resetSwap(), 3000);
    }
  }, [swapSuccess]);

  // Refresh allowance after approval
  useEffect(() => {
    if (approveSuccess) {
      refetchAllowance();
      setTimeout(() => resetApprove(), 2000);
    }
  }, [approveSuccess]);

  const handleSwap = async () => {
    if (!address || !amountIn) return;

    await swap({
      isZeroToOne,
      amountIn,
      amountOutMin: minOutput,
      recipient: address,
    });
  };

  const handleApprove = async () => {
    if (!address) return;
    // Approve max uint256 for convenience
    await approve(inputToken, CONTRACTS.POOL, BigInt(2) ** BigInt(256) - BigInt(1));
  };

  const switchDirection = () => {
    setIsZeroToOne(!isZeroToOne);
    setAmountIn("");
  };

  const inputTokenInfo = isZeroToOne ? TOKENS.PURR : TOKENS.USDC;
  const outputTokenInfo = isZeroToOne ? TOKENS.USDC : TOKENS.PURR;
  const inputBalance = isZeroToOne ? formattedPurr : formattedUsdc;
  const outputBalance = isZeroToOne ? formattedUsdc : formattedPurr;

  const isLoading = swapPending || swapConfirming || approvePending || approveConfirming;

  return (
    <div className="bg-gray-900 rounded-2xl p-6 w-full max-w-md mx-auto shadow-xl border border-gray-800">
      <div className="flex justify-between items-center mb-6">
        <h2 className="text-xl font-bold text-white">Swap</h2>
        <button
          onClick={() => refetchPrice()}
          className="text-gray-400 hover:text-white transition-colors"
          title="Refresh price"
        >
          <RefreshIcon />
        </button>
      </div>

      {/* Price Display */}
      <div className="bg-gray-800 rounded-lg p-3 mb-4">
        <div className="text-sm text-gray-400">Hyperliquid Spot Price</div>
        <div className="text-lg font-semibold text-green-400">
          {priceLoading ? "Loading..." : `1 PURR = $${formattedPrice.toFixed(4)}`}
        </div>
      </div>

      {/* Input Token */}
      <div className="bg-gray-800 rounded-xl p-4 mb-2">
        <div className="flex justify-between text-sm text-gray-400 mb-2">
          <span>You pay</span>
          <span>Balance: {inputBalance}</span>
        </div>
        <div className="flex items-center gap-3">
          <input
            type="number"
            value={amountIn}
            onChange={(e) => setAmountIn(e.target.value)}
            placeholder="0.0"
            className="bg-transparent text-2xl text-white outline-none flex-1 w-full"
          />
          <button
            onClick={() => setAmountIn(inputBalance)}
            className="text-xs text-blue-400 hover:text-blue-300"
          >
            MAX
          </button>
          <div className="flex items-center gap-2 bg-gray-700 rounded-lg px-3 py-2">
            <span className="text-white font-medium">{inputTokenInfo.symbol}</span>
          </div>
        </div>
      </div>

      {/* Switch Button */}
      <div className="flex justify-center -my-2 relative z-10">
        <button
          onClick={switchDirection}
          className="bg-gray-700 hover:bg-gray-600 p-2 rounded-lg border-4 border-gray-900 transition-colors"
        >
          <SwitchIcon />
        </button>
      </div>

      {/* Output Token */}
      <div className="bg-gray-800 rounded-xl p-4 mt-2 mb-4">
        <div className="flex justify-between text-sm text-gray-400 mb-2">
          <span>You receive</span>
          <span>Balance: {outputBalance}</span>
        </div>
        <div className="flex items-center gap-3">
          <input
            type="text"
            value={expectedOutput}
            readOnly
            placeholder="0.0"
            className="bg-transparent text-2xl text-white outline-none flex-1 w-full"
          />
          <div className="flex items-center gap-2 bg-gray-700 rounded-lg px-3 py-2">
            <span className="text-white font-medium">{outputTokenInfo.symbol}</span>
          </div>
        </div>
      </div>

      {/* Slippage Setting */}
      <div className="flex items-center justify-between text-sm mb-4 px-1">
        <span className="text-gray-400">Slippage tolerance</span>
        <div className="flex items-center gap-2">
          <input
            type="number"
            value={slippage}
            onChange={(e) => setSlippage(e.target.value)}
            className="bg-gray-800 text-white text-right w-16 px-2 py-1 rounded outline-none"
          />
          <span className="text-gray-400">%</span>
        </div>
      </div>

      {/* Swap Details */}
      {amountIn && Number(amountIn) > 0 && (
        <div className="bg-gray-800 rounded-lg p-3 mb-4 text-sm">
          <div className="flex justify-between text-gray-400 mb-1">
            <span>Rate</span>
            <span>
              1 {inputTokenInfo.symbol} = {isZeroToOne ? formattedPrice.toFixed(4) : (1/formattedPrice).toFixed(5)} {outputTokenInfo.symbol}
            </span>
          </div>
          <div className="flex justify-between text-gray-400 mb-1">
            <span>Fee (0.3%)</span>
            <span>{(Number(amountIn) * 0.003).toFixed(inputDecimals)} {inputTokenInfo.symbol}</span>
          </div>
          <div className="flex justify-between text-gray-400">
            <span>Min received</span>
            <span>{minOutput} {outputTokenInfo.symbol}</span>
          </div>
        </div>
      )}

      {/* Error Display */}
      {(swapError || approveError) && (
        <div className="bg-red-900/50 border border-red-500 rounded-lg p-3 mb-4 text-red-300 text-sm">
          {swapError?.message || approveError?.message}
        </div>
      )}

      {/* Success Display */}
      {swapSuccess && (
        <div className="bg-green-900/50 border border-green-500 rounded-lg p-3 mb-4 text-green-300 text-sm">
          Swap successful!
        </div>
      )}

      {/* Action Button */}
      {!isConnected ? (
        <button
          disabled
          className="w-full bg-gray-700 text-gray-400 py-4 rounded-xl font-semibold cursor-not-allowed"
        >
          Connect Wallet
        </button>
      ) : needsApproval ? (
        <button
          onClick={handleApprove}
          disabled={isLoading || !amountIn}
          className="w-full bg-blue-600 hover:bg-blue-500 disabled:bg-gray-700 disabled:text-gray-400 text-white py-4 rounded-xl font-semibold transition-colors"
        >
          {approvePending || approveConfirming
            ? "Approving..."
            : `Approve ${inputTokenInfo.symbol}`}
        </button>
      ) : (
        <button
          onClick={handleSwap}
          disabled={isLoading || !amountIn || Number(amountIn) <= 0}
          className="w-full bg-blue-600 hover:bg-blue-500 disabled:bg-gray-700 disabled:text-gray-400 text-white py-4 rounded-xl font-semibold transition-colors"
        >
          {swapPending || swapConfirming ? "Swapping..." : "Swap"}
        </button>
      )}
    </div>
  );
}

// Icons
function RefreshIcon() {
  return (
    <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
    </svg>
  );
}

function SwitchIcon() {
  return (
    <svg className="w-5 h-5 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M7 16V4m0 0L3 8m4-4l4 4m6 0v12m0 0l4-4m-4 4l-4-4" />
    </svg>
  );
}
