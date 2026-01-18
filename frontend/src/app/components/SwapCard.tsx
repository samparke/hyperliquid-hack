"use client";

import { useEffect, useMemo, useState } from "react";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { formatUnits, parseUnits, maxUint256 } from "viem";
import { ArrowDown, ChevronDown, Loader2, Settings } from "lucide-react";
import { TOKENS, ERC20_ABI, SOVEREIGN_POOL_ABI } from "@/contracts";

// Re-export for other components
export { TOKENS };

// Hard-set to your deployed pool
export const SOVEREIGN_POOL_ADDRESS =
  "0x5BaCa1C25D084873C6b9A4D437aC275027C2D94b" as const;

// Your swap fee module (fallback if pool.swapFeeModule() is zero/unset)
const SWAP_FEE_MODULE_FALLBACK =
  "0x4AAB075BCa61D7F8618CCab3af878F889892CBc6" as const;

// Minimal ABI for fee module quoting
const SWAP_FEE_MODULE_ABI = [
  {
    type: "function",
    name: "getSwapFeeInBips",
    stateMutability: "view",
    inputs: [
      { name: "tokenIn", type: "address" },
      { name: "tokenOut", type: "address" },
      { name: "amountIn", type: "uint256" },
      { name: "sender", type: "address" },
      { name: "ctx", type: "bytes" },
    ],
    outputs: [
      {
        name: "data",
        type: "tuple",
        components: [
          { name: "feeInBips", type: "uint256" },
          { name: "internalContext", type: "bytes" },
        ],
      },
    ],
  },
] as const;

// Minimal ABI for ALM quoting
// NOTE: Your ALM returns (isCallbackOnSwap, amountOut, amountInFilled)
// Your previous ABI had a different order, which breaks parsing.
const SOVEREIGN_ALM_ABI_MIN = [
  {
    type: "function",
    name: "getLiquidityQuote",
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
      { name: "", type: "bytes" }, // externalContext
      { name: "", type: "bytes" }, // verifierData (unused for you)
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

// amountInMinusFee exactly like pool:
// amountInMinusFee = amountIn * 10000 / (10000 + feeBips)
function amountInMinusFee(amountIn: bigint, feeBips: bigint): bigint {
  const BIPS = 10_000n;
  return (amountIn * BIPS) / (BIPS + feeBips);
}

// ═══════════════════════════════════════════════════════════════
// Token Input
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
// Swap Card
// ═══════════════════════════════════════════════════════════════
export default function SwapCard() {
  const { address, isConnected } = useAccount();

  const [sellToken, setSellToken] = useState<"PURR" | "USDC">("USDC");
  const [amountIn, setAmountIn] = useState("");
  const [amountOut, setAmountOut] = useState("");
  const [slippage, setSlippage] = useState("0.5");
  const [showSettings, setShowSettings] = useState(false);

  // Track latest tx for UI only (approve OR swap)
  const [txHash, setTxHash] = useState<`0x${string}` | undefined>();

  // Force the allowance cache to refresh after approvals
  const [approvalNonce, setApprovalNonce] = useState(0);

  const buyToken = sellToken === "PURR" ? "USDC" : "PURR";
  const tokenIn = TOKENS[sellToken];
  const tokenOut = TOKENS[buyToken];

  // Parse amount in
  const amountInParsed = useMemo(() => {
    if (!amountIn || isNaN(Number(amountIn))) return 0n;
    try {
      return parseUnits(amountIn, tokenIn.decimals);
    } catch {
      return 0n;
    }
  }, [amountIn, tokenIn.decimals]);

  // Pool reads
  const { data: poolToken0 } = useReadContract({
    address: SOVEREIGN_POOL_ADDRESS,
    abi: SOVEREIGN_POOL_ABI,
    functionName: "token0",
    query: { enabled: true },
  });

  const { data: poolAlm } = useReadContract({
    address: SOVEREIGN_POOL_ADDRESS,
    abi: SOVEREIGN_POOL_ABI,
    functionName: "alm",
    query: { enabled: true },
  });

  const { data: poolSwapFeeModule } = useReadContract({
    address: SOVEREIGN_POOL_ADDRESS,
    abi: SOVEREIGN_POOL_ABI,
    functionName: "swapFeeModule",
    query: { enabled: true },
  });

  // Swap direction based on actual token0
  const isZeroToOne = useMemo(() => {
    if (!poolToken0) return sellToken === "PURR"; // fallback
    return (
      tokenIn.address.toLowerCase() === (poolToken0 as string).toLowerCase()
    );
  }, [poolToken0, tokenIn.address, sellToken]);

  // Fee module address
  const feeModuleAddress = useMemo(() => {
    const mod = (poolSwapFeeModule as string | undefined) || "";
    const isZero =
      !mod || mod === "0x0000000000000000000000000000000000000000";
    return (isZero ? SWAP_FEE_MODULE_FALLBACK : mod) as `0x${string}`;
  }, [poolSwapFeeModule]);

  // Balance
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

  // Allowance (keyed by approvalNonce so it re-queries after approve confirms)
  const {
    data: allowance,
    refetch: refetchAllowance,
    queryKey: _allowanceKey, // not used, but keeps TS happy if wagmi exposes it
  } = useReadContract({
    address: tokenIn.address,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: address ? [address, SOVEREIGN_POOL_ADDRESS] : undefined,
    query: {
      enabled: !!address && amountInParsed > 0n,
      // ensure we don't keep stale allowance around
      staleTime: 0,
      gcTime: 0,
    },
    // @ts-expect-error wagmi v2 supports scopeKey; if yours doesn't, remove it.
    scopeKey: `allowance-${sellToken}-${approvalNonce}`,
  });

  const needsApproval = useMemo(() => {
    if (!amountInParsed) return false;
    if (allowance === undefined) return false;
    return allowance < amountInParsed;
  }, [amountInParsed, allowance]);

  // Fee bips
  const { data: feeDataRaw } = useReadContract({
    address: feeModuleAddress,
    abi: SWAP_FEE_MODULE_ABI,
    functionName: "getSwapFeeInBips",
    args:
      amountInParsed > 0n
        ? [
            tokenIn.address,
            tokenOut.address,
            amountInParsed,
            (address ??
              "0x0000000000000000000000000000000000000000") as `0x${string}`,
            "0x",
          ]
        : undefined,
    query: { enabled: amountInParsed > 0n },
  });

  const feeBips = useMemo(() => {
    const v: any = feeDataRaw;
    // viem returns the tuple object directly: { feeInBips, internalContext }
    const fee = v?.feeInBips;
    if (fee == null) return 0n;
    try {
      return BigInt(fee);
    } catch {
      return 0n;
    }
  }, [feeDataRaw]);

  const feePct = useMemo(() => Number(feeBips) / 100, [feeBips]);

  // amountInMinusFee per pool
  const amountInMinus = useMemo(() => {
    if (amountInParsed <= 0n) return 0n;
    return amountInMinusFee(amountInParsed, feeBips);
  }, [amountInParsed, feeBips]);

  // ALM quote
  const { data: almQuoteRaw, isLoading: quoteLoading } = useReadContract({
    address: (poolAlm as `0x${string}`) || undefined,
    abi: SOVEREIGN_ALM_ABI_MIN,
    functionName: "getLiquidityQuote",
    args:
      amountInParsed > 0n && poolAlm
        ? [
            {
              isZeroToOne,
              amountInMinusFee: amountInMinus,
              feeInBips: feeBips,
              sender: (address ??
                "0x0000000000000000000000000000000000000000") as `0x${string}`,
              recipient: (address ??
                "0x0000000000000000000000000000000000000000") as `0x${string}`,
              tokenOutSwap: tokenOut.address,
            },
            "0x",
            "0x",
          ]
        : undefined,
    query: { enabled: amountInParsed > 0n && !!poolAlm },
  });

  const quotedOut = useMemo(() => {
    const q: any = almQuoteRaw;
    const out = q?.amountOut;
    if (out == null) return 0n;
    try {
      return BigInt(out);
    } catch {
      return 0n;
    }
  }, [almQuoteRaw]);

  // Sync amountOut UI
  useEffect(() => {
    if (!amountIn || Number(amountIn) === 0 || amountInParsed === 0n) {
      setAmountOut("");
      return;
    }
    if (quotedOut > 0n) setAmountOut(formatUnits(quotedOut, tokenOut.decimals));
    else setAmountOut("");
  }, [amountIn, amountInParsed, quotedOut, tokenOut.decimals]);

  // Writes + receipt
  const { writeContractAsync, isPending } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash: txHash,
  });
  const isLoading = isPending || isConfirming;

  // After ANY tx confirms, if it was an approval, refresh allowance.
  // Easiest: always refetch allowance on success.
  useEffect(() => {
    if (!isSuccess) return;
    // bump nonce to force query key change + refetch explicitly
    setApprovalNonce((n) => n + 1);
    refetchAllowance?.();
    // (optional) clear txHash so "Confirming..." doesn't stick across actions
    setTxHash(undefined);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isSuccess]);

  // Actions
  const handleFlip = () => {
    setSellToken(buyToken);
    setAmountIn(amountOut);
    setAmountOut(amountIn);
  };

  const handleMax = () => {
    if (balance) setAmountIn(balance);
  };

  // Approve MAX so you don't get stuck approving repeatedly
  const handleApprove = async () => {
    if (!address) return;
    try {
      const hash = await writeContractAsync({
        address: tokenIn.address,
        abi: ERC20_ABI,
        functionName: "approve",
        args: [SOVEREIGN_POOL_ADDRESS, maxUint256],
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

    const minOut =
      quotedOut > 0n
        ? (quotedOut * BigInt(10_000 - slippageBps)) / 10_000n
        : 0n;

    const params = {
      isSwapCallback: false,
      isZeroToOne,
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
        abi: SOVEREIGN_POOL_ABI,
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
    if (amountInParsed > 0n && quoteLoading) return { text: "Quoting...", disabled: true };
    if (quotedOut === 0n) return { text: "No quote", disabled: true };
    return { text: "Swap", disabled: false, action: handleSwap };
  })();

  const shownRate = useMemo(() => {
    const ain = Number(amountIn);
    const aout = Number(amountOut);
    if (!ain || !aout || ain <= 0 || aout <= 0) return "";
    return (aout / ain).toFixed(6);
  }, [amountIn, amountOut]);

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

            <TokenInput label="Buy" token={tokenOut} amount={amountOut} readOnly />
          </div>
        </div>

        {/* details */}
        {amountIn && amountOut && Number(amountOut) > 0 && (
          <div className="mt-4 rounded-2xl bg-[var(--accent-muted)] border border-[var(--border)] p-4 text-sm">
            <div className="flex items-center justify-between gap-3 text-[var(--text-muted)]">
              <span>Rate</span>
              <span className="text-[var(--foreground)] text-right">
                1 {tokenIn.symbol} = {shownRate} {tokenOut.symbol}
              </span>
            </div>

            <div className="flex items-center justify-between gap-3 text-[var(--text-muted)] mt-2">
              <span>Fee (dynamic)</span>
              <span className="text-[var(--foreground)]">
                {feePct.toFixed(2)}%{" "}
                <span className="text-[var(--text-muted)]">
                  ({feeBips.toString()} bips)
                </span>
              </span>
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

          {txHash && (
            <div className="mt-4 rounded-2xl bg-[var(--accent-muted)] border border-[var(--border)] p-4 text-center">
              <p className="text-[var(--text-muted)] text-sm">
                Tx:{" "}
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

        {/* debug footer */}
        <div className="mt-4 text-xs text-[var(--text-muted)]">
          <div className="flex flex-wrap gap-x-4 gap-y-1">
            <span>
              Pool: <span className="font-mono">{SOVEREIGN_POOL_ADDRESS}</span>
            </span>
            <span>
              FeeModule: <span className="font-mono">{feeModuleAddress}</span>
            </span>
            <span>
              ALM: <span className="font-mono">{(poolAlm as string) || "-"}</span>
            </span>
            <span>
              token0: <span className="font-mono">{(poolToken0 as string) || "-"}</span>
            </span>
          </div>
        </div>
      </div>
    </div>
  );
}