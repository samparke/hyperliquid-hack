"use client";

import { useState } from "react";
import SwapCard from "./components/SwapCard";
import AddLiquidityCard from "./components/AddLiquidityCard";
import RemoveLiquidityCard from "./components/RemoveLiquidityCard";
import StrategistCard from "./components/StrategistCard";

type Tab = "swap" | "add" | "remove" | "debug";

export default function Home() {
  const [activeTab, setActiveTab] = useState<Tab>("swap");

  return (
    <main className="min-h-screen bg-[var(--background)] flex flex-col items-center px-4 sm:px-6 lg:px-8 pt-10 pb-20">
      <div className="w-full max-w-5xl space-y-12 md:space-y-16">
        {/* Hero */}
        <div className="text-center">
          <p className="text-[var(--text-muted)] text-lg sm:text-xl max-w-md mx-auto">
            Swap tokens with yield-bearing liquidity on <b></b>
            <i>Hyperliquid</i>
          </p>
        </div>

        {/* Tabs + Content (shared width) */}
        <div className="w-full flex justify-center">
          <div
            className={`w-full ${activeTab === "debug" ? "max-w-[700px]" : "max-w-[500px]"}`}
          >
            {/* Tabs */}
            <div className="flex gap-2 p-1 bg-[var(--card)] rounded-2xl border border-[var(--border)] mb-6">
              {(["swap", "add", "remove", "debug"] as const).map((tab) => (
                <button
                  key={tab}
                  onClick={() => setActiveTab(tab)}
                  className={`flex-1 py-3 px-4 rounded-xl font-medium text-sm transition ${
                    activeTab === tab
                      ? "bg-[var(--accent)] text-white glow-green"
                      : "text-[var(--text-muted)] hover:text-[var(--foreground)]"
                  }`}
                >
                  {tab === "swap"
                    ? "Swap"
                    : tab === "add"
                      ? "Add"
                      : tab === "remove"
                        ? "Remove"
                        : "Strategist"}
                </button>
              ))}
            </div>

            {/* Content */}
            {activeTab === "swap" && <SwapCard />}
            {activeTab === "add" && <AddLiquidityCard />}
            {activeTab === "remove" && <RemoveLiquidityCard />}
            {activeTab === "debug" && <StrategistCard />}
          </div>
        </div>
      </div>
    </main>
  );
}
