# Deploy Circuit Vault (Ethereum mainnet or Base)

Prototype, **not audited**. Nothing has been broadcast. Live deploys need Lef's wallet and an explicit OK. This runbook never prints keys.

## What is deployed

One `CircuitVaultFactory`, wired to this chain's official Circle USDC, Aave V3 Pool and aUSDC token. Users then call `createVault()` (the caller becomes the vault owner; the vault deploys its own Aave V3 USDC adapter). The factory deploy is the only step this script performs on a live chain.

Official addresses (also in `script/DeployConfig.sol`):

| Chain | Id | Pool | USDC | aUSDC |
|---|---|---|---|---|
| Ethereum mainnet | 1 | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | `0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c` |
| Base | 8453 | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB` |

The script checks USDC metadata, `PoolAddressesProvider.getPool()`, and that aUSDC's `UNDERLYING_ASSET_ADDRESS` and `POOL()` match those addresses before doing anything on a live chain. Any other chain is refused. Local anvil (31337) deploys mocks instead.

## Prerequisites

- Foundry (`forge`, `cast`, `anvil`) on `PATH` (this repo expects `~/.foundry/bin`)
- An Ethereum or Base RPC (`MAINNET_RPC_URL` / `BASE_RPC_URL`, or `RPC_URL`)
- For a live broadcast only: a deployer with ETH, as a Foundry keystore account (`DEPLOYER_ACCOUNT`), a keystore file (`DEPLOYER_KEYSTORE`), or `DEPLOYER_KEY` in a git-ignored `.env`
- Optional: `ETHERSCAN_API_KEY` (Etherscan v2, one key covers both chains)

Copy `.env.example` to `.env` and fill only what you need. Never commit `.env` or keystores.

## Dry run (sends nothing)

```bash
make deploy-mainnet-dry
make deploy-base-dry
make dry-run-mainnet          # local anvil fork on port 8629; also checks the CONFIRM_MAINNET guard
# or:  RPC_URL=<rpc> ./script/deploy.sh
```

## Live deploy (real ETH)

Both the shell wrapper and `Deploy.s.sol` refuse unless `CONFIRM_MAINNET` is exactly `yes`:

```bash
CONFIRM_MAINNET=yes make deploy-mainnet
CONFIRM_MAINNET=yes make deploy-base
# or:  CONFIRM_MAINNET=yes RPC_URL=<rpc> ./script/deploy.sh --broadcast
```

If `ETHERSCAN_API_KEY` is set, the broadcast also verifies through the Etherscan v2 API (`foundry.toml` `[etherscan]` entries for chainid 1 and 8453). You can verify later with:

```bash
RPC_URL=<rpc> ./script/verify.sh factory <factoryAddress>
RPC_URL=<rpc> ./script/verify.sh vault <vaultAddress> <ownerAddress>
```

A successful broadcast writes the factory, USDC, Pool and aToken addresses into `web/src/deployments.json` (override the path with `DEPLOYMENTS_PATH`). The dapp reads that file; `VITE_FACTORY_*` in `web/.env` can still override it.

## Local anvil (no keys, no funds)

```bash
anvil                                 # terminal 1, chain 31337
./script/deploy-anvil.sh              # uses anvil's unlocked dev account #0
cd web && npm install && npm run dev  # http://localhost:5173
```

## Safety

- `CONFIRM_MAINNET=yes` is required for any broadcast on chain 1 or 8453, even if someone calls `forge script --broadcast` directly.
- The contracts are a prototype and **not audited**. Do not deposit funds you cannot afford to lose.
- Never commit `.env`, keystores, or `broadcast/` (they are git-ignored).
