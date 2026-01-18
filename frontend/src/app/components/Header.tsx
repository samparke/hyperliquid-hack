"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";

export default function Header() {
  return (
    <header className="sticky top-0 z-50 bg-[var(--background)]/80 backdrop-blur-sm border-b border-[var(--border)] justfiy-center">
      <div className="max-w-7xl mx-auto px-6 sm:px-10">
        <div className="flex items-center justify-between h-16">
          {/* Logo */}
          <div className="flex items-center gap-2">
            <span className="text-lg font-semibold text-[var(--foreground)]">
              Sovereign
            </span>
          </div>

          {/* Navigation */}
          <nav className="hidden md:flex items-center gap-20">
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
