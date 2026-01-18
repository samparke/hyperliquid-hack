import "./globals.css";
import type { Metadata } from "next";
import { type ReactNode } from "react";
import Header from "@/app/components/Header";
import { Providers } from "./providers";

export const metadata: Metadata = {
  title: "Sovereign AMM",
  description: "Swap tokens with yield-bearing liquidity on Hyperliquid",
};

export default function RootLayout(props: { children: ReactNode }) {
  return (
    <html lang="en">
      <head>
        <link rel="icon" href="/T-Sender.svg" sizes="any" />
      </head>
      <body>
        <Providers>
          <Header />
          {props.children}
        </Providers>
      </body>
    </html>
  );
}
