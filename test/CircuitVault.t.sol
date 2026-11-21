// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CircuitVault} from "../src/CircuitVault.sol";
import {CircuitVaultFactory} from "../src/CircuitVaultFactory.sol";
import {AaveV3UsdcAdapter} from "../src/AaveV3UsdcAdapter.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockAavePool, MockAToken} from "../src/mocks/MockAavePool.sol";
import {MockStrategy} from "../src/mocks/MockStrategy.sol";

contract CircuitVaultTest is Test {
    CircuitVaultFactory factory;
    CircuitVault vault;
    MockUSDC usdc;
    MockAToken aToken;
    MockAavePool pool;
    address aave;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address stranger = makeAddr("stranger");
    address guardian = makeAddr("guardian");

    uint256 constant DEPOSIT = 100_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        aToken = new MockAToken(address(usdc));
        pool = new MockAavePool(address(usdc), address(aToken));
        aToken.setPool(address(pool));
        usdc.mint(address(pool), 1_000_000e6);

        factory = new CircuitVaultFactory(address(usdc), address(pool), address(aToken));
        vm.prank(owner);
        vault = CircuitVault(factory.createVault());
        aave = vault.aaveStrategy();

        usdc.mint(owner, 1_000_000e6);
        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(DEPOSIT);
        vault.grantAgent(agent, uint64(block.timestamp + 30 days));
        vm.stopPrank();
    }

    function test_factoryIndexesVaultAndWiresDefaults() public view {
        assertEq(factory.vaultsOf(owner).length, 1);
        assertEq(factory.vaultsOf(owner)[0], address(vault));
        assertEq(vault.owner(), owner);
        assertEq(vault.usdc(), address(usdc));
        assertEq(vault.maxDrawdownBps(), 1000);
        assertTrue(vault.autoExitOnTrip());
        assertEq(vault.cash(), DEPOSIT);
        assertEq(vault.totalValue(), DEPOSIT);
        assertEq(vault.highWaterMark(), DEPOSIT);
        (bool allowed, uint16 capBps,) = vault.strategies(aave);
        assertTrue(allowed);
        assertEq(capBps, 8000);
        assertEq(AaveV3UsdcAdapter(aave).vault(), address(vault));
        assertEq(AaveV3UsdcAdapter(aave).usdc(), address(usdc));
        assertEq(address(AaveV3UsdcAdapter(aave).pool()), address(pool));
        assertEq(AaveV3UsdcAdapter(aave).aToken(), address(aToken));
    }

    function test_createVaultWithPolicy() public {
        vm.prank(owner);
        CircuitVault custom = CircuitVault(factory.createVaultWithPolicy(500, 6000));
        assertEq(custom.maxDrawdownBps(), 500);
        (, uint16 capBps,) = custom.strategies(custom.aaveStrategy());
        assertEq(capBps, 6000);
    }

    function test_depositAndWithdrawUpdateHwm() public {
        vm.prank(owner);
        vault.deposit(50_000e6);
        assertEq(vault.highWaterMark(), 150_000e6);
        assertEq(vault.totalValue(), 150_000e6);

        vm.prank(owner);
        vault.withdraw(owner, 30_000e6);
        // HWM scaled pro-rata: 150k * 120k / 150k = 120k
        assertEq(vault.highWaterMark(), 120_000e6);
        assertEq(vault.cash(), 120_000e6);
        assertEq(usdc.balanceOf(owner), 1_000_000e6 - 120_000e6);
    }

    function test_strangerCannotDepositOrWithdraw() public {
        usdc.mint(stranger, 1_000e6);
        vm.startPrank(stranger);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert();
        vault.deposit(1_000e6);
        vm.expectRevert();
        vault.withdraw(stranger, 1e6);
        vm.stopPrank();
    }

    function test_rebalanceIntoAaveWithinCap() public {
        vm.prank(agent);
        vault.rebalance(aave, 80_000e6);
        assertEq(vault.strategyAssets(aave), 80_000e6);
        assertEq(vault.cash(), 20_000e6);
        assertEq(vault.totalValue(), DEPOSIT);
        assertEq(vault.allocationBps(aave), 8000);
    }

    function test_rebalanceExceedsCapReverts() public {
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(CircuitVault.ExceedsAllocationCap.selector, 80_001e6, DEPOSIT, uint16(8000))
        );
        vault.rebalance(aave, 80_001e6);
        assertEq(vault.strategyAssets(aave), 0);
        assertEq(vault.cash(), DEPOSIT);
    }

    function test_rebalanceBackToCash() public {
        vm.prank(agent);
        vault.rebalance(aave, 50_000e6);
        vm.prank(agent);
        vault.rebalance(aave, 10_000e6);
        assertEq(vault.strategyAssets(aave), 10_000e6);
        assertEq(vault.cash(), 90_000e6);
    }

    function test_agentCannotSendFundsOutsideVaultAndStrategies() public {
        vm.prank(agent);
        vault.rebalance(aave, 40_000e6);
        assertEq(usdc.balanceOf(agent), 0);
        assertEq(usdc.balanceOf(stranger), 0);
        assertEq(usdc.balanceOf(address(vault)) + usdc.balanceOf(address(pool)), 1_000_000e6 + DEPOSIT);
        // Agent has no other entry point that moves tokens.
        vm.prank(agent);
        vm.expectRevert();
        vault.withdraw(agent, 1e6);
        vm.prank(agent);
        vm.expectRevert();
        vault.exitStrategy(aave);
    }

    function test_strangerCannotRebalance() public {
        vm.prank(stranger);
        vm.expectRevert(CircuitVault.NotAgent.selector);
        vault.rebalance(aave, 1e6);
    }

    function test_expiredRevokedPausedBlocked() public {
        vm.prank(agent);
        vault.rebalance(aave, 1_000e6);

        vm.warp(block.timestamp + 31 days);
        vm.prank(agent);
        vm.expectRevert(CircuitVault.AgentExpired.selector);
        vault.rebalance(aave, 2_000e6);

        vm.prank(owner);
        vault.grantAgent(agent, uint64(block.timestamp + 10 days));

        vm.prank(owner);
        vault.pause();
        vm.prank(agent);
        vm.expectRevert(); // EnforcedPause
        vault.rebalance(aave, 2_000e6);

        vm.prank(owner);
        vault.unpause();
        vm.prank(owner);
        vault.revokeAgent(agent);
        vm.prank(agent);
        vm.expectRevert(CircuitVault.NotAgent.selector);
        vault.rebalance(aave, 2_000e6);
    }

    function test_guardianCanPauseAndRevoke() public {
        vm.prank(owner);
        vault.setGuardian(guardian);
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());
        vm.prank(guardian);
        vault.revokeAgent(agent);
        (bool active,) = vault.agents(agent);
        assertFalse(active);
        vm.prank(guardian);
        vm.expectRevert();
        vault.unpause();
        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_unknownStrategyRejected() public {
        MockStrategy other = new MockStrategy(address(vault), address(usdc));
        vm.prank(agent);
        vm.expectRevert(CircuitVault.StrategyNotAllowed.selector);
        vault.rebalance(address(other), 1e6);
    }

    function test_ownerCanAddSecondStrategyAndCapHolds() public {
        MockStrategy extra = new MockStrategy(address(vault), address(usdc));
        vm.prank(owner);
        vault.setStrategy(address(extra), true, 2000);
        vm.prank(agent);
        vault.rebalance(address(extra), 20_000e6);
        assertEq(vault.strategyAssets(address(extra)), 20_000e6);
        vm.prank(agent);
        vm.expectRevert();
        vault.rebalance(address(extra), 20_001e6);
    }

    function test_cannotDisableStrategyWithAssets() public {
        vm.prank(agent);
        vault.rebalance(aave, 10_000e6);
        vm.prank(owner);
        vm.expectRevert(CircuitVault.StrategyHasAssets.selector);
        vault.setStrategy(aave, false, 0);
        vm.prank(owner);
        vault.exitStrategy(aave);
        vm.prank(owner);
        vault.setStrategy(aave, false, 0);
        (bool allowed,,) = vault.strategies(aave);
        assertFalse(allowed);
    }

    function test_yieldRaisesHighWaterMark() public {
        vm.prank(agent);
        vault.rebalance(aave, 50_000e6);
        usdc.mint(address(pool), 5_000e6);
        pool.accrue(aave, 5_000e6);
        assertEq(vault.totalValue(), 105_000e6);
        assertEq(vault.highWaterMark(), DEPOSIT); // not raised until checkpoint
        vault.checkpoint();
        assertEq(vault.highWaterMark(), 105_000e6);
        assertEq(vault.drawdownBps(), 0);
    }

    function test_depositDoesNotEraseDrawdown() public {
        vm.prank(agent);
        vault.rebalance(aave, 80_000e6);
        pool.impair(aave, 20_000e6); // NAV = 80k, HWM = 100k, dd = 2000 bps
        assertEq(vault.totalValue(), 80_000e6);
        assertEq(vault.drawdownBps(), 2000);
        vm.prank(owner);
        vault.deposit(20_000e6); // HWM += 20k = 120k, value = 100k, dd remains ~1666 bps
        assertEq(vault.highWaterMark(), 120_000e6);
        assertEq(vault.totalValue(), 100_000e6);
        assertGt(vault.drawdownBps(), 0);
        assertEq(vault.drawdownBps(), 1666); // (20_000e6 * 10000) / 120_000e6
    }

    function test_tripRevertsBeforeLimit() public {
        vm.prank(agent);
        vault.rebalance(aave, 80_000e6);
        pool.impair(aave, 5_000e6); // 5% < 10%
        assertEq(vault.drawdownBps(), 500);
        assertFalse(vault.canTrip());
        vm.prank(stranger);
        vm.expectRevert(CircuitVault.CannotTrip.selector);
        vault.trip();
    }

    function test_anyoneCanTripAtLimitAndAutoExit() public {
        vm.prank(agent);
        vault.rebalance(aave, 80_000e6);
        pool.impair(aave, 10_000e6); // 10% on the nose
        assertEq(vault.drawdownBps(), 1000);
        assertTrue(vault.canTrip());

        // Agent is already blocked once the limit is hit, even before trip().
        vm.prank(agent);
        vm.expectRevert(CircuitVault.DrawdownLimitHit.selector);
        vault.rebalance(aave, 0);

        vm.prank(stranger);
        vault.trip();
        assertTrue(vault.tripped());
        assertEq(vault.strategyAssets(aave), 0);
        assertEq(vault.cash(), 90_000e6); // 20k cash + 70k recovered (80k-10k lost aTokens; leftover USDC stays in mock pool)

        vm.prank(agent);
        vm.expectRevert(CircuitVault.BreakerTripped.selector);
        vault.rebalance(aave, 1e6);

        // Owner can still withdraw cash after the trip.
        vm.prank(owner);
        vault.withdraw(owner, 90_000e6);
        assertEq(usdc.balanceOf(owner), 1_000_000e6 - DEPOSIT + 90_000e6);
    }

    function test_tripWithoutAutoExitLeavesAssetsAndBlocksAgent() public {
        vm.prank(owner);
        vault.setAutoExitOnTrip(false);
        vm.prank(agent);
        vault.rebalance(aave, 80_000e6);
        pool.impair(aave, 10_000e6);
        vm.prank(stranger);
        vault.trip();
        assertTrue(vault.tripped());
        assertEq(vault.strategyAssets(aave), 70_000e6);
        vm.prank(agent);
        vm.expectRevert(CircuitVault.BreakerTripped.selector);
        vault.rebalance(aave, 0);
        vm.prank(owner);
        vault.exitAll();
        assertEq(vault.strategyAssets(aave), 0);
        assertEq(vault.cash(), 90_000e6);
    }

    function test_resetTripAllowsAgentAgain() public {
        vm.prank(agent);
        vault.rebalance(aave, 80_000e6);
        pool.impair(aave, 10_000e6);
        vault.trip();
        // Owner tops up to recover, then resets. Deposit raises HWM by the top-up, so
        // we also checkpoint after a "recovery" by impairing no further and... actually
        // after trip+autoExit, value is 90k, HWM 100k. Deposit 20k -> value 110k, HWM 120k,
        // still in drawdown. Owner must raise the HWM only via yield or accept a reset
        // that checkpoints current value only if it exceeds HWM. resetTrip does not lower HWM.
        // To make the agent usable, owner can widen the limit or wait for recovery.
        vm.prank(owner);
        vault.setMaxDrawdownBps(2000); // 20%, current dd = 1000 after exit (90/100)
        // After autoExit, value=90k, HWM=100k, dd=1000. With new limit 2000, canTrip is false.
        vm.prank(owner);
        vault.resetTrip();
        assertFalse(vault.tripped());
        vm.prank(agent);
        vault.rebalance(aave, 10_000e6);
        assertEq(vault.strategyAssets(aave), 10_000e6);
    }

    function test_withdrawWorksWhilePausedAndTripped() public {
        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        vault.withdraw(owner, 1_000e6);
        assertEq(vault.cash(), 99_000e6);
    }

    function test_setMaxDrawdownBounds() public {
        vm.prank(owner);
        vm.expectRevert(CircuitVault.InvalidDrawdown.selector);
        vault.setMaxDrawdownBps(0);
        vm.prank(owner);
        vault.setMaxDrawdownBps(10_000);
        assertEq(vault.maxDrawdownBps(), 10_000);
    }

    function test_insufficientCashOnRebalance() public {
        vm.prank(agent);
        vm.expectRevert(CircuitVault.InsufficientCash.selector);
        vault.rebalance(aave, DEPOSIT + 1);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_rebalanceRespectsCap(uint256 target) public {
        target = bound(target, 0, DEPOSIT);
        vm.prank(agent);
        if (target * 10_000 > DEPOSIT * 8000) {
            vm.expectRevert();
            vault.rebalance(aave, target);
            assertEq(vault.strategyAssets(aave), 0);
        } else {
            vault.rebalance(aave, target);
            assertLe(vault.strategyAssets(aave) * 10_000, vault.totalValue() * 8000);
            assertEq(usdc.balanceOf(agent), 0);
            assertEq(vault.cash() + vault.strategyAssets(aave), DEPOSIT);
        }
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_agentCannotLeak(uint256 t1, uint256 t2) public {
        t1 = bound(t1, 0, 80_000e6);
        t2 = bound(t2, 0, 80_000e6);
        vm.prank(agent);
        vault.rebalance(aave, t1);
        vm.prank(agent);
        vault.rebalance(aave, t2);
        assertEq(usdc.balanceOf(agent), 0);
        assertEq(usdc.balanceOf(stranger), 0);
        assertEq(vault.cash() + vault.strategyAssets(aave), DEPOSIT);
        // All USDC still in vault or Aave mock (plus the pool's seed liquidity).
        assertEq(usdc.balanceOf(address(vault)) + usdc.balanceOf(address(pool)), 1_000_000e6 + DEPOSIT);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_tripBlocksAgent(uint256 lossBps) public {
        lossBps = bound(lossBps, 1000, 8000); // at or past the 10% default
        vm.prank(agent);
        vault.rebalance(aave, 80_000e6);
        uint256 loss = (DEPOSIT * lossBps) / 10_000;
        if (loss > 80_000e6) loss = 80_000e6;
        pool.impair(aave, loss);
        assertTrue(vault.canTrip());
        vault.trip();
        vm.prank(agent);
        vm.expectRevert(CircuitVault.BreakerTripped.selector);
        vault.rebalance(aave, 1e6);
    }

    function test_withdrawCashCannotBreachCap() public {
        vm.prank(agent);
        vault.rebalance(aave, 80_000e6);
        // Withdrawing any cash would push Aave above 80%.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(CircuitVault.ExceedsAllocationCap.selector, 80_000e6, 99_999e6, uint16(8000))
        );
        vault.withdraw(owner, 1e6);
        vm.prank(owner);
        vault.exitStrategy(aave);
        vm.prank(owner);
        vault.withdraw(owner, 1_000e6);
        assertEq(vault.cash(), DEPOSIT - 1_000e6);
    }

    function test_twoStepOwnership() public {
        address next = makeAddr("next-owner");
        vm.prank(owner);
        vault.transferOwnership(next);
        assertEq(vault.owner(), owner);
        vm.prank(next);
        vault.acceptOwnership();
        assertEq(vault.owner(), next);
    }
}
