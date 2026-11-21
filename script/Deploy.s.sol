// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {CircuitVaultFactory} from "../src/CircuitVaultFactory.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockAavePool, MockAToken} from "../src/mocks/MockAavePool.sol";
import {DeployConfig} from "./DeployConfig.sol";
import {IPoolAddressesProvider, IAToken} from "../src/interfaces/IAave.sol";

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @notice Deploys CircuitVaultFactory on Ethereum mainnet (1), Base (8453) or local anvil (31337).
///         - Prints the chain it is on.
///         - Checks canonical USDC, official Aave V3 Pool (via PoolAddressesProvider) and aUSDC
///           before doing anything on a live chain.
///         - REFUSES to broadcast on chain 1 / 8453 unless env CONFIRM_MAINNET=yes.
///         - On a live broadcast, writes factory / USDC / pool / aToken into web/src/deployments.json.
///         Dry run (no --broadcast) is always allowed and prints gas estimates.
///         On local anvil, deploys MockUSDC, a MockAavePool (with seed liquidity) and the factory.
contract Deploy is Script {
    string internal constant DEPLOYMENTS_PATH = "web/src/deployments.json";

    function run()
        external
        returns (CircuitVaultFactory factory, address usdc, address pool, address aToken)
    {
        DeployConfig.Chain memory c = DeployConfig.get(block.chainid);
        console2.log("==> Chain:", c.name);
        console2.log("    chainId:", block.chainid);

        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (c.isMainnet) {
            _checkLive(c);
            if (broadcasting) {
                require(
                    keccak256(bytes(vm.envOr("CONFIRM_MAINNET", string("")))) == keccak256("yes"),
                    "Deploy: refusing to broadcast on a live chain without CONFIRM_MAINNET=yes"
                );
                console2.log("    CONFIRM_MAINNET=yes - LIVE BROADCAST");
            } else {
                console2.log("    dry run (no --broadcast): nothing will be sent");
            }
        }

        vm.startBroadcast();
        if (c.isMainnet) {
            usdc = c.usdc;
            pool = c.pool;
            aToken = c.aToken;
            factory = new CircuitVaultFactory(c.usdc, c.pool, c.aToken);
        } else {
            MockUSDC musdc = new MockUSDC();
            MockAToken ma = new MockAToken(address(musdc));
            MockAavePool mpool = new MockAavePool(address(musdc), address(ma));
            ma.setPool(address(mpool));
            musdc.mint(address(mpool), 10_000_000e6);
            usdc = address(musdc);
            pool = address(mpool);
            aToken = address(ma);
            factory = new CircuitVaultFactory(usdc, pool, aToken);
        }
        vm.stopBroadcast();

        console2.log("CircuitVaultFactory", address(factory));
        console2.log("USDC", usdc);
        console2.log("Pool", pool);
        console2.log("aToken", aToken);

        if (broadcasting) {
            _writeWebConfig(address(factory), usdc, pool, aToken);
        }
    }

    function _checkLive(DeployConfig.Chain memory c) internal view {
        require(c.usdc.code.length > 0, "Deploy: USDC has no code on this chain");
        require(keccak256(bytes(IERC20Meta(c.usdc).symbol())) == keccak256("USDC"), "Deploy: USDC symbol mismatch");
        require(IERC20Meta(c.usdc).decimals() == 6, "Deploy: USDC decimals mismatch");
        console2.log("    USDC verified (symbol USDC, 6 decimals):", c.usdc);

        require(c.pool.code.length > 0, "Deploy: Aave V3 Pool has no code on this chain");
        require(c.poolAddressesProvider.code.length > 0, "Deploy: PoolAddressesProvider has no code");
        address fromProvider = IPoolAddressesProvider(c.poolAddressesProvider).getPool();
        require(fromProvider == c.pool, "Deploy: PoolAddressesProvider.getPool() mismatch");
        console2.log("    Aave V3 Pool verified via provider:", c.pool);

        require(c.aToken.code.length > 0, "Deploy: aUSDC has no code on this chain");
        require(IAToken(c.aToken).UNDERLYING_ASSET_ADDRESS() == c.usdc, "Deploy: aToken underlying != USDC");
        require(IAToken(c.aToken).POOL() == c.pool, "Deploy: aToken POOL() != official Pool");
        console2.log("    aUSDC verified (underlying USDC, official Pool):", c.aToken);
    }

    function _writeWebConfig(address factory, address usdc, address pool, address aToken) internal {
        string memory path = vm.envOr("DEPLOYMENTS_PATH", DEPLOYMENTS_PATH);
        if (!vm.exists(path)) {
            console2.log("    skip writing dapp config: file not found:", path);
            return;
        }
        string memory key = string.concat(".", vm.toString(block.chainid));
        string memory obj = "dep";
        vm.serializeAddress(obj, "factory", factory);
        vm.serializeAddress(obj, "usdc", usdc);
        vm.serializeAddress(obj, "pool", pool);
        string memory json = vm.serializeAddress(obj, "aToken", aToken);
        vm.writeJson(json, path, key);
        console2.log("    wrote factory + USDC + pool + aToken to", path);
    }
}
