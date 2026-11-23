// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkBase} from "../fork/CircuitVault.fork.t.sol";
import {CircuitVault} from "../../src/CircuitVault.sol";
import {AaveV3UsdcAdapter} from "../../src/AaveV3UsdcAdapter.sol";
import {MockStrategy} from "../../src/mocks/MockStrategy.sol";
import {IPool} from "../../src/interfaces/IAave.sol";

/// @notice Audit 2026-11-23 M-1 regression on a Base fork with the real Aave V3 pool.
///         Set BASE_FORK_RPC (e.g. anvil on 8642); skipped otherwise.
contract AuditBaseForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }

    function _setupLoss() internal returns (MockStrategy lossy) {
        lossy = new MockStrategy(address(vault), address(usdc));
        vm.prank(owner);
        vault.setStrategy(address(lossy), true, 5000);
        vm.startPrank(agent);
        vault.rebalance(aave, 20_000e6);
        vault.rebalance(address(lossy), 20_000e6);
        vm.stopPrank();
        vm.prank(address(0xdead));
        lossy.impair(6_000e6); // 12% drawdown
        assertTrue(vault.canTrip());
    }

    function test_fork_M1_tripExitsRealAaveAndOtherStrategy() public onFork {
        MockStrategy lossy = _setupLoss();
        vm.prank(stranger);
        vault.trip();
        assertTrue(vault.tripped());
        assertEq(vault.strategyAssets(aave), 0);
        assertEq(lossy.totalAssets(), 0);
        assertApproxEqAbs(vault.cash(), DEPOSIT - 6_000e6, 10);
    }

    function test_fork_M1_tripLatchesWhenAaveWithdrawReverts() public onFork {
        MockStrategy lossy = _setupLoss();
        address pool = address(AaveV3UsdcAdapter(aave).pool());
        // Simulate 100% utilization: Aave withdraw reverts.
        vm.mockCallRevert(pool, abi.encodeWithSelector(IPool.withdraw.selector), bytes("NOT_ENOUGH_AVAILABLE_USER_BALANCE"));
        vm.prank(stranger);
        vault.trip();
        vm.clearMockedCalls();
        assertTrue(vault.tripped());
        assertEq(lossy.totalAssets(), 0, "other strategy still exited");
        assertApproxEqAbs(vault.strategyAssets(aave), 20_000e6, 10);
        vm.prank(owner);
        vault.exitAll();
        assertEq(vault.strategyAssets(aave), 0);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_fork_M1_tripCannotBeGasGriefed(uint256 g) public onFork {
        MockStrategy lossy = _setupLoss();
        g = bound(g, 30_000, 2_000_000);
        vm.prank(stranger);
        (bool ok,) = address(vault).call{gas: g}(abi.encodeCall(CircuitVault.trip, ()));
        if (ok) {
            assertTrue(vault.tripped());
            assertEq(vault.strategyAssets(aave), 0, "aave skipped under gas grief");
            assertEq(lossy.totalAssets(), 0, "lossy skipped under gas grief");
        } else {
            assertFalse(vault.tripped());
        }
    }
}
