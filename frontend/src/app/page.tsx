"use client";

import { useState } from "react";
import SwapCard from "./components/SwapCard";
import AddLiquidityCard from "./components/AddLiquidityCard";
import RemoveLiquidityCard from "./components/RemoveLiquidityCard";

export default function Home() {
  const [activeTab, setActiveTab] = useState<"swap" | "add" | "remove">("swap");

  return (
    <main className="min-h-screen bg-[var(--background)] flex flex-col items-center px-4 sm:px-6 lg:px-8 pt-10 pb-20">
      <div className="w-full max-w-5xl space-y-12 md:space-y-16">
        {/* Hero */}
        <div className="text-center">
          <p className="text-[var(--text-muted)] text-lg sm:text-xl max-w-md mx-auto">
            Swap tokens with yield-bearing liquidity on Hyperliquid
          </p>
        </div>

        {/* Tabs + Content */}
        <div className="w-full">
          <div className="flex gap-2 p-1 bg-[var(--card)] rounded-2xl border border-[var(--border)] mb-6 max-w-md mx-auto">
            {["swap", "add", "remove"].map((tab) => (
              <button
                key={tab}
                onClick={() => setActiveTab(tab as any)}
                className={`flex-1 py-3 px-4 rounded-xl font-medium text-sm transition ${
                  activeTab === tab
                    ? "bg-[var(--accent)] text-white glow-green"
                    : "text-[var(--text-muted)] hover:text-[var(--foreground)]"
                }`}
              >
                {tab === "swap"
                  ? "Swap"
                  : tab === "add"
                    ? "Add Liquidity"
                    : "Remove Liquidity"}
              </button>
            ))}
          </div>

          {activeTab === "swap" && <SwapCard />}
          {activeTab === "add" && <AddLiquidityCard />}
          {activeTab === "remove" && <RemoveLiquidityCard />}
        </div>
      </div>
    </main>
  );
}
