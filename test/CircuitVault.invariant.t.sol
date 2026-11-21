// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CircuitVault} from "../src/CircuitVault.sol";
import {CircuitVaultFactory} from "../src/CircuitVaultFactory.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockAavePool, MockAToken} from "../src/mocks/MockAavePool.sol";
import {MockStrategy} from "../src/mocks/MockStrategy.sol";

contract Handler is Test {
    CircuitVault public vault;
    MockUSDC public usdc;
    MockAavePool public pool;
    address public aave;
    address public owner;
    address public agent;
    address public outsider = makeAddr("inv-outsider");

    uint256 public ghostAgentLeaks;
    uint256 public ghostCapViolations;
    uint256 public ghostRebalanceWhileBlocked;
    uint256 public ghostSuccessfulRebalances;
    uint256 public ghostTrips;
    uint256 public calls;
    bool public lastWasAccrue;

    constructor(CircuitVault v, MockUSDC u, MockAavePool p, address aave_, address o, address a) {
        vault = v;
        usdc = u;
        pool = p;
        aave = aave_;
        owner = o;
        agent = a;
    }

    function rebalance(uint256 target) external {
        calls++;
        lastWasAccrue = false;
        target = bound(target, 0, 200_000e6);
        bool blocked = vault.paused() || vault.tripped() || vault.canTrip();
        (bool active, uint64 expiry) = vault.agents(agent);
        if (!active || expiry <= block.timestamp) blocked = true;
        uint256 outsiderBefore = usdc.balanceOf(outsider) + usdc.balanceOf(agent);
        vm.prank(agent);
        try vault.rebalance(aave, target) {
            ghostSuccessfulRebalances++;
            if (blocked) ghostRebalanceWhileBlocked++;
            (bool allowed, uint16 capBps,) = vault.strategies(aave);
            uint256 held = vault.strategyAssets(aave);
            uint256 tv = vault.totalValue();
            if (allowed && held > 0 && tv > 0 && held * 10_000 > tv * capBps) ghostCapViolations++;
        } catch {}
        uint256 outsiderAfter = usdc.balanceOf(outsider) + usdc.balanceOf(agent);
        if (outsiderAfter > outsiderBefore) ghostAgentLeaks += outsiderAfter - outsiderBefore;
    }

    function trip() external {
        vm.prank(outsider);
        try vault.trip() {
            ghostTrips++;
        } catch {}
    }

    function impair(uint256 lossBps) external {
        lossBps = bound(lossBps, 0, 5000);
        uint256 held = vault.strategyAssets(aave);
        if (held == 0) return;
        uint256 loss = (held * lossBps) / 10_000;
        if (loss == 0) return;
        pool.impair(aave, loss);
    }

    function accrue(uint256 gainBps) external {
        lastWasAccrue = true;
        gainBps = bound(gainBps, 0, 200);
        uint256 held = vault.strategyAssets(aave);
        if (held == 0 || gainBps == 0) return;
        uint256 gain = (held * gainBps) / 10_000;
        if (gain == 0) return;
        usdc.mint(address(pool), gain);
        pool.accrue(aave, gain);
        vault.checkpoint();
    }

    function ownerDeposit(uint256 amt) external {
        lastWasAccrue = false;
        amt = bound(amt, 1, 50_000e6);
        uint256 bal = usdc.balanceOf(owner);
        if (amt > bal) amt = bal;
        if (amt == 0) return;
        vm.startPrank(owner);
        try vault.deposit(amt) {} catch {}
        vm.stopPrank();
    }

    function ownerWithdraw(uint256 amt) external {
        lastWasAccrue = false;
        amt = bound(amt, 1, vault.cash());
        if (amt == 0) return;
        vm.prank(owner);
        try vault.withdraw(owner, amt) {} catch {}
    }

    function togglePause(bool p) external {
        lastWasAccrue = false;
        bool isPaused = vault.paused();
        vm.prank(owner);
        if (p && !isPaused) vault.pause();
        if (!p && isPaused) vault.unpause();
    }

    function ownerExit() external {
        lastWasAccrue = false;
        vm.prank(owner);
        try vault.exitAll() {} catch {}
    }

    function ownerReset() external {
        vm.prank(owner);
        try vault.resetTrip() {} catch {}
    }
}

contract CircuitVaultInvariantTest is Test {
    Handler handler;
    CircuitVault vault;
    MockUSDC usdc;
    MockAavePool pool;
    address aave;

    address owner = makeAddr("inv-owner");
    address agent = makeAddr("inv-agent");

    function setUp() public {
        usdc = new MockUSDC();
        MockAToken aToken = new MockAToken(address(usdc));
        pool = new MockAavePool(address(usdc), address(aToken));
        aToken.setPool(address(pool));
        usdc.mint(address(pool), 50_000_000e6);

        CircuitVaultFactory factory = new CircuitVaultFactory(address(usdc), address(pool), address(aToken));
        vm.prank(owner);
        vault = CircuitVault(factory.createVault());
        aave = vault.aaveStrategy();

        usdc.mint(owner, 5_000_000e6);
        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000e6);
        vault.grantAgent(agent, uint64(block.timestamp + 365 days));
        vm.stopPrank();

        handler = new Handler(vault, usdc, pool, aave, owner, agent);
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](8);
        sels[0] = Handler.rebalance.selector;
        sels[1] = Handler.trip.selector;
        sels[2] = Handler.impair.selector;
        sels[3] = Handler.accrue.selector;
        sels[4] = Handler.ownerDeposit.selector;
        sels[5] = Handler.ownerWithdraw.selector;
        sels[6] = Handler.togglePause.selector;
        sels[7] = Handler.ownerExit.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function invariant_capsHold() public view {
        assertEq(handler.ghostCapViolations(), 0);
        // Yield can drift a strategy slightly over its cap until the next rebalance.
        // After every other action, caps must hold. Withdraw now reverts if it would breach.
        if (handler.lastWasAccrue()) return;
        (bool allowed, uint16 capBps,) = vault.strategies(aave);
        uint256 held = vault.strategyAssets(aave);
        uint256 tv = vault.totalValue();
        if (allowed && held > 0 && tv > 0) {
            assertLe(held * 10_000, tv * capBps);
        }
    }

    function invariant_agentNeverReceivesFunds() public view {
        assertEq(handler.ghostAgentLeaks(), 0);
        assertEq(usdc.balanceOf(agent), 0);
        assertEq(usdc.balanceOf(handler.outsider()), 0);
    }

    function invariant_trippedBreakerBlocksAgent() public view {
        assertEq(handler.ghostRebalanceWhileBlocked(), 0);
    }

    function invariant_fundsStayInVaultOrStrategies() public view {
        uint256 inVault = usdc.balanceOf(address(vault));
        uint256 inStrategies;
        uint256 n = vault.strategyCount();
        for (uint256 i; i < n; ++i) {
            address s = vault.strategyAt(i);
            inStrategies += IStrategy(s).totalAssets();
        }
        assertEq(vault.totalValue(), inVault + inStrategies);
        // Agent and random outsiders never hold vault USDC.
        assertEq(usdc.balanceOf(agent), 0);
    }

    function invariant_hwmNeverBelowValueWithoutTripMath() public view {
        // HWM is at least current value after any checkpointed gain; it may be above after a loss.
        if (vault.totalValue() > vault.highWaterMark()) {
            // A gain that has not been checkpointed is allowed; handler.accrue checkpoints.
            revert("value above high-water mark");
        }
    }
}
