import "./globals.css";
import type { Metadata } from "next";
import { type ReactNode } from "react";
import Header from "@/app/components/Header";
import { Providers } from "./providers";
import { Quicksand } from "next/font/google";

const quicksand = Quicksand({
  subsets: ["latin"],
  weight: ["300", "400", "500", "600", "700"],
});

export const metadata: Metadata = {
  title: "Delta Flow",
  description: "Swap tokens with yield-bearing liquidity on Hyperliquid",
};

export default function RootLayout(props: { children: ReactNode }) {
  return (
    <html lang="en">
      <head>
        <link rel="icon" href="/T-Sender.svg" sizes="any" />
      </head>
      <body className={quicksand.className}>
        <Providers>
          <Header />
          {props.children}
        </Providers>
      </body>
    </html>
  );
}
