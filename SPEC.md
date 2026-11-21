# Circuit Vault — spec (prototype, 22 Nov 2026)

Source: overnight agent-DeFi research (`agents-trading.md`, idea 3). Shared “AI vaults” collapsed; the gap is owner-enforced guardrails on a personal agent, like Agent Spend Controls.

**Problem.** An owner who wants an AI agent to move USDC between cash and a yield venue has no on-chain way to cap that allocation or stop the agent on a drawdown.

**Users.** Builders running a personal yield agent who fund the vault themselves and want a kill switch the agent cannot override.

**Scope (v0, Ethereum mainnet and Base, after an audit and Lef's OK).** One vault per owner (EOA or Safe). The owner deposits and withdraws USDC. v1 ships one strategy: an Aave V3 USDC supply adapter, checked against the official Pool on each chain. The owner sets the whitelist and a per-strategy cap (default 80%). `rebalance` only moves between cash and allowed strategies. A high-water mark tracks peak NAV; deposits raise it by the amount in, withdrawals scale it pro-rata. Anyone may `trip()` when drawdown is at or past `maxDrawdownBps` (default 10%). That blocks the agent and, if `autoExitOnTrip` is on (default), unwinds to USDC. The agent is also blocked as soon as the limit is hit. The owner (or a guardian) can pause, revoke, exit and reset the breaker. Withdraw and exit work while paused or tripped. The dapp shows allocations, drawdown, trip and owner controls, plus a **Not deployed yet** state. Out of v0: Morpho, WETH, public ERC-4626 shares, fees, multi-venue rotation.

**Choices for Lef to review.** Default max drawdown 10%, Aave cap 80%, auto-exit on. Caps also enforced on cash withdrawals. No fee. Standalone vault + factory, not a Safe module. Base first for cheaper gas.

**Competitors.** Almanak, Giza (retired), Theoriq, Sommelier, Brahma Console (sunset).

**Edge.** On-chain caps and a breaker anyone can trip; the agent cannot send funds outside the vault and its strategies.

**Open questions.** Audit before a live deploy? Owner wallet or Safe? First chain (recommend Base)? Keep these defaults?
