# Circuit Vault

A personal **USDC** vault. An authorized **agent** may **rebalance** only between cash and owner-whitelisted strategies (v1 is one **Aave V3 USDC supply** adapter), within **per-strategy allocation caps**. A hard on-chain **drawdown breaker** tracks a high-water mark: anyone may **trip()** when value falls at or past the owner's `maxDrawdownBps`, which pauses the agent and can **exit to USDC**. The owner can **deposit**, **withdraw**, **pause** and **revoke**.

> Prototype, **not audited**. It targets **Ethereum mainnet (1)** and **Base (8453)**, plus local anvil (31337) for development. The deploy scripts refuse any other chain and **refuse to broadcast on 1/8453 unless `CONFIRM_MAINNET=yes`**. Nothing has been deployed.

See [SPEC.md](SPEC.md) for the problem, choices and open questions, and [DEPLOY.md](DEPLOY.md) for the deploy runbook.

## Layout

| Path | What |
|---|---|
| `src/CircuitVault.sol` | The vault: deposit/withdraw, agent rebalance, caps, HWM breaker, pause, revoke |
| `src/CircuitVaultFactory.sol` | Deploys one vault per owner, wired to this chain's USDC, Aave V3 Pool and aUSDC |
| `src/AaveV3UsdcAdapter.sol` | Per-vault adapter that supplies USDC to the official Aave V3 Pool |
| `src/interfaces/` | `IStrategy`, minimal Aave V3 Pool / aToken interfaces |
| `src/mocks/` | MockUSDC, MockAavePool and MockStrategy for local tests only |
| `test/` | Unit, fuzz and invariant tests (Foundry) |
| `test/fork/` | Fork tests against the real Aave V3 Pool and Circle USDC, plus a fork test of `Deploy.s.sol` |
| `script/Deploy.s.sol`, `script/DeployConfig.sol` | Deploy script and per-chain official addresses |
| `script/deploy.sh`, `script/verify.sh`, `script/deploy-anvil.sh` | Dry-run/broadcast wrapper, Etherscan v2 verify, local deploy |
| `script/dry-run-fork.sh`, `script/write-web-config.sh` | Anvil-fork dry run (port 8629) and dapp-config writer |
| `web/` | Vite + React + wagmi/viem dapp (Ethereum, Base and anvil) |

## Contract model

- `deposit` / `withdraw` are owner only. Withdraw pulls from cash (exit strategies first if you need more). A cash withdraw reverts if it would push any allowed strategy over its cap.
- High-water mark: deposits add the amount; withdrawals scale it pro-rata; `checkpoint()` raises it when NAV has grown (interest).
- `grantAgent`, `setStrategy(strategy, allowed, capBps)`, `setMaxDrawdownBps` and `setAutoExitOnTrip` are owner only. Default cap for the v1 Aave adapter is 80%; default max drawdown is 10%.
- `rebalance(strategy, targetAssets)` is called by the agent. It moves only between cash and that strategy, reverts if paused, tripped, already past the drawdown limit, or over the cap.
- `trip()` can be called by anyone once drawdown is at or past the limit. It blocks the agent and, if `autoExitOnTrip` is set, unwinds every strategy to USDC.
- `revokeAgent` (owner or guardian) and `pause()` (owner or guardian); `unpause()` and `resetTrip()` are owner only. Withdraw and exit work while paused or tripped.
- Ownership uses `Ownable2Step`, so a Safe can be the owner.

## Run the dapp

```bash
cd web
npm install
# optional: cp .env.example .env   # only to override RPCs or factory addresses
npm run dev      # http://localhost:5173
npm run build    # production build
```

The dapp is Vite + React + wagmi/viem, on Ethereum mainnet and Base (and local anvil). Contract addresses come from `web/src/deployments.json`, with optional `VITE_FACTORY_*` overrides in `web/.env`. When the factory address for the selected chain is empty, the page shows a clear **Not deployed yet** state and disables create-vault.

Connect a wallet, switch network, then: create or pick a vault, deposit USDC, inspect allocations and drawdown, grant an agent, rebalance, trip, pause, or revoke.

## Tests

Needs Foundry (`forge` / `anvil`; this repo expects `~/.foundry/bin` on `PATH`) and Node 20+.

```bash
forge build
forge test              # unit, fuzz, invariant, and anvil deploy-script tests; fork tests skip without a fork
make dry-run-mainnet    # Deploy.s.sol dry-run + CONFIRM_MAINNET guard, on an anvil mainnet fork at port 8629
```

Fork tests (real Aave V3 Pool and Circle USDC, plus the deploy-script fork tests):

```bash
anvil --port 8629 --fork-url https://ethereum-rpc.publicnode.com   # Ethereum fork
make test-fork-mainnet
# Base, using Foundry's own fork (no extra anvil):
make test-fork-base
```

This worker uses **anvil port 8629 only**.

## Deploy to Ethereum or Base (not done: needs Lef's wallet and OK)

| Chain | Id | Aave V3 Pool | USDC | aUSDC |
|---|---|---|---|---|
| Ethereum mainnet | 1 | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | `0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c` |
| Base | 8453 | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB` |

Once the wallet is set (Foundry keystore account, keystore file, or `DEPLOYER_KEY` in a git-ignored `.env`):

```bash
cp .env.example .env && set -a && source .env && set +a
make dry-run-mainnet                 # local anvil fork on port 8629; sends nothing
CONFIRM_MAINNET=yes make deploy-mainnet
CONFIRM_MAINNET=yes make deploy-base
```

A successful broadcast writes addresses into `web/src/deployments.json` and, if `ETHERSCAN_API_KEY` is set, verifies via the Etherscan v2 API. See [DEPLOY.md](DEPLOY.md).

- `deploy.sh` and `Deploy.s.sol` both print the chain. Each refuses to broadcast on 1 or 8453 without `CONFIRM_MAINNET=yes`, so the guard holds even if someone calls `forge script` directly.
- Never commit `.env`, keys, or `broadcast/`.

## Local end-to-end (anvil, no keys)

```bash
anvil                                   # terminal 1 (chain 31337)
./script/deploy-anvil.sh                # factory + MockUSDC/AavePool on a fresh anvil
cd web && npm install && npm run dev
```

The anvil deploy uses anvil's unlocked dev accounts, so no private key is stored anywhere.

## Regenerate ABIs

`forge build && node tools/gen-abi.mjs` writes `web/src/abi.ts`.

## Contact

Support and questions: [lg.playstudio@gmail.com](mailto:lg.playstudio@gmail.com)
