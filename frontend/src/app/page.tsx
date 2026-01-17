import SwapCard from "@/app/components/SwapCard";

export default function Home() {
  return (
    <main className="min-h-screen bg-zinc-50 flex flex-col items-center px-4 sm:px-6 lg:px-8 pt-10 pb-20">
      <div className="w-full max-w-lg md:max-w-2xl space-y-12 md:space-y-16">
        {/* Hero section */}
        <div className="text-center">
          <h1 className="text-4xl sm:text-5xl font-bold text-zinc-900 mb-4">
            Sovereign AMM
          </h1>
          <p className="text-zinc-600 text-lg sm:text-xl max-w-md mx-auto">
            Swap tokens with yield-bearing liquidity on Hyperliquid
          </p>
        </div>

        <div className="w-full max-w-md mx-auto">
          <SwapCard />
        </div>
      </div>
    </main>
  );
}
