// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CircuitVault} from "../../src/CircuitVault.sol";
import {CircuitVaultFactory} from "../../src/CircuitVaultFactory.sol";
import {AaveV3UsdcAdapter} from "../../src/AaveV3UsdcAdapter.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockAavePool, MockAToken} from "../../src/mocks/MockAavePool.sol";
import {MockStrategy} from "../../src/mocks/MockStrategy.sol";

/// @dev Owner-whitelisted strategy that tries to re-enter the vault from deposit/withdraw.
contract ReentrantStrategy is IStrategy {
    address public immutable vault;
    address public immutable usdc;
    uint256 public held;
    bytes4 public attack; // selector to call on the vault during deposit
    bool public attackSucceeded;
    bool public attacked;

    constructor(address vault_, address usdc_) {
        vault = vault_;
        usdc = usdc_;
    }

    function setAttack(bytes4 sel) external {
        attack = sel;
    }

    function asset() external view returns (address) {
        return usdc;
    }

    function totalAssets() external view returns (uint256) {
        return held;
    }

    function deposit(uint256 amount) external {
        MockUSDC(usdc).transferFrom(vault, address(this), amount);
        held += amount;
        if (attack != bytes4(0)) {
            attacked = true;
            bytes memory data = attack == CircuitVault.rebalance.selector
                ? abi.encodeWithSelector(attack, address(this), uint256(0))
                : attack == CircuitVault.withdraw.selector
                    ? abi.encodeWithSelector(attack, address(this), uint256(1))
                    : abi.encodeWithSelector(attack);
            (bool ok,) = vault.call(data);
            attackSucceeded = ok;
        }
    }

    function withdraw(uint256 amount) external returns (uint256) {
        held -= amount;
        MockUSDC(usdc).transfer(vault, amount);
        return amount;
    }

    function withdrawAll() external returns (uint256 a) {
        a = held;
        held = 0;
        MockUSDC(usdc).transfer(vault, a);
    }
}

/// @notice Polish pass 2026-11-24: adapter/factory/constructor guards, role matrix,
///         reentrancy, HWM math, boundary and precision tests.
contract Polish20261124Test is Test {
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

        usdc.mint(owner, 1_000_000_000e6);
        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(DEPOSIT);
        vault.grantAgent(agent, uint64(block.timestamp + 30 days));
        vault.setGuardian(guardian);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ adapter

    function test_adapter_onlyVault() public {
        AaveV3UsdcAdapter a = AaveV3UsdcAdapter(aave);
        address[3] memory callers = [stranger, owner, agent];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(AaveV3UsdcAdapter.NotVault.selector);
            a.deposit(1);
            vm.expectRevert(AaveV3UsdcAdapter.NotVault.selector);
            a.withdraw(1);
            vm.expectRevert(AaveV3UsdcAdapter.NotVault.selector);
            a.withdrawAll();
            vm.stopPrank();
        }
    }

    function test_adapter_zeroAmountAndEmptyWithdrawAll() public {
        vm.startPrank(address(vault));
        vm.expectRevert(AaveV3UsdcAdapter.ZeroAmount.selector);
        AaveV3UsdcAdapter(aave).deposit(0);
        vm.expectRevert(AaveV3UsdcAdapter.ZeroAmount.selector);
        AaveV3UsdcAdapter(aave).withdraw(0);
        assertEq(AaveV3UsdcAdapter(aave).withdrawAll(), 0);
        vm.stopPrank();
    }

    function test_adapter_constructorGuards() public {
        vm.expectRevert(AaveV3UsdcAdapter.ZeroAddress.selector);
        new AaveV3UsdcAdapter(address(0), address(usdc), address(pool), address(aToken));
        vm.expectRevert(AaveV3UsdcAdapter.ZeroAddress.selector);
        new AaveV3UsdcAdapter(address(vault), address(0), address(pool), address(aToken));
        // aToken whose underlying is not the supplied USDC
        MockUSDC other = new MockUSDC();
        vm.expectRevert(AaveV3UsdcAdapter.BadAToken.selector);
        new AaveV3UsdcAdapter(address(vault), address(other), address(pool), address(aToken));
        // aToken whose POOL differs
        MockAToken a2 = new MockAToken(address(usdc));
        a2.setPool(address(0xBEEF));
        vm.expectRevert(AaveV3UsdcAdapter.BadAToken.selector);
        new AaveV3UsdcAdapter(address(vault), address(usdc), address(pool), address(a2));
    }

    function test_adapter_approvalOnlyToPool() public view {
        assertEq(usdc.allowance(aave, address(pool)), type(uint256).max);
        assertEq(usdc.allowance(address(vault), aave), 0);
    }

    // ------------------------------------------------------------ factory / constructor

    function test_factory_zeroAddressGuards() public {
        vm.expectRevert(CircuitVaultFactory.ZeroAddress.selector);
        new CircuitVaultFactory(address(0), address(pool), address(aToken));
        vm.expectRevert(CircuitVaultFactory.ZeroAddress.selector);
        new CircuitVaultFactory(address(usdc), address(0), address(aToken));
        vm.expectRevert(CircuitVaultFactory.ZeroAddress.selector);
        new CircuitVaultFactory(address(usdc), address(pool), address(0));
    }

    function test_factory_policyValidationAndIndependentVaults() public {
        vm.startPrank(stranger);
        vm.expectRevert(CircuitVault.InvalidDrawdown.selector);
        factory.createVaultWithPolicy(0, 5000);
        vm.expectRevert(CircuitVault.InvalidDrawdown.selector);
        factory.createVaultWithPolicy(10_001, 5000);
        vm.expectRevert(CircuitVault.InvalidCap.selector);
        factory.createVaultWithPolicy(1000, 0);
        vm.expectRevert(CircuitVault.InvalidCap.selector);
        factory.createVaultWithPolicy(1000, 10_001);
        CircuitVault a = CircuitVault(factory.createVault());
        CircuitVault b = CircuitVault(factory.createVaultWithPolicy(10_000, 10_000));
        vm.stopPrank();
        assertTrue(address(a) != address(b));
        assertTrue(a.aaveStrategy() != b.aaveStrategy());
        assertEq(a.owner(), stranger);
        assertEq(b.owner(), stranger);
        assertEq(factory.vaultsOf(stranger).length, 2);
        assertEq(factory.vaultsOf(owner).length, 1); // unaffected
        // fresh vault is not controlled by the other vault's owner/agent
        vm.prank(owner);
        vm.expectRevert(CircuitVault.NotOwnerOrGuardian.selector);
        a.pause();
    }

    function test_vault_constructorGuards() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CircuitVault(address(0), address(usdc), address(pool), address(aToken), 1000, 8000);
        vm.expectRevert(CircuitVault.ZeroAddress.selector);
        new CircuitVault(owner, address(0), address(pool), address(aToken), 1000, 8000);
        vm.expectRevert(CircuitVault.ZeroAddress.selector);
        new CircuitVault(owner, address(usdc), address(0), address(aToken), 1000, 8000);
        vm.expectRevert(CircuitVault.ZeroAddress.selector);
        new CircuitVault(owner, address(usdc), address(pool), address(0), 1000, 8000);
    }

    // ------------------------------------------------------------ access-control matrix

    function test_roles_guardianLimitedToPauseRevokeExit() public {
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.unpause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.resetTrip();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.grantAgent(guardian, uint64(block.timestamp + 1 days));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.setStrategy(aave, true, 5000);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.withdraw(guardian, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.deposit(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.setGuardian(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.setMaxDrawdownBps(5000);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.setAutoExitOnTrip(false);
        // allowed
        vault.pause();
        vault.exitAll();
        vault.exitStrategy(aave);
        vault.revokeAgent(agent);
        vm.stopPrank();
        (bool active,) = vault.agents(agent);
        assertFalse(active);
    }

    function test_roles_strangerAndAgentHaveNoAdmin() public {
        address[2] memory callers = [stranger, agent];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(CircuitVault.NotOwnerOrGuardian.selector);
            vault.pause();
            vm.expectRevert(CircuitVault.NotOwnerOrGuardian.selector);
            vault.revokeAgent(agent);
            vm.expectRevert(CircuitVault.NotOwnerOrGuardian.selector);
            vault.exitAll();
            vm.expectRevert(CircuitVault.NotOwnerOrGuardian.selector);
            vault.exitStrategy(aave);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]));
            vault.setGuardian(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]));
            vault.resetTrip();
            vm.stopPrank();
        }
    }

    function test_roles_oldGuardianLosesPowerWhenReplaced() public {
        vm.prank(owner);
        vault.setGuardian(address(0));
        vm.prank(guardian);
        vm.expectRevert(CircuitVault.NotOwnerOrGuardian.selector);
        vault.pause();
        // address(0) never gains power: nobody can call as it, owner path still works
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_agentCannotSelfExtendOrRegrant() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vault.grantAgent(agent, uint64(block.timestamp + 365 days));
    }

    // ------------------------------------------------------------ agent grants

    function test_grantAgent_validation() public {
        vm.startPrank(owner);
        vm.expectRevert(CircuitVault.ZeroAddress.selector);
        vault.grantAgent(address(0), uint64(block.timestamp + 1));
        vm.expectRevert(CircuitVault.InvalidExpiry.selector);
        vault.grantAgent(stranger, uint64(block.timestamp));
        vm.expectRevert(CircuitVault.InvalidExpiry.selector);
        vault.grantAgent(stranger, 0);
        vm.stopPrank();
    }

    function test_agent_expiresExactlyAtExpiry() public {
        address a2 = makeAddr("a2");
        uint64 exp = uint64(block.timestamp + 1 days);
        vm.prank(owner);
        vault.grantAgent(a2, exp);
        vm.warp(exp - 1);
        vm.prank(a2);
        vault.rebalance(aave, 1e6);
        vm.warp(exp);
        vm.prank(a2);
        vm.expectRevert(CircuitVault.AgentExpired.selector);
        vault.rebalance(aave, 2e6);
    }

    function test_revokeAgent_unknownAddressIsHarmlessAndRegrantWorks() public {
        vm.prank(owner);
        vault.revokeAgent(stranger); // no revert
        vm.prank(owner);
        vault.revokeAgent(agent);
        vm.prank(agent);
        vm.expectRevert(CircuitVault.NotAgent.selector);
        vault.rebalance(aave, 1e6);
        vm.prank(owner);
        vault.grantAgent(agent, uint64(block.timestamp + 1 days));
        vm.prank(agent);
        vault.rebalance(aave, 1e6);
    }

    // ------------------------------------------------------------ owner funding

    function test_depositWithdraw_zeroAndBadArgs() public {
        vm.startPrank(owner);
        vm.expectRevert(CircuitVault.ZeroAmount.selector);
        vault.deposit(0);
        vm.expectRevert(CircuitVault.ZeroAmount.selector);
        vault.withdraw(owner, 0);
        vm.expectRevert(CircuitVault.ZeroAddress.selector);
        vault.withdraw(address(0), 1);
        vm.expectRevert(CircuitVault.InsufficientCash.selector);
        vault.withdraw(owner, DEPOSIT + 1);
        vm.stopPrank();
    }

    function test_withdrawMaxCashEmptiesVaultAndHwm() public {
        vm.prank(owner);
        vault.withdraw(owner, DEPOSIT);
        assertEq(vault.totalValue(), 0);
        assertEq(vault.highWaterMark(), 0);
        assertFalse(vault.canTrip());
        // can start again from zero
        vm.prank(owner);
        vault.deposit(5e6);
        assertEq(vault.highWaterMark(), 5e6);
    }

    function test_withdrawToThirdPartyWorks() public {
        vm.prank(owner);
        vault.withdraw(stranger, 1_000e6);
        assertEq(usdc.balanceOf(stranger), 1_000e6);
    }

    function test_depositWhileTrippedAndPausedAllowed() public {
        _loseTenPercentViaAave();
        vault.trip();
        vm.startPrank(owner);
        vault.pause();
        vault.deposit(10e6);
        vm.stopPrank();
        assertEq(vault.cash(), 90_000e6 + 10e6);
    }

    /// HWM scaling: a pro-rata withdraw must never change drawdown bps by more than rounding.
    function testFuzz_withdrawPreservesDrawdown(uint256 loss, uint256 wd) public {
        vm.prank(agent);
        vault.rebalance(aave, 50_000e6);
        loss = bound(loss, 1e6, 9_000e6); // under the 10% trip line
        pool.impair(aave, loss);
        uint256 ddBefore = vault.drawdownBps();
        uint256 hwmBefore = vault.highWaterMark();
        wd = bound(wd, 1, vault.cash());
        // cap may revert if cash gets tiny relative to aave share
        vm.prank(owner);
        try vault.withdraw(owner, wd) {
            uint256 v = vault.totalValue();
            if (v > 0) {
                // HWM scaled down, never up
                assertLe(vault.highWaterMark(), hwmBefore);
                uint256 ddAfter = vault.drawdownBps();
                assertApproxEqAbs(ddAfter, ddBefore, 2);
            }
        } catch {}
    }

    // ------------------------------------------------------------ rebalance semantics

    function test_rebalance_exactCapBoundary() public {
        vm.startPrank(agent);
        vault.rebalance(aave, 80_000e6); // exactly 80%
        vm.expectRevert(abi.encodeWithSelector(CircuitVault.ExceedsAllocationCap.selector, 80_001e6, DEPOSIT, uint16(8000)));
        vault.rebalance(aave, 80_001e6);
        vm.stopPrank();
    }

    function test_rebalance_noApprovalLeftBehind() public {
        vm.prank(agent);
        vault.rebalance(aave, 10_000e6);
        assertEq(usdc.allowance(address(vault), aave), 0);
    }

    function test_rebalance_sameTargetNoop() public {
        vm.startPrank(agent);
        vault.rebalance(aave, 10_000e6);
        uint256 hwm = vault.highWaterMark();
        vault.rebalance(aave, 10_000e6);
        vm.stopPrank();
        assertEq(vault.highWaterMark(), hwm);
        assertEq(vault.cash(), 90_000e6);
        vm.prank(agent);
        vault.rebalance(aave, 0);
        vm.prank(agent);
        vault.rebalance(aave, 0); // zero to zero is fine
        assertEq(vault.cash(), DEPOSIT);
    }

    function test_rebalance_withdrawWhenPoolEmptyReverts() public {
        vm.prank(agent);
        vault.rebalance(aave, 10_000e6);
        uint256 bal = usdc.balanceOf(address(pool));
        vm.prank(address(pool));
        usdc.transfer(stranger, bal);
        vm.prank(agent);
        vm.expectRevert(); // pool cannot pay out
        vault.rebalance(aave, 0);
    }

    function test_rebalance_maxTargetReverts() public {
        vm.prank(agent);
        vm.expectRevert(CircuitVault.InsufficientCash.selector);
        vault.rebalance(aave, type(uint256).max);
    }

    function test_rebalance_disabledAndUnlistedStrategy() public {
        vm.startPrank(owner);
        vault.setStrategy(aave, false, 0);
        vm.stopPrank();
        vm.prank(agent);
        vm.expectRevert(CircuitVault.StrategyNotAllowed.selector);
        vault.rebalance(aave, 1e6);
        // unlisted address with no code never reaches a call
        vm.prank(agent);
        vm.expectRevert(CircuitVault.StrategyNotAllowed.selector);
        vault.rebalance(stranger, 1e6);
    }

    function test_rebalance_blockedAtDrawdownLimitEvenWithoutTrip() public {
        _loseTenPercentViaAave();
        assertTrue(vault.canTrip());
        vm.prank(agent);
        vm.expectRevert(CircuitVault.DrawdownLimitHit.selector);
        vault.rebalance(aave, 0);
    }

    function test_rebalance_pausedReverts() public {
        vm.prank(owner);
        vault.pause();
        vm.prank(agent);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.rebalance(aave, 1e6);
    }

    // ------------------------------------------------------------ strategies

    function test_setStrategy_validation() public {
        MockStrategy s = new MockStrategy(address(vault), address(usdc));
        MockStrategy wrongVault = new MockStrategy(stranger, address(usdc));
        MockStrategy wrongAsset = new MockStrategy(address(vault), address(0xBAD));
        vm.startPrank(owner);
        vm.expectRevert(CircuitVault.ZeroAddress.selector);
        vault.setStrategy(address(0), true, 1000);
        vm.expectRevert(CircuitVault.InvalidCap.selector);
        vault.setStrategy(address(s), true, 0);
        vm.expectRevert(CircuitVault.InvalidCap.selector);
        vault.setStrategy(address(s), true, 10_001);
        vm.expectRevert(CircuitVault.BadStrategy.selector);
        vault.setStrategy(address(wrongVault), true, 1000);
        vm.expectRevert(CircuitVault.BadStrategy.selector);
        vault.setStrategy(address(wrongAsset), true, 1000);
        vm.stopPrank();
    }

    function test_setStrategy_listedOnceAndReenable() public {
        MockStrategy s = new MockStrategy(address(vault), address(usdc));
        vm.startPrank(owner);
        vault.setStrategy(address(s), true, 3000);
        vault.setStrategy(address(s), true, 4000);
        assertEq(vault.strategyCount(), 2);
        vault.setStrategy(address(s), false, 9999); // cap ignored when disabling
        (bool allowed, uint16 cap, uint32 idx) = vault.strategies(address(s));
        assertFalse(allowed);
        assertEq(cap, 0);
        assertEq(idx, 2);
        vault.setStrategy(address(s), true, 2000);
        vm.stopPrank();
        assertEq(vault.strategyCount(), 2);
        assertEq(vault.strategyAt(1), address(s));
    }

    function test_setStrategy_capLoweringDoesNotBreakExistingButBlocksGrowth() public {
        vm.prank(agent);
        vault.rebalance(aave, 80_000e6);
        vm.prank(owner);
        vault.setStrategy(aave, true, 5000);
        // agent can't add, can reduce
        vm.startPrank(agent);
        vm.expectRevert();
        vault.rebalance(aave, 80_001e6);
        vault.rebalance(aave, 50_000e6);
        vm.stopPrank();
    }

    function test_disabledStrategyHoldingAssetsStillCountsInNav() public {
        vm.prank(agent);
        vault.rebalance(aave, 10_000e6);
        // someone donates aTokens to a disabled-then-reenabled flow: simulate accrue after disable is impossible
        // (disable requires 0 assets), so verify accrual after disable still counts toward NAV.
        vm.prank(agent);
        vault.rebalance(aave, 0);
        vm.prank(owner);
        vault.setStrategy(aave, false, 0);
        pool.accrue(aave, 5e6); // stray aTokens
        assertEq(vault.totalValue(), DEPOSIT + 5e6);
        assertEq(vault.strategyAssets(aave), 5e6);
    }

    function test_exitStrategy_unlistedAddressIsHarmless() public {
        MockStrategy foreign = new MockStrategy(stranger, address(usdc));
        vm.prank(owner);
        vm.expectRevert(MockStrategy.NotVault.selector);
        vault.exitStrategy(address(foreign));
    }

    // ------------------------------------------------------------ breaker

    function _loseTenPercentViaAave() internal {
        vm.prank(agent);
        vault.rebalance(aave, 80_000e6);
        pool.impair(aave, 10_000e6);
    }

    function test_trip_exactBoundaryAndOneWeiBelow() public {
        vm.prank(agent);
        vault.rebalance(aave, 80_000e6);
        // 10_000e6 loss = exactly 1000 bps; one unit less rounds down to 999 bps
        pool.impair(aave, 9_999_999_999);
        assertEq(vault.drawdownBps(), 999);
        assertFalse(vault.canTrip());
        pool.impair(aave, 1);
        assertEq(vault.drawdownBps(), 1000);
        assertTrue(vault.canTrip());
    }

    function test_trip_calledTwiceRevertsAndWorksPaused() public {
        _loseTenPercentViaAave();
        vm.prank(owner);
        vault.pause();
        vm.prank(stranger);
        vault.trip();
        assertTrue(vault.tripped());
        vm.expectRevert(CircuitVault.CannotTrip.selector);
        vault.trip();
    }

    function test_trip_withoutAutoExitThenGuardianExitAll() public {
        vm.prank(owner);
        vault.setAutoExitOnTrip(false);
        _loseTenPercentViaAave();
        vault.trip();
        assertEq(vault.strategyAssets(aave), 70_000e6);
        vm.prank(guardian);
        vault.exitAll();
        assertEq(vault.strategyAssets(aave), 0);
        assertEq(vault.cash(), 90_000e6);
    }

    function test_trip_noHwmCannotTrip() public {
        vm.prank(owner);
        vault.withdraw(owner, DEPOSIT);
        assertFalse(vault.canTrip());
        vm.expectRevert(CircuitVault.CannotTrip.selector);
        vault.trip();
    }

    function test_resetTrip_afterRealLossStillBlocksAgent() public {
        // documents audit L-1: breaker keeps firing after reset until limit widened
        _loseTenPercentViaAave();
        vault.trip();
        vm.prank(owner);
        vault.resetTrip();
        assertFalse(vault.tripped());
        assertTrue(vault.canTrip());
        vm.prank(agent);
        vm.expectRevert(CircuitVault.DrawdownLimitHit.selector);
        vault.rebalance(aave, 1e6);
        vm.prank(owner);
        vault.setMaxDrawdownBps(2000);
        vm.prank(agent);
        vault.rebalance(aave, 1e6);
    }

    function test_checkpoint_permissionlessOnlyRaises() public {
        vm.prank(agent);
        vault.rebalance(aave, 50_000e6);
        pool.accrue(aave, 1_000e6);
        vm.prank(stranger);
        vault.checkpoint();
        assertEq(vault.highWaterMark(), DEPOSIT + 1_000e6);
        pool.impair(aave, 500e6);
        vm.prank(stranger);
        vault.checkpoint();
        assertEq(vault.highWaterMark(), DEPOSIT + 1_000e6);
    }

    function test_donationRaisesNavNotHwm() public {
        usdc.mint(address(vault), 5_000e6);
        assertEq(vault.totalValue(), DEPOSIT + 5_000e6);
        assertEq(vault.highWaterMark(), DEPOSIT);
        assertEq(vault.drawdownBps(), 0);
    }

    function test_setMaxDrawdown_changeCanTripExistingLoss() public {
        vm.prank(agent);
        vault.rebalance(aave, 50_000e6);
        pool.impair(aave, 5_000e6); // 5%
        assertFalse(vault.canTrip());
        vm.prank(owner);
        vault.setMaxDrawdownBps(500);
        assertTrue(vault.canTrip());
        vault.trip();
        assertEq(vault.cash(), 95_000e6);
    }

    // ------------------------------------------------------------ reentrancy

    function _reentrantSetup() internal returns (ReentrantStrategy r) {
        r = new ReentrantStrategy(address(vault), address(usdc));
        vm.prank(address(vault));
        usdc.approve(address(r), 0); // no-op; rebalance sets approval itself
        vm.prank(owner);
        vault.setStrategy(address(r), true, 5000);
    }

    function test_reentrancy_strategyCannotReenterVault() public {
        ReentrantStrategy r = _reentrantSetup();
        bytes4[5] memory sels = [
            CircuitVault.rebalance.selector,
            CircuitVault.trip.selector,
            CircuitVault.exitAll.selector,
            CircuitVault.deposit.selector,
            CircuitVault.withdraw.selector
        ];
        for (uint256 i; i < sels.length; ++i) {
            r.setAttack(sels[i]);
            // reset strategy state so each iteration deposits fresh cash
            vm.prank(agent);
            vault.rebalance(address(r), 0);
            vm.prank(agent);
            vault.rebalance(address(r), 1_000e6);
            assertTrue(r.attacked());
            assertFalse(r.attackSucceeded());
        }
    }

    // ------------------------------------------------------------ ownership

    function test_twoStepOwnership_newOwnerControlsAndOldLosesAccess() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        // old owner still in charge until accepted
        vm.prank(owner);
        vault.pause();
        vm.prank(stranger);
        vm.expectRevert();
        vault.acceptOwnership();
        vm.prank(newOwner);
        vault.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.unpause();
        vm.prank(newOwner);
        vault.unpause();
    }

    // ------------------------------------------------------------ precision / scale

    /// USDC has 6 decimals; test at 10 trillion USDC-scale supply (1e19 base units) for overflow/rounding safety.
    function testFuzz_largeScaleAccounting(uint256 dep, uint256 alloc, uint256 loss) public {
        dep = bound(dep, 1e6, 1e19);
        usdc.mint(owner, dep);
        usdc.mint(address(pool), dep);
        vm.prank(owner);
        vault.deposit(dep);
        uint256 total = DEPOSIT + dep;
        alloc = bound(alloc, 0, (total * 8000) / 10_000);
        vm.prank(agent);
        vault.rebalance(aave, alloc);
        assertEq(vault.totalValue(), total);
        assertEq(vault.highWaterMark(), total);
        loss = bound(loss, 0, alloc);
        if (loss > 0) pool.impair(aave, loss);
        uint256 dd = vault.drawdownBps();
        assertEq(dd, (loss * 10_000) / total);
        assertEq(vault.canTrip(), dd >= 1000);
        if (vault.canTrip()) {
            vault.trip();
            assertEq(vault.strategyAssets(aave), 0);
            assertEq(vault.cash(), total - loss);
        }
    }

    function testFuzz_allocationBpsMatchesCap(uint256 alloc) public {
        alloc = bound(alloc, 0, 80_000e6);
        vm.prank(agent);
        vault.rebalance(aave, alloc);
        assertLe(vault.allocationBps(aave), 8000);
    }

    function test_allocationBps_emptyVault() public {
        vm.prank(owner);
        vault.withdraw(owner, DEPOSIT);
        assertEq(vault.allocationBps(aave), 0);
        assertEq(vault.allocationBps(stranger), 0);
    }
}
