"use client";

import { useEffect, useMemo, useState } from "react";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { formatUnits, parseUnits } from "viem";
import { ArrowDown, ChevronDown, Loader2, Settings } from "lucide-react";

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
// Token Input Component (UI consistency pass)
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
    <div className="rounded-3xl bg-[var(--input-bg)] border border-[var(--border)] p-4 sm:p-5">
      {/* top row */}
      <div className="flex items-center justify-between gap-3 text-xs sm:text-sm text-[var(--text-muted)]">
        <span className="leading-none">{label}</span>

        {balance && (
          <span className="flex items-center gap-2 leading-none">
            <span className="whitespace-nowrap">Balance: {balance}</span>
            {onMaxClick && (
              <button
                type="button"
                onClick={onMaxClick}
                className="text-[var(--accent)] font-semibold hover:text-[var(--accent-hover)]"
                aria-label="Use max balance"
              >
                MAX
              </button>
            )}
          </span>
        )}
      </div>

      {/* main row */}
      <div className="mt-3 flex items-center gap-3">
        <input
          type="text"
          value={amount}
          onChange={(e) =>
            onAmountChange?.(e.target.value.replace(/[^0-9.]/g, ""))
          }
          placeholder="0"
          readOnly={readOnly}
          className="min-w-0 bg-transparent w-full text-3xl sm:text-4xl font-semibold text-[var(--foreground)] placeholder-[var(--text-secondary)] outline-none leading-none"
          inputMode="decimal"
        />

        <button
          type="button"
          className="shrink-0 inline-flex items-center gap-2 h-11 px-3 rounded-2xl font-semibold text-[var(--foreground)] bg-[var(--card)] hover:bg-[var(--card-hover)] border border-[var(--border)]"
          aria-label={`Select ${token.symbol}`}
        >
          <div className="w-7 h-7 rounded-full bg-[var(--accent-muted)] flex items-center justify-center text-xs font-bold text-[var(--accent)]">
            {token.symbol[0]}
          </div>
          <span className="text-sm sm:text-base">{token.symbol}</span>
          <ChevronDown size={16} className="text-[var(--text-muted)]" />
        </button>
      </div>
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════
// Main Swap Card (layout/padding/consistency pass)
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

  // Get balance
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

  // Writes + receipt
  const { writeContractAsync, isPending } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash: txHash,
  });
  const isLoading = isPending || isConfirming;

  // Mock quote
  useEffect(() => {
    if (!amountIn || Number(amountIn) === 0) {
      setAmountOut("");
      return;
    }

    const purrPrice = 4.7;
    const inputAmount = Number(amountIn);

    if (sellToken === "PURR")
      setAmountOut((inputAmount * purrPrice * 0.997).toFixed(6));
    else setAmountOut(((inputAmount / purrPrice) * 0.997).toFixed(5));
  }, [amountIn, sellToken]);

  // Actions
  const handleFlip = () => {
    setSellToken(buyToken);
    setAmountIn(amountOut);
    setAmountOut(amountIn);
  };

  const handleMax = () => {
    if (balance) setAmountIn(balance);
  };

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

  const handleSwap = async () => {
    if (!address || !amountInParsed) return;

    const deadline = BigInt(Math.floor(Date.now() / 1000) + 60 * 20);
    const slippageBps = Math.floor(Number(slippage) * 100);
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
  const buttonState = (() => {
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
  })();

  return (
    <div className="w-full">
      <div className="bg-[var(--card)] rounded-3xl border border-[var(--border)] shadow-lg glow-green p-4 sm:p-6 flex flex-col">
        {/* header */}
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-semibold text-[var(--foreground)]">
            Swap
          </h2>

          <button
            type="button"
            onClick={() => setShowSettings((v) => !v)}
            className="p-2.5 rounded-xl hover:bg-[var(--card-hover)] text-[var(--text-muted)] transition"
            aria-label="Swap settings"
          >
            <Settings size={20} />
          </button>
        </div>

        {/* settings */}
        {showSettings && (
          <div className="mt-4 rounded-2xl bg-[var(--accent-muted)] border border-[var(--border)] p-4">
            <div className="text-sm text-[var(--text-muted)] mb-3">
              Slippage Tolerance
            </div>

            <div className="flex flex-wrap gap-2">
              {["0.1", "0.5", "1.0"].map((val) => (
                <button
                  key={val}
                  type="button"
                  onClick={() => setSlippage(val)}
                  className={`px-3 py-1.5 rounded-xl text-sm font-semibold transition ${
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
                className="w-20 px-2 py-1.5 rounded-xl text-sm border border-[var(--border)] text-center bg-[var(--input-bg)] text-[var(--foreground)] outline-none"
                placeholder="Custom"
                inputMode="decimal"
              />
            </div>
          </div>
        )}

        {/* body */}
        <div className="mt-5">
          {/* Inputs wrapper (allows clean flip placement without negative margins) */}
          <div className="relative space-y-3">
            <TokenInput
              label="Sell"
              token={tokenIn}
              amount={amountIn}
              onAmountChange={setAmountIn}
              balance={balance}
              onMaxClick={handleMax}
            />

            {/* flip button */}
            <div className="pointer-events-none absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2">
              <button
                type="button"
                onClick={handleFlip}
                className="pointer-events-auto bg-[var(--card)] p-2.5 rounded-2xl border border-[var(--border)] hover:border-[var(--border-hover)] hover:bg-[var(--card-hover)] transition shadow-sm"
                aria-label="Flip tokens"
              >
                <ArrowDown size={20} className="text-[var(--accent)]" />
              </button>
            </div>

            <TokenInput
              label="Buy"
              token={tokenOut}
              amount={amountOut}
              readOnly
            />
          </div>
        </div>

        {/* details */}
        {amountIn && amountOut && Number(amountOut) > 0 && (
          <div className="mt-4 rounded-2xl bg-[var(--accent-muted)] border border-[var(--border)] p-4 text-sm">
            <div className="flex items-center justify-between gap-3 text-[var(--text-muted)]">
              <span>Rate</span>
              <span className="text-[var(--foreground)] text-right">
                1 {tokenIn.symbol} ={" "}
                {(Number(amountOut) / Number(amountIn)).toFixed(6)}{" "}
                {tokenOut.symbol}
              </span>
            </div>

            <div className="flex items-center justify-between gap-3 text-[var(--text-muted)] mt-2">
              <span>Fee</span>
              <span className="text-[var(--foreground)]">0.3%</span>
            </div>

            <div className="flex items-center justify-between gap-3 text-[var(--text-muted)] mt-2">
              <span>Slippage</span>
              <span className="text-[var(--foreground)]">{slippage}%</span>
            </div>
          </div>
        )}

        {/* CTA */}
        <div className="mt-6">
          <button
            onClick={buttonState.action}
            disabled={buttonState.disabled}
            className={`w-full py-4 rounded-2xl font-semibold text-lg transition ${
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

          {isSuccess && txHash && (
            <div className="mt-4 rounded-2xl bg-[var(--accent-muted)] border border-[var(--accent)] p-4 text-center">
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
    </div>
  );
}
