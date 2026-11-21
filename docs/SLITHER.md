# Slither (22 Nov 2026)

Ran `slither src --exclude-dependencies --filter-paths 'src/mocks'`. 30 findings. Nothing that required a code change for v0.

- **High (1), `arbitrary-send-erc20`:** `AaveV3UsdcAdapter.deposit` `transferFrom`s USDC from the vault. The `from` is the immutable vault, and the function is `onlyVault`. False positive.
- **Medium (6), `incorrect-equality`:** zero-checks on NAV / HWM / aToken balance (`== 0`). Intentional.
- **Medium (1), `reentrancy-no-eth`:** `rebalance` checkpoints the high-water mark after a strategy call. `nonReentrant` covers this.
- **Low / informational:** calls in a loop over the strategy list (v1 has one adapter), `block.timestamp` for agent expiry, aToken `POOL()` / `UNDERLYING_ASSET_ADDRESS()` naming (Aave's ABI).

Re-run after contract changes: `slither src --exclude-dependencies --filter-paths 'src/mocks'`.
