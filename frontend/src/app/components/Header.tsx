"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";

export default function Header() {
  return (
    <header className="sticky top-0 z-50 bg-[var(--background)]/80 backdrop-blur-sm border-b border-[var(--border)]">
      <div className="max-w-7xl mx-auto px-4 sm:px-6">
        <div className="flex items-center justify-between h-16">
          {/* Logo */}
          <div className="flex items-center gap-2">
            <div className="w-8 h-8 rounded-lg bg-[var(--accent)] flex items-center justify-center glow-green">
              <span className="text-white font-bold text-sm">S</span>
            </div>
            <span className="text-lg font-semibold text-[var(--foreground)]">
              Sovereign
            </span>
          </div>

          {/* Navigation */}
          <nav className="hidden md:flex items-center gap-8">
            <a href="#" className="text-white font-medium text-sm">
              Swap
            </a>
            <a href="#" className="text-white hover:gray text-sm transition">
              Debug
            </a>
          </nav>

          {/* Connect button */}
          <ConnectButton
            showBalance={false}
            chainStatus="icon"
            accountStatus={{
              smallScreen: "avatar",
              largeScreen: "full",
            }}
          />
        </div>
      </div>
    </header>
  );
}
