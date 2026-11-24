import { useState } from "react";
import { useAccount, useChainId, useReadContract } from "wagmi";
import { erc20Abi, formatUnits, isAddress, parseUnits, type Address } from "viem";
import { circuitVaultAbi, circuitVaultFactoryAbi } from "./abi";
import { deployments } from "./config";
import { Addr, Empty, Hint, Loading, Shell, short, useTx } from "./ui";

const fmtUsdc = (v?: bigint) => (v === undefined ? "…" : Number(formatUnits(v, 6)).toLocaleString(undefined, { maximumFractionDigits: 2 }));
const fmtBps = (v?: bigint | number) => {
  if (v === undefined) return "…";
  const n = Number(v) / 100;
  return `${n.toFixed(2)}%`;
};

export default function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const dep = deployments[chainId] ?? {};
  const [vault, setVault] = useState<Address | "">("");

  return (
    <Shell
      title="Circuit Vault"
      tagline="A personal USDC vault with a circuit breaker. Your AI agent can only move funds between cash and strategies you whitelist (v1: Aave V3 USDC supply), within caps you set. If the vault falls a set percentage below its peak, anyone can trip the breaker and the agent is blocked."
      steps={[
        "Create a vault you own and deposit USDC.",
        "Set the Aave cap and the maximum drawdown, then grant an agent key with an expiry.",
        "The agent rebalances between cash and Aave inside those limits. It can never withdraw.",
        "Breaker trips at your drawdown limit. Only you can withdraw, reset or unpause.",
      ]}
      contractLabel="Vault factory"
      contractOf={(id) => deployments[id]?.factory}
      refs={[
        { label: "USDC", address: dep.usdc },
        { label: "Aave V3 pool", address: dep.pool },
        { label: "Aave aUSDC", address: dep.aToken },
      ]}
      risk={
        <>
          <strong>Real funds.</strong> This contract is not audited. USDC supplied to Aave carries Aave's own risks, and
          the breaker limits losses only after someone trips it. Only deposit amounts you can afford to lose.
        </>
      }
    >
      {!isConnected && <Empty>Connect a wallet to create a vault or manage one you already own.</Empty>}

      {isConnected && address && (
        <>
          <VaultPicker owner={address} factory={dep.factory} vault={vault} setVault={setVault} />
          {vault && isAddress(vault) && (
            <>
              <Overview vault={vault} usdc={dep.usdc} />
              <Allocations vault={vault} />
              <Drawdown vault={vault} />
              <OwnerControls vault={vault} usdc={dep.usdc} />
              <AgentRebalance vault={vault} />
            </>
          )}
        </>
      )}
    </Shell>
  );
}

function VaultPicker(props: {
  owner: Address;
  factory?: Address;
  vault: string;
  setVault: (v: Address | "") => void;
}) {
  const { owner, factory, vault, setVault } = props;
  const { data: vaults, refetch, isLoading } = useReadContract({
    address: factory,
    abi: circuitVaultFactoryAbi,
    functionName: "vaultsOf",
    args: [owner],
    query: { enabled: !!factory },
  });
  const { writeContractAsync, status, run, safe } = useTx();
  return (
    <div className="card">
      <h2>1. Choose a vault</h2>
      <p className="muted">A vault is your own contract. It holds the USDC and enforces the agent limits.</p>
      <div className="field-label">Your vaults on this network</div>
      {!factory ? (
        <Empty>No factory on this network, so vaults cannot be listed or created here.</Empty>
      ) : isLoading ? (
        <Loading>Looking up your vaults…</Loading>
      ) : vaults && vaults.length > 0 ? (
        <div className="row">
          {vaults.map((v) => (
            <button key={v} className={v === vault ? "seg seg-on" : "seg"} aria-pressed={v === vault} onClick={() => setVault(v)}>
              <code>{short(v)}</code>
              <span className="seg-sub">{v === vault ? "selected" : "select"}</span>
            </button>
          ))}
        </div>
      ) : (
        <Empty>This wallet has no vaults yet. Create one below, or paste the address of a vault you want to inspect.</Empty>
      )}
      <div className="row">
        <button
          disabled={!factory}
          onClick={safe(async () => {
            const ok = await run("Create vault", () =>
              writeContractAsync({ address: factory!, abi: circuitVaultFactoryAbi, functionName: "createVault" }),
            );
            if (ok) {
              const list = (await refetch()).data ?? [];
              if (list.length) setVault(list[list.length - 1]);
            }
          })}
        >
          Create new vault
        </button>
        <label>
          Or open a vault by address
          <input value={vault} placeholder="0x…" spellCheck={false} onChange={(e) => setVault(e.target.value.trim() as Address)} />
        </label>
      </div>
      {vault && !isAddress(vault) && <div className="bad muted">That is not a valid address (0x followed by 40 hex characters).</div>}
      <Hint>
        “Create new vault” deploys a vault contract owned by your connected wallet. One transaction, gas only — no
        funds move.
      </Hint>
      {status}
    </div>
  );
}

function Overview({ vault, usdc }: { vault: Address; usdc?: Address }) {
  const { data: total } = useReadContract({ address: vault, abi: circuitVaultAbi, functionName: "totalValue" });
  const { data: cash } = useReadContract({ address: vault, abi: circuitVaultAbi, functionName: "cash" });
  const { data: owner } = useReadContract({ address: vault, abi: circuitVaultAbi, functionName: "owner" });
  const { data: aave } = useReadContract({ address: vault, abi: circuitVaultAbi, functionName: "aaveStrategy" });
  const { data: paused } = useReadContract({ address: vault, abi: circuitVaultAbi, functionName: "paused" });
  const { address: me } = useAccount();
  const isMe = !!me && !!owner && me.toLowerCase() === owner.toLowerCase();
  return (
    <div className="card">
      <h2>2. Overview</h2>
      <table>
        <tbody>
          <tr>
            <th>Vault</th>
            <td>
              <Addr value={vault} full />
            </td>
          </tr>
          <tr>
            <th>Owner</th>
            <td>
              <Addr value={owner} /> {isMe && <span className="ok">(you)</span>}
            </td>
          </tr>
          <tr>
            <th>Total value</th>
            <td>{fmtUsdc(total)} USDC</td>
          </tr>
          <tr>
            <th>Cash</th>
            <td>{fmtUsdc(cash)} USDC</td>
          </tr>
          <tr>
            <th>Aave adapter</th>
            <td>
              <Addr value={aave} />
            </td>
          </tr>
          <tr>
            <th>USDC</th>
            <td>
              <Addr value={usdc} />
            </td>
          </tr>
          <tr>
            <th>Agent rebalancing</th>
            <td className={paused ? "bad" : "ok"}>{paused === undefined ? "…" : paused ? "Paused" : "Active"}</td>
          </tr>
        </tbody>
      </table>
      {owner === undefined && total === undefined && (
        <p className="muted">If these stay empty, this address is not a Circuit Vault on this network.</p>
      )}
    </div>
  );
}

function Allocations({ vault }: { vault: Address }) {
  const { data: aave } = useReadContract({ address: vault, abi: circuitVaultAbi, functionName: "aaveStrategy" });
  const { data: cash } = useReadContract({ address: vault, abi: circuitVaultAbi, functionName: "cash" });
  const { data: total } = useReadContract({ address: vault, abi: circuitVaultAbi, functionName: "totalValue" });
  const { data: held } = useReadContract({
    address: vault,
    abi: circuitVaultAbi,
    functionName: "strategyAssets",
    args: aave ? [aave] : undefined,
    query: { enabled: !!aave },
  });
  const { data: cfg } = useReadContract({
    address: vault,
    abi: circuitVaultAbi,
    functionName: "strategies",
    args: aave ? [aave] : undefined,
    query: { enabled: !!aave },
  });
  const { data: alloc } = useReadContract({
    address: vault,
    abi: circuitVaultAbi,
    functionName: "allocationBps",
    args: aave ? [aave] : undefined,
    query: { enabled: !!aave },
  });
  const capBps = cfg?.[1];
  return (
    <div className="card">
      <h2>3. Allocations</h2>
      <table>
        <thead>
          <tr>
            <th>Sleeve</th>
            <th>USDC</th>
            <th>Share</th>
            <th>Cap</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>Cash</td>
            <td>{fmtUsdc(cash)}</td>
            <td>{total && total > 0n && cash !== undefined ? fmtBps((cash * 10_000n) / total) : "…"}</td>
            <td>—</td>
          </tr>
          <tr>
            <td>Aave V3 USDC</td>
            <td>{fmtUsdc(held)}</td>
            <td>{fmtBps(alloc)}</td>
            <td>{capBps !== undefined ? fmtBps(capBps) : "…"} {cfg?.[0] === false ? "(disabled)" : ""}</td>
          </tr>
        </tbody>
      </table>
    </div>
  );
}

function Drawdown({ vault }: { vault: Address }) {
  const { data: hwm } = useReadContract({ address: vault, abi: circuitVaultAbi, functionName: "highWaterMark" });
  const { data: maxDd } = useReadContract({ address: vault, abi: circuitVaultAbi, functionName: "maxDrawdownBps" });
  const { data: dd } = useReadContract({ address: vault, abi: circuitVaultAbi, functionName: "drawdownBps" });
  const { data: canTrip } = useReadContract({ address: vault, abi: circuitVaultAbi, functionName: "canTrip" });
  const { data: tripped } = useReadContract({ address: vault, abi: circuitVaultAbi, functionName: "tripped" });
  const { data: autoExit } = useReadContract({ address: vault, abi: circuitVaultAbi, functionName: "autoExitOnTrip" });
  const { writeContractAsync, status, run, safe } = useTx();
  const breached = !!tripped || !!canTrip;
  return (
    <div className="card">
      <h2>4. Drawdown breaker</h2>
      <table>
        <tbody>
          <tr>
            <th>High-water mark</th>
            <td>{fmtUsdc(hwm)} USDC</td>
          </tr>
          <tr>
            <th>Current drawdown</th>
            <td className={breached ? "bad" : "ok"}>{fmtBps(dd)}</td>
          </tr>
          <tr>
            <th>Trip at</th>
            <td>{fmtBps(maxDd)}</td>
          </tr>
          <tr>
            <th>Status</th>
            <td className={tripped ? "bad" : canTrip ? "bad" : "ok"}>
              {tripped ? "TRIPPED — agent blocked" : canTrip ? "Limit hit — anyone may trip" : "Armed"}
            </td>
          </tr>
          <tr>
            <th>Auto-exit on trip</th>
            <td>{autoExit ? "yes (unwind to USDC)" : "no (flag only)"}</td>
          </tr>
        </tbody>
      </table>
      <div className="row">
        <button
          className="danger"
          disabled={!canTrip}
          onClick={() => run("Trip", () => writeContractAsync({ address: vault, abi: circuitVaultAbi, functionName: "trip" }))}
        >
          Trip breaker
        </button>
        <button
          className="ghost"
          onClick={() =>
            run("Checkpoint HWM", () => writeContractAsync({ address: vault, abi: circuitVaultAbi, functionName: "checkpoint" }))
          }
        >
          Checkpoint HWM
        </button>
      </div>
      <Hint>
        “Trip breaker” can be pressed by anyone once drawdown reaches the limit: it blocks the agent
        {autoExit ? " and unwinds every strategy back to USDC inside the vault" : " (funds stay where they are)"}. No
        funds leave the vault. “Checkpoint HWM” raises the high-water mark to the current value if it has grown; it
        never lowers it.
      </Hint>
      {status}
    </div>
  );
}

function OwnerControls({ vault, usdc }: { vault: Address; usdc?: Address }) {
  const { address } = useAccount();
  const { data: owner } = useReadContract({ address: vault, abi: circuitVaultAbi, functionName: "owner" });
  const { data: aave } = useReadContract({ address: vault, abi: circuitVaultAbi, functionName: "aaveStrategy" });
  const { writeContractAsync, status, run, safe, fail } = useTx();
  const [amount, setAmount] = useState("1000");
  const [agent, setAgent] = useState("");
  const [days, setDays] = useState("30");
  const [cap, setCap] = useState("80");
  const [dd, setDd] = useState("10");
  const isOwner = !!address && !!owner && address.toLowerCase() === owner.toLowerCase();
  const units = () => parseUnits(amount || "0", 6);

  if (!isOwner) {
    return (
      <div className="card">
        <h2>5. Owner controls</h2>
        <Empty>
          Only the vault owner (<Addr value={owner} copy={false} />) can deposit, withdraw, grant agents or reset the
          breaker. Connect that wallet to use these controls.
        </Empty>
      </div>
    );
  }

  return (
    <div className="card">
      <h2>5. Owner controls</h2>
      <h3>Deposit and withdraw</h3>
      <div className="row">
        <label>
          Amount (USDC)
          <input value={amount} inputMode="decimal" onChange={(e) => setAmount(e.target.value)} />
        </label>
        <button
          disabled={!usdc}
          onClick={safe(async () => {
            const ok = await run("Approve USDC", () =>
              writeContractAsync({ address: usdc!, abi: erc20Abi, functionName: "approve", args: [vault, units()] }),
            );
            if (ok) {
              await run("Deposit", () =>
                writeContractAsync({ address: vault, abi: circuitVaultAbi, functionName: "deposit", args: [units()] }),
              );
            }
          })}
        >
          Approve + deposit
        </button>
        <button
          onClick={() =>
            run("Withdraw", () =>
              writeContractAsync({
                address: vault,
                abi: circuitVaultAbi,
                functionName: "withdraw",
                args: [address!, units()],
              }),
            )
          }
        >
          Withdraw cash
        </button>
      </div>
      <Hint>
        Deposit asks twice: an approval for exactly this amount, then the deposit, which moves the USDC from your
        wallet into the vault as cash. Withdraw sends that amount of the vault's cash back to your connected wallet;
        to withdraw funds that are in Aave, use “Exit all to cash” first.
      </Hint>
      <h3>Agent key</h3>
      <div className="row">
        <label>
          Agent address
          <input value={agent} spellCheck={false} onChange={(e) => setAgent(e.target.value.trim())} placeholder="0x…" />
        </label>
        <label>
          Expiry (days)
          <input value={days} onChange={(e) => setDays(e.target.value)} />
        </label>
        <button
          disabled={!isAddress(agent)}
          onClick={safe(() => {
            const d = Number(days);
            if (!Number.isFinite(d) || d <= 0) return fail("Expiry must be a number of days greater than 0.");
            const expiry = BigInt(Math.floor(Date.now() / 1000 + d * 86400));
            return run("Grant agent", () =>
              writeContractAsync({
                address: vault,
                abi: circuitVaultAbi,
                functionName: "grantAgent",
                args: [agent as Address, expiry],
              }),
            );
          })}
        >
          Grant agent
        </button>
        <button
          className="danger"
          disabled={!isAddress(agent)}
          onClick={() =>
            run("Revoke agent", () =>
              writeContractAsync({
                address: vault,
                abi: circuitVaultAbi,
                functionName: "revokeAgent",
                args: [agent as Address],
              }),
            )
          }
        >
          Revoke agent
        </button>
      </div>
      <Hint>
        Grant lets that address rebalance between cash and whitelisted strategies until the expiry. It cannot
        withdraw or send funds anywhere else. Revoke removes the key immediately.
      </Hint>
      <h3>Limits</h3>
      <div className="row">
        <label>
          Aave cap (%)
          <input value={cap} onChange={(e) => setCap(e.target.value)} />
        </label>
        <button
          disabled={!aave}
          onClick={() =>
            run("Set Aave cap", () =>
              writeContractAsync({
                address: vault,
                abi: circuitVaultAbi,
                functionName: "setStrategy",
                args: [aave!, true, Number(cap) * 100],
              }),
            )
          }
        >
          Set cap
        </button>
        <label>
          Max drawdown (%)
          <input value={dd} onChange={(e) => setDd(e.target.value)} />
        </label>
        <button
          onClick={() =>
            run("Set max drawdown", () =>
              writeContractAsync({
                address: vault,
                abi: circuitVaultAbi,
                functionName: "setMaxDrawdownBps",
                args: [Number(dd) * 100],
              }),
            )
          }
        >
          Set limit
        </button>
      </div>
      <Hint>
        The Aave cap is the largest share of the vault the agent may place in Aave. Max drawdown is how far the vault
        may fall below its high-water mark before the breaker can be tripped.
      </Hint>
      <h3>Emergency</h3>
      <div className="row">
        <button className="danger" onClick={() => run("Pause", () => writeContractAsync({ address: vault, abi: circuitVaultAbi, functionName: "pause" }))}>
          Pause
        </button>
        <button
          className="ghost"
          onClick={() => run("Unpause", () => writeContractAsync({ address: vault, abi: circuitVaultAbi, functionName: "unpause" }))}
        >
          Unpause
        </button>
        <button
          className="ghost"
          onClick={() =>
            run("Exit all strategies", () =>
              writeContractAsync({ address: vault, abi: circuitVaultAbi, functionName: "exitAll" }),
            )
          }
        >
          Exit all to cash
        </button>
        <button
          className="ghost"
          onClick={() =>
            run("Reset breaker", () =>
              writeContractAsync({ address: vault, abi: circuitVaultAbi, functionName: "resetTrip" }),
            )
          }
        >
          Reset breaker
        </button>
      </div>
      <Hint tone="danger">
        Pause blocks agent rebalancing at once; you can still withdraw. “Exit all to cash” pulls everything out of
        Aave back into the vault. “Reset breaker” clears a trip and re-arms it at the current value; it does not
        unpause.
      </Hint>
      {status}
    </div>
  );
}

function AgentRebalance({ vault }: { vault: Address }) {
  const { data: aave } = useReadContract({ address: vault, abi: circuitVaultAbi, functionName: "aaveStrategy" });
  const { writeContractAsync, status, run, safe } = useTx();
  const [target, setTarget] = useState("0");
  return (
    <div className="card">
      <h2>6. Agent rebalance</h2>
      <p className="muted">For the granted agent key. Other wallets are rejected.</p>
      <div className="row">
        <label>
          Target in Aave (USDC)
          <input value={target} onChange={(e) => setTarget(e.target.value)} />
        </label>
        <button
          disabled={!aave}
          onClick={() =>
            run("Rebalance", () =>
              writeContractAsync({
                address: vault,
                abi: circuitVaultAbi,
                functionName: "rebalance",
                args: [aave!, parseUnits(target || "0", 6)],
              }),
            )
          }
        >
          Rebalance
        </button>
      </div>
      <Hint>
        Moves USDC between the vault's cash and Aave until Aave holds the target amount. Funds never leave the vault.
        Rejected if the vault is paused, tripped, past its drawdown limit, or the target exceeds the Aave cap.
      </Hint>
      {status}
    </div>
  );
}
