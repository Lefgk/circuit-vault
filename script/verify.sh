#!/usr/bin/env bash
# Verify deployed contracts on Etherscan v2 (one API key works for Ethereum 1 and Base 8453).
#   ./script/verify.sh factory <factoryAddress>
#   ./script/verify.sh vault   <vaultAddress> <ownerAddress>
# Env: RPC_URL (to detect chain), ETHERSCAN_API_KEY. Key is never echoed.
# Constructor args for the factory are taken from this chain's DeployConfig addresses.
# The vault constructor also deploys AaveV3UsdcAdapter; verify the adapter separately if needed
# with `forge verify-contract` using vault, usdc, pool, aToken as its constructor args.
set -euo pipefail
export PATH="${HOME}/.foundry/bin:${PATH}"
: "${RPC_URL:?set RPC_URL}"
: "${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY (Etherscan v2 key)}"
KIND=${1:?factory|vault}; ADDR=${2:?address}
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
case "$CHAIN_ID" in
  1)
    echo "==> Chain: Ethereum mainnet (1)"
    USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    POOL=0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2
    ATOKEN=0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c
    ;;
  8453)
    echo "==> Chain: Base (8453)"
    USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
    POOL=0xA238Dd80C259a72e81d7e4664a9801593F98d1c5
    ATOKEN=0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB
    ;;
  *) echo "Unsupported chain $CHAIN_ID" >&2; exit 1;;
esac
COMMON=(--chain "$CHAIN_ID" --watch --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=$CHAIN_ID")
DEFAULT_DD=1000
DEFAULT_CAP=8000
case "$KIND" in
  factory)
    forge verify-contract "$ADDR" src/CircuitVaultFactory.sol:CircuitVaultFactory "${COMMON[@]}" \
      --constructor-args "$(cast abi-encode 'constructor(address,address,address)' "$USDC" "$POOL" "$ATOKEN")"
    ;;
  vault)
    OWNER=${3:?owner address}
    forge verify-contract "$ADDR" src/CircuitVault.sol:CircuitVault "${COMMON[@]}" \
      --constructor-args "$(cast abi-encode 'constructor(address,address,address,address,uint16,uint16)' "$OWNER" "$USDC" "$POOL" "$ATOKEN" "$DEFAULT_DD" "$DEFAULT_CAP")"
    ;;
  *) echo "first arg must be factory or vault" >&2; exit 1 ;;
esac
