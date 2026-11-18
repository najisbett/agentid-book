# AgentID Book

An on-chain book for Binance Wallet **Agent IDs** (names ending in `.ai`).

Agent ID resolution lives in Binance's backend: `baguslupamakan.ai` maps to an EOA,
but no smart contract can read that mapping, so no dApp can gate on an Agent ID.
This book fixes that on BNB Chain.

## How it works

1. A holder signs an EIP-712 `Bind(bytes32 id, address owner, string handle, uint256 deadline)`
   message with the same address their Agent ID resolves to.
2. Anyone submits that signature to `AgentIDBook.bind(...)`; a relayer pays the gas,
   so binding costs the holder nothing.
3. The contract checks the recovery against `owner`, stores `handle → owner` and
   `owner → handle`, and emits `Bound`.
4. Any dApp can now read the name on-chain: `resolveHandle("x")`, `isAgent(addr)`,
   `handleOf(addr)`.

One Agent ID per address, one address per Agent ID. Rebinding requires `unbind()` first.

## Contract

`src/AgentIDBook.sol` — MIT, Solidity 0.8.24, no dependencies, no owner, no upgrade path.

Tests: `forge test` — 9 tests covering signature forgery, handle theft, replay across
contracts, expiry, one-name-per-address, unbind and rebind.

## Run the site and relayer

```
cd relayer && npm i
CONTRACT=0x... RELAYER_PK=0x... PORT=8099 node server.js
```

The relayer serves `site/` and exposes `/id`, `/resolve`, `/agents`, `/bind`, `/health`.
