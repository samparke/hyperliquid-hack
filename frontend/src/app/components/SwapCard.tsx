"use client";

import { useState, useMemo, useEffect } from "react";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { parseUnits, formatUnits } from "viem";
import { ArrowDown, Loader2, Settings, ChevronDown } from "lucide-react";

// ═══════════════════════════════════════════════════════════════
// Contract Addresses - Hyperliquid Testnet
// ═══════════════════════════════════════════════════════════════
export const SOVEREIGN_POOL_ADDRESS =
  "0x0000000000000000000000000000000000000000" as const; // TODO: Deploy and update

export const TOKENS = {
  PURR: {
    address: "0xa9056c15938f9aff34CD497c722Ce33dB0C2fD57" as const,
    symbol: "PURR",
    decimals: 5,
    name: "PURR",
  },
  USDC: {
    address: "0x5555555555555555555555555555555555555555" as const,
    symbol: "USDC",
    decimals: 6,
    name: "USD Coin",
  },
} as const;

// ═══════════════════════════════════════════════════════════════
// ABIs
// ═══════════════════════════════════════════════════════════════
const erc20Abi = [
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
] as const;

const poolAbi = [
  {
    name: "swap",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "params",
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
] as const;

// ═══════════════════════════════════════════════════════════════
// Token Input Component
// ═══════════════════════════════════════════════════════════════
function TokenInput({
  label,
  token,
  amount,
  onAmountChange,
  balance,
  readOnly = false,
  onMaxClick,
}: {
  label: string;
  token: (typeof TOKENS)[keyof typeof TOKENS];
  amount: string;
  onAmountChange?: (value: string) => void;
  balance?: string;
  readOnly?: boolean;
  onMaxClick?: () => void;
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
// Main Swap Card
// ═══════════════════════════════════════════════════════════════
export default function SwapCard() {
  const { address, isConnected } = useAccount();

  const [sellToken, setSellToken] = useState<"PURR" | "USDC">("USDC");
  const [amountIn, setAmountIn] = useState("");
  const [amountOut, setAmountOut] = useState("");
  const [slippage, setSlippage] = useState("0.5");
  const [showSettings, setShowSettings] = useState(false);
  const [txHash, setTxHash] = useState<`0x${string}` | undefined>();

  const buyToken = sellToken === "PURR" ? "USDC" : "PURR";
  const tokenIn = TOKENS[sellToken];
  const tokenOut = TOKENS[buyToken];

  // Parse amount
  const amountInParsed = useMemo(() => {
    if (!amountIn || isNaN(Number(amountIn))) return 0n;
    try {
      return parseUnits(amountIn, tokenIn.decimals);
    } catch {
      return 0n;
    }
  }, [amountIn, tokenIn.decimals]);

  // Get token balance using useReadContract
  const { data: balanceRaw } = useReadContract({
    address: tokenIn.address,
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

  const balance = balanceRaw
    ? formatUnits(balanceRaw, tokenIn.decimals)
    : undefined;

  // Get allowance
  const { data: allowance } = useReadContract({
    address: tokenIn.address,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, SOVEREIGN_POOL_ADDRESS] : undefined,
    query: { enabled: !!address && amountInParsed > 0n },
  });

  const needsApproval = useMemo(() => {
    if (!amountInParsed || !allowance) return false;
    return allowance < amountInParsed;
  }, [amountInParsed, allowance]);

  // Contract writes
  const { writeContractAsync, isPending } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash: txHash,
  });

  const isLoading = isPending || isConfirming;

  // Estimate output (simplified - in production call ALM.getLiquidityQuote)
  useEffect(() => {
    if (!amountIn || Number(amountIn) === 0) {
      setAmountOut("");
      return;
    }

    // Mock price: 1 PURR = ~$4.70
    const purrPrice = 4.7;
    const inputAmount = Number(amountIn);

    if (sellToken === "PURR") {
      // PURR -> USDC
      const output = inputAmount * purrPrice * 0.997; // 0.3% fee
      setAmountOut(output.toFixed(6));
    } else {
      // USDC -> PURR
      const output = (inputAmount / purrPrice) * 0.997;
      setAmountOut(output.toFixed(5));
    }
  }, [amountIn, sellToken]);

  // Flip tokens
  const handleFlip = () => {
    setSellToken(buyToken);
    setAmountIn(amountOut);
    setAmountOut(amountIn);
  };

  // Max button
  const handleMax = () => {
    if (balance) {
      setAmountIn(balance);
    }
  };

  // Approve
  const handleApprove = async () => {
    if (!address || !amountInParsed) return;
    try {
      const hash = await writeContractAsync({
        address: tokenIn.address,
        abi: erc20Abi,
        functionName: "approve",
        args: [SOVEREIGN_POOL_ADDRESS, amountInParsed],
      });
      setTxHash(hash);
    } catch (err) {
      console.error("Approve failed:", err);
    }
  };

  // Swap
  const handleSwap = async () => {
    if (!address || !amountInParsed) return;

    const deadline = BigInt(Math.floor(Date.now() / 1000) + 60 * 20);
    const slippageBps = Number(slippage) * 100;
    const minOut = amountOut
      ? (BigInt(Math.floor(Number(amountOut) * 10 ** tokenOut.decimals)) *
          BigInt(10000 - slippageBps)) /
        10000n
      : 0n;

    const params = {
      isSwapCallback: false,
      isZeroToOne: sellToken === "PURR",
      amountIn: amountInParsed,
      amountOutMin: minOut,
      deadline,
      recipient: address,
      swapTokenOut: tokenOut.address,
      swapContext: {
        externalContext: "0x" as const,
        verifierContext: "0x" as const,
        swapFeeModuleContext: "0x" as const,
        swapCallbackContext: "0x" as const,
      },
    };

    try {
      const hash = await writeContractAsync({
        address: SOVEREIGN_POOL_ADDRESS,
        abi: poolAbi,
        functionName: "swap",
        args: [params],
      });
      setTxHash(hash);
    } catch (err) {
      console.error("Swap failed:", err);
    }
  };

  // Button state
  const getButtonState = () => {
    if (!isConnected) return { text: "Connect Wallet", disabled: true };
    if (!amountIn || Number(amountIn) === 0)
      return { text: "Enter amount", disabled: true };
    if (balance && Number(amountIn) > Number(balance))
      return { text: "Insufficient balance", disabled: true };
    if (isLoading) return { text: "Confirming...", disabled: true };
    if (needsApproval)
      return {
        text: `Approve ${tokenIn.symbol}`,
        disabled: false,
        action: handleApprove,
      };
    return { text: "Swap", disabled: false, action: handleSwap };
  };

  const buttonState = getButtonState();

  return (
    <div className="w-full max-w-[700px] mx-auto">
      {/* Card */}
      <div className="bg-[var(--card)] rounded-3xl border border-[var(--border)] shadow-lg glow-green ">
        {/* Header */}
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-lg font-semibold text-[var(--foreground)]">
            Swap
          </h2>
          <button
            onClick={() => setShowSettings(!showSettings)}
            className="p-2 rounded-xl hover:bg-[var(--card-hover)] text-[var(--text-muted)]"
          >
            <Settings size={20} />
          </button>
        </div>

        {/* Settings dropdown */}
        {showSettings && (
          <div className="mb-4 p-3 rounded-xl bg-[var(--accent-muted)] border border-[var(--border)]">
            <div className="text-sm text-[var(--text-muted)] mb-2">
              Slippage Tolerance
            </div>
            <div className="flex gap-2">
              {["0.1", "0.5", "1.0"].map((val) => (
                <button
                  key={val}
                  onClick={() => setSlippage(val)}
                  className={`px-3 py-1.5 rounded-lg text-sm font-medium transition ${
                    slippage === val
                      ? "bg-[var(--accent)] text-white"
                      : "bg-[var(--input-bg)] border border-[var(--border)] text-[var(--text-muted)] hover:border-[var(--border-hover)]"
                  }`}
                >
                  {val}%
                </button>
              ))}
              <input
                type="text"
                value={slippage}
                onChange={(e) =>
                  setSlippage(e.target.value.replace(/[^0-9.]/g, ""))
                }
                className="w-16 px-2 py-1.5 rounded-lg text-sm border border-[var(--border)] text-center bg-[var(--input-bg)] text-[var(--foreground)]"
                placeholder="Custom"
              />
            </div>
          </div>
        )}

        {/* Sell */}
        <TokenInput
          label="Sell"
          token={tokenIn}
          amount={amountIn}
          onAmountChange={setAmountIn}
          balance={balance}
          onMaxClick={handleMax}
        />

        {/* Flip button */}
        <div className="flex justify-center -my-2 relative z-10">
          <button
            onClick={handleFlip}
            className="bg-[var(--card)] p-2 rounded-xl border border-[var(--border)] hover:border-[var(--border-hover)] hover:bg-[var(--card-hover)] transition"
          >
            <ArrowDown size={20} className="text-[var(--accent)]" />
          </button>
        </div>

        {/* Buy */}
        <TokenInput label="Buy" token={tokenOut} amount={amountOut} readOnly />

        {/* Price info */}
        {amountIn && amountOut && Number(amountOut) > 0 && (
          <div className="mt-4 p-3 rounded-xl bg-[var(--accent-muted)] border border-[var(--border)] text-sm">
            <div className="flex justify-between text-[var(--text-muted)]">
              <span>Rate</span>
              <span className="text-[var(--foreground)]">
                1 {tokenIn.symbol} ={" "}
                {(Number(amountOut) / Number(amountIn)).toFixed(6)}{" "}
                {tokenOut.symbol}
              </span>
            </div>
            <div className="flex justify-between text-[var(--text-muted)] mt-1">
              <span>Fee</span>
              <span className="text-[var(--foreground)]">0.3%</span>
            </div>
            <div className="flex justify-between text-[var(--text-muted)] mt-1">
              <span>Slippage</span>
              <span className="text-[var(--foreground)]">{slippage}%</span>
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
              Swap successful!{" "}
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
