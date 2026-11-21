// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CircuitVault} from "../../src/CircuitVault.sol";
import {CircuitVaultFactory} from "../../src/CircuitVaultFactory.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployConfig} from "../../script/DeployConfig.sol";
import {IPoolAddressesProvider, IAToken} from "../../src/interfaces/IAave.sol";

/// @dev Runs the production Deploy script against a live-chain fork (no broadcast to a real network).
abstract contract DeployForkBase is Test {
    bool active;

    function _rpcEnv() internal pure virtual returns (string memory);
    function _chainId() internal pure virtual returns (uint256);

    function setUp() public {
        if (block.chainid == _chainId()) {
            // already on this chain's fork
        } else if (block.chainid == 31337) {
            string memory rpc = vm.envOr(_rpcEnv(), string(""));
            if (bytes(rpc).length == 0) return;
            vm.createSelectFork(rpc);
        } else {
            return;
        }
        active = true;
        assertEq(block.chainid, _chainId(), "wrong fork chain");
    }

    modifier onFork() {
        if (!active) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_deployScript_factoryAndCanonicalAave() public onFork {
        Deploy script = new Deploy();
        (CircuitVaultFactory factory, address usdc, address pool, address aToken) = script.run();

        DeployConfig.Chain memory c = DeployConfig.get(block.chainid);
        assertTrue(address(factory).code.length > 0, "factory not deployed");
        assertEq(usdc, c.usdc, "must use canonical USDC");
        assertEq(pool, c.pool, "must use official Aave V3 Pool");
        assertEq(aToken, c.aToken, "must use official aUSDC");
        assertEq(IERC20Metadata(usdc).symbol(), "USDC");
        assertEq(IERC20Metadata(usdc).decimals(), 6);
        assertEq(IPoolAddressesProvider(c.poolAddressesProvider).getPool(), pool);
        assertEq(IAToken(aToken).UNDERLYING_ASSET_ADDRESS(), usdc);
        assertEq(IAToken(aToken).POOL(), pool);

        address user = makeAddr("vault-owner");
        vm.prank(user);
        address vault = factory.createVault();
        assertTrue(vault.code.length > 0, "vault not created");
        assertEq(CircuitVault(vault).owner(), user);
        assertEq(CircuitVault(vault).usdc(), usdc);
        assertEq(CircuitVault(vault).maxDrawdownBps(), 1000);
        assertTrue(CircuitVault(vault).aaveStrategy().code.length > 0);
        address[] memory list = factory.vaultsOf(user);
        assertEq(list.length, 1);
        assertEq(list[0], vault);
    }

    function test_fork_deployScript_confirmMainnetNotSetIsDryRunSafe() public onFork {
        vm.setEnv("CONFIRM_MAINNET", "");
        Deploy script = new Deploy();
        (CircuitVaultFactory factory,,,) = script.run();
        assertTrue(address(factory).code.length > 0);
    }
}

contract EthereumDeployForkTest is DeployForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "MAINNET_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 1;
    }
}

contract BaseDeployForkTest is DeployForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }
}
