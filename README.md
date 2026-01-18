# Delta Flow

Delta Flow is a highly composable and precise AMM inspired by the Valantis Sovereign Pool architecture.

While popular AMMs like Uniswap have started to integrate more functionality - for example, Uniswap v4 hooks - several constraints still exist. One example is reserve-based pricing. For large trades in low-liquidity pools, the pool price can deviate far from the true market price, resulting in high slippage costs for the end-user.

Delta Flow brings a new class of AMMs to market that: prices swaps based on spot prices, apply dynamic fees based pool value imbalances, allows for the allocation of excess liquidity to HyperCore vaults, and recalls liquidity from vaults to traders if the vault has insufficent liquidity.

![Delta Flow Logo](frontend/public/flow.png)

## Delta Flow has three modules:

- Delta Vault
- Delta ALM
- Delta Swap-Fee

## Delta Vault

A module which:

- Holds all pool assets
- Allows a strategist to deploy excess capital to a HyperCore Vault
- Provides the tokens for a swap in the Delta Pool
- Recalls the tokens from vault positions if the vault is short in existing reserves

Because pricing is anchored to spot markets, the pool does not naturally rebalance through arbitrage the way constant-product AMMs do. Without a rebalance mechanism, a pool could be drained of one token if it is repeatedly swapped out.

To counter this, Sovereign vault sells the token with higher reserves on the spot market for the token with less reserves.

## Delta ALM

A module which calculates the price for an asset to be swapped.

Delta ALM reads from the HyperEVM precompile contract to get the mid spot price, calculates the total value of the other token needed for the trade (USDC in our product), and returns this amount for the user to swap in.

This prevents the reserve-based price drift described above.

## Delta Swap-Fee

A module which dynamically calculates fees based on deviations within pool reserves.

The pool aims to maintain a 1:1 USDC value ratio:

- the USDC value of token X reserves must equal the USDC value of token Y reserves.

To further avoid deviations in pool balances, we apply a linearly increasing fee for every 0.01% deviation.

Target condition (healthy state):

```
USDC/PURR * spot price
```

### Frontend

```bash
cd frontend
pnpm dev
```
