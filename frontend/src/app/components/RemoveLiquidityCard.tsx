"use client";

import { useState, useMemo } from "react";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { parseUnits, formatUnits } from "viem";
import { Minus, Loader2, ChevronDown } from "lucide-react";
import { TOKENS } from "./SwapCard";

// ═══════════════════════════════════════════════════════════════
// Token Input Component
// ═══════════════════════════════════════════════════════════════
function TokenInput({
  label,
  token,
  amount,
  onAmountChange,
  balance,
  onMaxClick,
  readOnly = false,
}: {
  label: string;
  token: (typeof TOKENS)[keyof typeof TOKENS];
  amount: string;
  onAmountChange?: (value: string) => void;
  balance?: string;
  onMaxClick?: () => void;
  readOnly?: boolean;
}) {
  return (
    <div className="rounded-2xl bg-[var(--card)] border border-[var(--border)] p-4">
      <div className="flex justify-between text-sm text-[var(--text-muted)] mb-2">
        <span>{label}</span>
        {balance && (
          <span className="flex items-center gap-1">
            Balance: {balance}
            {onMaxClick && (
              <button
                onClick={onMaxClick}
                className="text-[var(--accent)] font-medium hover:text-[var(--accent-hover)] ml-1"
              >
                MAX
              </button>
            )}
          </span>
        )}
      </div>
      <div className="flex items-center gap-3">
        <input
          type="text"
          value={amount}
          onChange={(e) =>
            onAmountChange?.(e.target.value.replace(/[^0-9.]/g, ""))
          }
          placeholder="0"
          readOnly={readOnly}
          className="bg-transparent text-3xl font-medium text-[var(--foreground)] placeholder-[var(--text-secondary)] outline-none flex-1 min-w-0"
        />
        <button className="flex items-center gap-2 bg-[var(--input-bg)] px-3 py-2 rounded-xl font-medium text-[var(--foreground)] hover:bg-[var(--card-hover)] border border-[var(--border)]">
          <div className="w-6 h-6 rounded-full bg-[var(--accent-muted)] flex items-center justify-center text-xs font-bold text-[var(--accent)]">
            {token.symbol[0]}
          </div>
          {token.symbol}
          <ChevronDown size={16} className="text-[var(--text-muted)]" />
        </button>
      </div>
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════
// Main Remove Liquidity Card
// ═══════════════════════════════════════════════════════════════
export default function RemoveLiquidityCard() {
  const { address, isConnected } = useAccount();

  const [amount0, setAmount0] = useState("");
  const [amount1, setAmount1] = useState("");
  const [txHash, _setTxHash] = useState<`0x${string}` | undefined>();

  const token0 = TOKENS.PURR;
  const token1 = TOKENS.USDC;

  // Parse amounts
  const amount0Parsed = useMemo(() => {
    if (!amount0 || isNaN(Number(amount0))) return 0n;
    try {
      return parseUnits(amount0, token0.decimals);
    } catch {
      return 0n;
    }
  }, [amount0, token0.decimals]);

  const amount1Parsed = useMemo(() => {
    if (!amount1 || isNaN(Number(amount1))) return 0n;
    try {
      return parseUnits(amount1, token1.decimals);
    } catch {
      return 0n;
    }
  }, [amount1, token1.decimals]);

  // Get token balances (user's liquidity position - placeholder)
  const { data: balance0Raw } = useReadContract({
    address: token0.address,
    abi: [
      {
        name: "balanceOf",
        type: "function",
        stateMutability: "view",
        inputs: [{ name: "account", type: "address" }],
        outputs: [{ name: "", type: "uint256" }],
      },
    ] as const,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  const { data: balance1Raw } = useReadContract({
    address: token1.address,
    abi: [
      {
        name: "balanceOf",
        type: "function",
        stateMutability: "view",
        inputs: [{ name: "account", type: "address" }],
        outputs: [{ name: "", type: "uint256" }],
      },
    ] as const,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  // TODO: Get actual LP position from ALM/vault
  const balance0 = balance0Raw
    ? formatUnits(balance0Raw, token0.decimals)
    : undefined;
  const balance1 = balance1Raw
    ? formatUnits(balance1Raw, token1.decimals)
    : undefined;

  // Contract writes
  const { isPending } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash: txHash,
  });

  const isLoading = isPending || isConfirming;

  // Remove liquidity (placeholder - needs proper ALM/vault integration)
  const handleRemoveLiquidity = async () => {
    if (!address || !amount0Parsed || !amount1Parsed) return;
    // TODO: Implement actual liquidity withdrawal through ALM/vault
    console.log("Remove liquidity:", {
      amount0: amount0Parsed,
      amount1: amount1Parsed,
    });
  };

  // Max buttons
  const handleMax0 = () => {
    if (balance0) setAmount0(balance0);
  };

  const handleMax1 = () => {
    if (balance1) setAmount1(balance1);
  };

  // Button state
  const getButtonState = () => {
    if (!isConnected) return { text: "Connect Wallet", disabled: true };
    if (
      (!amount0 || Number(amount0) === 0) &&
      (!amount1 || Number(amount1) === 0)
    )
      return { text: "Enter amounts", disabled: true };
    if (isLoading) return { text: "Confirming...", disabled: true };
    return {
      text: "Remove Liquidity",
      disabled: false,
      action: handleRemoveLiquidity,
    };
  };

  const buttonState = getButtonState();

  return (
    <div className="w-full">
      <div className="bg-[var(--card)] rounded-3xl border border-[var(--border)] p-4 shadow-lg glow-green">
        <h2 className="text-lg font-semibold text-[var(--foreground)] mb-4">
          Remove Liquidity
        </h2>

        {/* Token 0 */}
        <TokenInput
          label="PURR"
          token={token0}
          amount={amount0}
          onAmountChange={setAmount0}
          balance={balance0}
          onMaxClick={handleMax0}
        />

        {/* Minus icon */}
        <div className="flex justify-center -my-2 relative z-10">
          <div className="bg-[var(--card)] p-2 rounded-xl border border-[var(--border)]">
            <Minus size={20} className="text-[var(--accent)]" />
          </div>
        </div>

        {/* Token 1 */}
        <TokenInput
          label="USDC"
          token={token1}
          amount={amount1}
          onAmountChange={setAmount1}
          balance={balance1}
          onMaxClick={handleMax1}
        />

        {/* Info */}
        {(amount0 || amount1) && (
          <div className="mt-4 p-3 rounded-xl bg-[var(--accent-muted)] border border-[var(--border)] text-sm">
            <div className="flex justify-between text-[var(--text-muted)]">
              <span>Share of Pool</span>
              <span className="text-[var(--foreground)]">-</span>
            </div>
          </div>
        )}

        {/* Action button */}
        <button
          onClick={buttonState.action}
          disabled={buttonState.disabled}
          className={`w-full mt-4 py-4 rounded-2xl font-semibold text-lg transition ${
            buttonState.disabled
              ? "bg-[var(--input-bg)] text-[var(--text-secondary)] cursor-not-allowed"
              : "bg-[var(--accent)] text-white hover:bg-[var(--accent-hover)] glow-green-strong"
          }`}
        >
          <span className="flex items-center justify-center gap-2">
            {isLoading && <Loader2 size={20} className="animate-spin" />}
            {buttonState.text}
          </span>
        </button>

        {/* Success message */}
        {isSuccess && txHash && (
          <div className="mt-4 p-3 rounded-xl bg-[var(--accent-muted)] border border-[var(--accent)] text-center">
            <p className="text-[var(--accent)] text-sm">
              Transaction successful!{" "}
              <a
                href={`https://explorer.hyperliquid-testnet.xyz/tx/${txHash}`}
                target="_blank"
                rel="noopener noreferrer"
                className="underline font-medium"
              >
                View transaction
              </a>
            </p>
          </div>
        )}
      </div>
    </div>
  );
}
