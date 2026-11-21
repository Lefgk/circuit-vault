// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CircuitVault} from "../src/CircuitVault.sol";
import {CircuitVaultFactory} from "../src/CircuitVaultFactory.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {DeployConfig} from "../script/DeployConfig.sol";

contract DeployTest is Test {
    function test_officialAddresses() public pure {
        DeployConfig.Chain memory e = DeployConfig.get(1);
        assertEq(e.usdc, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        assertEq(e.pool, 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
        assertEq(e.poolAddressesProvider, 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e);
        assertEq(e.aToken, 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c);
        assertTrue(e.isMainnet);
        DeployConfig.Chain memory b = DeployConfig.get(8453);
        assertEq(b.usdc, 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        assertEq(b.pool, 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5);
        assertEq(b.poolAddressesProvider, 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D);
        assertEq(b.aToken, 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB);
        assertTrue(b.isMainnet);
    }

    function test_anvilConfigIsNotMainnet() public pure {
        DeployConfig.Chain memory c = DeployConfig.get(31337);
        assertEq(c.usdc, address(0));
        assertFalse(c.isMainnet);
    }

    function test_unsupportedChainReverts() public {
        vm.chainId(11155111); // Sepolia is not a supported target
        Deploy script = new Deploy();
        vm.expectRevert(bytes("DeployConfig: unsupported chain (only 1, 8453, 31337)"));
        script.run();
    }

    function test_deployScriptOnAnvilDeploysFactoryAndMocks() public {
        if (block.chainid != 31337) {
            vm.skip(true);
            return;
        }
        Deploy script = new Deploy();
        (CircuitVaultFactory factory, address usdc, address pool, address aToken) = script.run();
        assertTrue(address(factory).code.length > 0);
        assertTrue(usdc.code.length > 0);
        assertTrue(pool.code.length > 0);
        assertTrue(aToken.code.length > 0);
        assertEq(factory.pool(), pool);
        assertEq(factory.usdc(), usdc);
        assertEq(factory.aToken(), aToken);
        address vault = factory.createVault();
        assertTrue(vault.code.length > 0);
        assertEq(CircuitVault(vault).owner(), address(this));
        assertEq(factory.vaultsOf(address(this)).length, 1);
        assertEq(CircuitVault(vault).maxDrawdownBps(), 1000);
        assertTrue(CircuitVault(vault).aaveStrategy().code.length > 0);
    }
}
