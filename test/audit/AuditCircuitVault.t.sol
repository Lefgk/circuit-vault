// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CircuitVault} from "../../src/CircuitVault.sol";
import {CircuitVaultFactory} from "../../src/CircuitVaultFactory.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockAavePool, MockAToken} from "../../src/mocks/MockAavePool.sol";
import {MockStrategy} from "../../src/mocks/MockStrategy.sol";

/// @notice Audit 2026-11-23 PoCs and regression tests.
contract AuditCircuitVaultTest is Test {
    CircuitVault vault;
    MockUSDC usdc;
    MockAToken aToken;
    MockAavePool pool;
    MockStrategy lossy;
    address aave;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address keeper = makeAddr("keeper");
    address sink = makeAddr("sink");

    function setUp() public {
        usdc = new MockUSDC();
        aToken = new MockAToken(address(usdc));
        pool = new MockAavePool(address(usdc), address(aToken));
        aToken.setPool(address(pool));
        usdc.mint(address(pool), 1_000_000e6);
        CircuitVaultFactory factory = new CircuitVaultFactory(address(usdc), address(pool), address(aToken));
        vm.prank(owner);
        vault = CircuitVault(factory.createVault());
        aave = vault.aaveStrategy();
        lossy = new MockStrategy(address(vault), address(usdc));

        usdc.mint(owner, 100_000e6);
        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(100_000e6);
        vault.grantAgent(agent, uint64(block.timestamp + 30 days));
        vault.setStrategy(address(lossy), true, 5000);
        vm.stopPrank();

        vm.startPrank(agent);
        vault.rebalance(aave, 40_000e6);
        vault.rebalance(address(lossy), 40_000e6);
        vm.stopPrank();
        // second strategy loses 10k -> 10% drawdown from a 100k HWM
        vm.prank(address(0xdead));
        lossy.impair(10_000e6);
        assertTrue(vault.canTrip());
    }

    function _drainAaveLiquidity() internal {
        // Aave at 100% utilization: aTokens are still owed, but the pool holds no free USDC.
        uint256 bal = usdc.balanceOf(address(pool));
        vm.prank(address(pool));
        usdc.transfer(sink, bal);
    }

    /// M-1 regression: an illiquid strategy must not stop trip() from latching or the
    /// other strategies from exiting. On the original code this whole call reverted.
    function test_M1_tripLatchesAndExitsOthersWhenAaveIlliquid() public {
        _drainAaveLiquidity();
        vm.prank(keeper);
        vault.trip();
        assertTrue(vault.tripped(), "breaker latched");
        assertEq(lossy.totalAssets(), 0, "lossy strategy exited");
        assertEq(vault.cash(), 20_000e6 + 30_000e6, "cash = idle + recovered");
        assertEq(vault.strategyAssets(aave), 40_000e6, "aave still owed, exit retryable");

        // Liquidity returns; guardian/owner can finish the exit.
        vm.prank(sink);
        usdc.transfer(address(pool), 1_000_000e6);
        vm.prank(owner);
        vault.exitAll();
        assertEq(vault.strategyAssets(aave), 0);
        assertEq(vault.cash(), 90_000e6);
    }

    /// M-1 fix must not open a 63/64 gas-griefing hole: any trip() that succeeds with a
    /// liquid pool has exited every strategy.
    function testFuzz_M1_tripCannotBeGasGriefed(uint256 g) public {
        g = bound(g, 30_000, 1_500_000);
        vm.prank(keeper);
        (bool ok,) = address(vault).call{gas: g}(abi.encodeCall(CircuitVault.trip, ()));
        if (ok) {
            assertTrue(vault.tripped());
            assertEq(lossy.totalAssets(), 0, "lossy not exited");
            assertEq(vault.strategyAssets(aave), 0, "aave not exited");
        } else {
            assertFalse(vault.tripped());
        }
    }

    /// L-1 PoC (acknowledged): resetTrip keeps the old HWM, so after a real loss the
    /// breaker stays "can trip" and the agent stays blocked until the owner widens the
    /// limit or withdraws and re-deposits.
    function test_L1_resetTripDoesNotRearmAfterRealLoss() public {
        vault.trip();
        vm.prank(owner);
        vault.resetTrip();
        assertFalse(vault.tripped());
        assertTrue(vault.canTrip(), "still past the limit vs stale HWM");
        vm.prank(agent);
        vm.expectRevert(CircuitVault.DrawdownLimitHit.selector);
        vault.rebalance(aave, 1e6);
    }

    /// Refutation check: a third party cannot push NAV down or the HWM up for free
    /// to force a trip. Donations raise NAV and HWM equally.
    function testFuzz_donationCannotForceTrip(uint256 d) public {
        // fresh healthy state: undo the loss
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(lossy), 10_000e6);
        lossy.accrue(10_000e6);
        assertFalse(vault.canTrip());
        d = bound(d, 1, 1_000_000e6);
        usdc.mint(address(this), d);
        usdc.transfer(address(vault), d);
        vault.checkpoint();
        assertFalse(vault.canTrip());
        assertEq(vault.drawdownBps(), 0);
    }
}
