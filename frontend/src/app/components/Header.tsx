"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";

export default function Header() {
  return (
    <header className="sticky top-0 z-50 bg-[var(--background)]/80 backdrop-blur-sm border-b border-[var(--border)] justfiy-center">
      <div className="max-w-7xl mx-auto px-6 sm:px-10">
        <div className="flex items-center justify-between h-16">
          {/* Logo */}
          <div className="flex items-center gap-2">
            <img
              src="/deltaFlow.png"
              alt="Delta Flow"
              className="h-7 sm:h-8 w-auto object-contain"
            />
          </div>

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
