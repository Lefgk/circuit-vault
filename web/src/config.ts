import { http, createConfig } from "wagmi";
import { mainnet, base, foundry } from "wagmi/chains";
import { injected } from "wagmi/connectors";
import type { Address } from "viem";
import deploymentsFile from "./deployments.json";

const env = import.meta.env;

export const config = createConfig({
  chains: [base, mainnet, foundry],
  connectors: [injected()],
  transports: {
    [mainnet.id]: http(env.VITE_MAINNET_RPC || undefined),
    [base.id]: http(env.VITE_BASE_RPC || undefined),
    [foundry.id]: http(env.VITE_ANVIL_RPC || "http://127.0.0.1:8545"),
  },
});

const asAddr = (v?: string) => (v && /^0x[0-9a-fA-F]{40}$/.test(v) ? (v as Address) : undefined);

type DeploymentRow = { factory?: string; usdc?: string; pool?: string; aToken?: string };
const file = deploymentsFile as Record<string, DeploymentRow>;
const fromFile = (chainId: number) => {
  const row = file[String(chainId)] ?? {};
  return {
    factory: asAddr(row.factory),
    usdc: asAddr(row.usdc),
    pool: asAddr(row.pool),
    aToken: asAddr(row.aToken),
  };
};

/** Per-chain deployment addresses. Env vars override deployments.json. Empty factory = not deployed yet. */
export const deployments: Record<
  number,
  { factory?: Address; usdc?: Address; pool?: Address; aToken?: Address; live: boolean }
> = {
  [mainnet.id]: {
    factory: asAddr(env.VITE_FACTORY_MAINNET) ?? fromFile(mainnet.id).factory,
    usdc: fromFile(mainnet.id).usdc ?? "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    pool: fromFile(mainnet.id).pool ?? "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
    aToken: fromFile(mainnet.id).aToken ?? "0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c",
    live: true,
  },
  [base.id]: {
    factory: asAddr(env.VITE_FACTORY_BASE) ?? fromFile(base.id).factory,
    usdc: fromFile(base.id).usdc ?? "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    pool: fromFile(base.id).pool ?? "0xA238Dd80C259a72e81d7e4664a9801593F98d1c5",
    aToken: fromFile(base.id).aToken ?? "0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB",
    live: true,
  },
  [foundry.id]: {
    factory: asAddr(env.VITE_FACTORY_ANVIL) ?? fromFile(foundry.id).factory,
    usdc: asAddr(env.VITE_USDC_ANVIL) ?? fromFile(foundry.id).usdc,
    pool: asAddr(env.VITE_POOL_ANVIL) ?? fromFile(foundry.id).pool,
    aToken: asAddr(env.VITE_ATOKEN_ANVIL) ?? fromFile(foundry.id).aToken,
    live: false,
  },
};

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
