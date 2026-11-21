// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CircuitVault} from "../../src/CircuitVault.sol";
import {CircuitVaultFactory} from "../../src/CircuitVaultFactory.sol";
import {AaveV3UsdcAdapter} from "../../src/AaveV3UsdcAdapter.sol";
import {DeployConfig} from "../../script/DeployConfig.sol";
import {IPoolAddressesProvider, IAToken} from "../../src/interfaces/IAave.sol";

interface IFiatToken {
    function masterMinter() external view returns (address);
    function configureMinter(address minter, uint256 minterAllowedAmount) external returns (bool);
    function mint(address to, uint256 amount) external returns (bool);
}

/// @dev Runs against a fork of a live chain using the real Aave V3 Pool and Circle USDC.
///      Either run `forge test --fork-url <rpc>` (only the matching chain's suite runs), or set
///      MAINNET_FORK_RPC / BASE_FORK_RPC (e.g. a local `anvil --fork-url` on port 8629). Otherwise skipped.
abstract contract ForkBase is Test {
    CircuitVaultFactory factory;
    CircuitVault vault;
    IERC20Metadata usdc;
    address aave;
    address owner = makeAddr("fork-owner");
    address agent = makeAddr("fork-agent");
    address stranger = makeAddr("fork-stranger");
    bool active;

    uint256 constant DEPOSIT = 50_000e6;

    function _rpcEnv() internal pure virtual returns (string memory);
    function _chainId() internal pure virtual returns (uint256);

    function setUp() public {
        if (block.chainid == _chainId()) {
            // already running on this chain's fork
        } else if (block.chainid == 31337) {
            string memory rpc = vm.envOr(_rpcEnv(), string(""));
            if (bytes(rpc).length == 0) return;
            vm.createSelectFork(rpc);
        } else {
            return;
        }
        active = true;
        assertEq(block.chainid, _chainId(), "wrong fork chain");

        DeployConfig.Chain memory c = DeployConfig.get(block.chainid);
        usdc = IERC20Metadata(c.usdc);

        factory = new CircuitVaultFactory(c.usdc, c.pool, c.aToken);
        vm.prank(owner);
        vault = CircuitVault(factory.createVault());
        aave = vault.aaveStrategy();

        _fundUsdc(owner, 200_000e6);
        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(DEPOSIT);
        vault.grantAgent(agent, uint64(block.timestamp + 30 days));
        vm.stopPrank();
    }

    modifier onFork() {
        if (!active) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_officialAddressesAndMetadata() public onFork {
        DeployConfig.Chain memory c = DeployConfig.get(block.chainid);
        assertGt(c.pool.code.length, 0, "pool has no code");
        assertGt(c.usdc.code.length, 0, "usdc has no code");
        assertGt(c.aToken.code.length, 0, "aToken has no code");
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        address fromProvider = IPoolAddressesProvider(c.poolAddressesProvider).getPool();
        assertEq(fromProvider, c.pool, "address book pool != provider.getPool()");
        assertEq(c.pool, _chainId() == 1
            ? address(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2)
            : address(0xA238Dd80C259a72e81d7e4664a9801593F98d1c5));
        assertEq(IAToken(c.aToken).UNDERLYING_ASSET_ADDRESS(), c.usdc);
        assertEq(IAToken(c.aToken).POOL(), c.pool);
        assertEq(address(AaveV3UsdcAdapter(aave).pool()), c.pool);
        assertEq(AaveV3UsdcAdapter(aave).aToken(), c.aToken);
        assertEq(vault.usdc(), c.usdc);
    }

    function test_fork_depositRebalanceIntoAaveAndBack() public onFork {
        assertEq(vault.cash(), DEPOSIT);
        assertEq(vault.strategyAssets(aave), 0);

        vm.prank(agent);
        vault.rebalance(aave, 40_000e6);

        uint256 inAave = vault.strategyAssets(aave);
        // aToken index rounding can leave a couple of wei below the deposited amount.
        assertApproxEqAbs(inAave, 40_000e6, 10);
        assertEq(vault.cash(), DEPOSIT - 40_000e6);
        assertApproxEqAbs(vault.totalValue(), DEPOSIT, 10);
        assertLe(inAave * 10_000, vault.totalValue() * 8000);

        // Pull most of it back to cash.
        vm.prank(agent);
        vault.rebalance(aave, 1_000e6);
        assertApproxEqAbs(vault.strategyAssets(aave), 1_000e6, 2e6);
        assertApproxEqAbs(vault.cash(), DEPOSIT - 1_000e6, 2e6);

        // A full cash withdraw would push the remaining Aave sleeve over its cap, so exit first.
        vm.prank(owner);
        vault.exitStrategy(aave);
        assertEq(vault.strategyAssets(aave), 0);
        uint256 before = usdc.balanceOf(owner);
        uint256 cashBal = vault.cash();
        vm.prank(owner);
        vault.withdraw(owner, cashBal);
        assertEq(usdc.balanceOf(owner), before + cashBal);
        assertEq(vault.totalValue(), 0);
    }

    function test_fork_capBlocksOverAllocation() public onFork {
        vm.prank(agent);
        vm.expectRevert();
        vault.rebalance(aave, 40_001e6); // 80% of 50k is 40k
        assertEq(vault.strategyAssets(aave), 0);
        assertEq(vault.cash(), DEPOSIT);
    }

    function test_fork_pauseRevokeBlockAgent() public onFork {
        vm.prank(owner);
        vault.pause();
        vm.prank(agent);
        vm.expectRevert();
        vault.rebalance(aave, 1_000e6);
        vm.prank(owner);
        vault.unpause();

        vm.prank(owner);
        vault.revokeAgent(agent);
        vm.prank(agent);
        vm.expectRevert(CircuitVault.NotAgent.selector);
        vault.rebalance(aave, 1_000e6);
    }

    function test_fork_tripViaMockedDrawdownBlocksAgent() public onFork {
        vm.prank(agent);
        vault.rebalance(aave, 20_000e6);

        // Disable auto-exit first so trip() only sets the flag. Real Aave USDC will not
        // drop 10% here; we mock the aToken balance down to create a drawdown.
        vm.prank(owner);
        vault.setAutoExitOnTrip(false);

        address aToken_ = AaveV3UsdcAdapter(aave).aToken();
        uint256 held = IAToken(aToken_).balanceOf(aave);
        vm.mockCall(
            aToken_,
            abi.encodeWithSelector(IAToken.balanceOf.selector, aave),
            abi.encode(held / 2)
        );
        // totalValue now ~= cash 30k + 10k = 40k, HWM 50k, dd ~= 2000 bps.
        assertTrue(vault.canTrip());
        vm.prank(stranger);
        vault.trip();
        assertTrue(vault.tripped());
        vm.clearMockedCalls();

        vm.prank(agent);
        vm.expectRevert(CircuitVault.BreakerTripped.selector);
        vault.rebalance(aave, 0);
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_fork_capsHold(uint256 t1, uint256 t2) public onFork {
        t1 = bound(t1, 0, 60_000e6);
        t2 = bound(t2, 0, 60_000e6);
        vm.prank(agent);
        try vault.rebalance(aave, t1) {} catch {}
        vm.prank(agent);
        try vault.rebalance(aave, t2) {} catch {}
        uint256 held = vault.strategyAssets(aave);
        uint256 tv = vault.totalValue();
        if (held > 0 && tv > 0) {
            assertLe(held * 10_000, tv * 8000);
        }
        assertEq(usdc.balanceOf(agent), 0);
    }

    function _fundUsdc(address to, uint256 amount) internal {
        deal(address(usdc), to, amount, true);
        if (usdc.balanceOf(to) >= amount) return;

        try IFiatToken(address(usdc)).masterMinter() returns (address mm) {
            if (mm != address(0) && mm.code.length > 0) {
                vm.prank(mm);
                IFiatToken(address(usdc)).configureMinter(address(this), type(uint256).max);
                IFiatToken(address(usdc)).mint(to, amount);
            }
        } catch {}
        require(usdc.balanceOf(to) >= amount, "could not fund USDC on this fork");
    }
}

contract EthereumForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "MAINNET_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 1;
    }
}

contract BaseForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }
}
