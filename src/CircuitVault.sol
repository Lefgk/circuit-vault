// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {AaveV3UsdcAdapter} from "./AaveV3UsdcAdapter.sol";

/// @title CircuitVault
/// @notice Personal USDC vault. An authorized agent may rebalance only between cash
///         and owner-whitelisted strategies, within per-strategy allocation caps.
///         A high-water-mark drawdown breaker lets anyone trip() once loss reaches
///         the owner's maxDrawdownBps; that pauses the agent and can exit to USDC.
///         The owner deposits, withdraws, pauses and revokes.
/// @dev    PROTOTYPE - NOT AUDITED. v1 ships one Aave V3 USDC supply adapter.
///         Not a public ERC-4626 fund. USDC only.
contract CircuitVault is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOM = 10_000;
    uint16 public constant DEFAULT_MAX_DRAWDOWN_BPS = 1000; // 10%
    uint16 public constant DEFAULT_AAVE_CAP_BPS = 8000; // 80%
    uint16 public constant MIN_DRAWDOWN_BPS = 1;
    /// @dev If a strategy exit fails with less than this much gas left, assume the caller
    ///      starved the call (63/64 rule) and revert instead of latching a half-done exit.
    uint256 internal constant EXIT_GAS_RESERVE = 50_000;

    struct Agent {
        bool active;
        uint64 expiry;
    }

    struct StrategyConfig {
        bool allowed;
        uint16 capBps;
        uint32 index; // 1-based index into strategyList; 0 = never listed
    }

    address public immutable usdc;
    address public immutable aaveStrategy;

    address public guardian;
    uint16 public maxDrawdownBps;
    bool public autoExitOnTrip;
    bool public tripped;
    uint256 public highWaterMark;

    mapping(address agent => Agent) public agents;
    mapping(address strategy => StrategyConfig) public strategies;
    address[] internal _strategyList;

    event Deposited(address indexed from, uint256 amount, uint256 totalValue, uint256 highWaterMark);
    event Withdrawn(address indexed to, uint256 amount, uint256 totalValue, uint256 highWaterMark);
    event GuardianSet(address indexed guardian);
    event AgentGranted(address indexed agent, uint64 expiry);
    event AgentRevoked(address indexed agent, address indexed by);
    event StrategySet(address indexed strategy, bool allowed, uint16 capBps);
    event MaxDrawdownSet(uint16 bps);
    event AutoExitOnTripSet(bool enabled);
    event Rebalanced(address indexed caller, address indexed strategy, uint256 targetAssets, uint256 held, uint256 totalValue);
    event HighWaterMarkSet(uint256 highWaterMark);
    event Tripped(address indexed caller, uint256 totalValue, uint256 highWaterMark, uint256 drawdownBps, bool exited);
    event BreakerReset(address indexed by, uint256 highWaterMark);
    event StrategyExited(address indexed strategy, uint256 withdrawn);
    event StrategyExitFailed(address indexed strategy, bytes reason);

    error NotAgent();
    error AgentExpired();
    error BreakerTripped();
    error DrawdownLimitHit();
    error CannotTrip();
    error StrategyNotAllowed();
    error ExceedsAllocationCap(uint256 held, uint256 totalValue, uint16 capBps);
    error InsufficientCash();
    error InsufficientStrategyAssets();
    error InvalidCap();
    error InvalidDrawdown();
    error InvalidExpiry();
    error ZeroAddress();
    error ZeroAmount();
    error NotOwnerOrGuardian();
    error StrategyHasAssets();
    error BadStrategy();
    error AlreadyListed();
    error ExitOutOfGas();

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && msg.sender != guardian) revert NotOwnerOrGuardian();
        _;
    }

    constructor(address initialOwner, address usdc_, address pool_, address aToken_, uint16 maxDrawdownBps_, uint16 aaveCapBps_)
        Ownable(initialOwner)
    {
        if (usdc_ == address(0) || pool_ == address(0) || aToken_ == address(0) || initialOwner == address(0)) {
            revert ZeroAddress();
        }
        if (maxDrawdownBps_ < MIN_DRAWDOWN_BPS || maxDrawdownBps_ > BPS_DENOM) revert InvalidDrawdown();
        if (aaveCapBps_ == 0 || aaveCapBps_ > BPS_DENOM) revert InvalidCap();
        usdc = usdc_;
        maxDrawdownBps = maxDrawdownBps_;
        autoExitOnTrip = true;

        AaveV3UsdcAdapter adapter = new AaveV3UsdcAdapter(address(this), usdc_, pool_, aToken_);
        aaveStrategy = address(adapter);
        _setStrategy(address(adapter), true, aaveCapBps_);
    }

    // ------------------------------------------------------------------ views

    function cash() public view returns (uint256) {
        return IERC20(usdc).balanceOf(address(this));
    }

    function strategyCount() external view returns (uint256) {
        return _strategyList.length;
    }

    function strategyAt(uint256 i) external view returns (address) {
        return _strategyList[i];
    }

    function strategyAssets(address strategy) public view returns (uint256) {
        if (strategies[strategy].index == 0) return 0;
        return IStrategy(strategy).totalAssets();
    }

    /// @notice Cash plus NAV of every listed strategy (including disabled ones that still hold assets).
    function totalValue() public view returns (uint256 v) {
        v = cash();
        uint256 n = _strategyList.length;
        for (uint256 i; i < n; ++i) {
            v += IStrategy(_strategyList[i]).totalAssets();
        }
    }

    /// @notice Current drawdown from the high-water mark, in bps. 0 if at or above the mark.
    function drawdownBps() public view returns (uint256) {
        uint256 hwm = highWaterMark;
        if (hwm == 0) return 0;
        uint256 v = totalValue();
        if (v >= hwm) return 0;
        return ((hwm - v) * BPS_DENOM) / hwm;
    }

    /// @notice True when NAV has fallen to or below the owner's max drawdown from the HWM.
    function canTrip() public view returns (bool) {
        if (tripped || highWaterMark == 0) return false;
        return drawdownBps() >= maxDrawdownBps;
    }

    function allocationBps(address strategy) external view returns (uint256) {
        uint256 v = totalValue();
        if (v == 0) return 0;
        return (strategyAssets(strategy) * BPS_DENOM) / v;
    }

    // ------------------------------------------------------------------ funding (owner)

    /// @notice Pull USDC from the owner into cash. Raises the high-water mark by `amount`
    ///         so a deposit cannot erase an existing drawdown.
    function deposit(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);
        highWaterMark += amount;
        uint256 v = totalValue();
        emit Deposited(msg.sender, amount, v, highWaterMark);
        emit HighWaterMarkSet(highWaterMark);
    }

    /// @notice Withdraw USDC from cash to `to`. Does not unwind strategies; call
    ///         `exitStrategy` / `exitAll` first if you need more than cash. Works while
    ///         paused or tripped so funds are never stuck. Scales the HWM pro-rata.
    function withdraw(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 v = totalValue();
        if (amount > cash()) revert InsufficientCash();
        if (v > 0) {
            highWaterMark = (highWaterMark * (v - amount)) / v;
        }
        IERC20(usdc).safeTransfer(to, amount);
        _assertCaps();
        emit Withdrawn(to, amount, totalValue(), highWaterMark);
        emit HighWaterMarkSet(highWaterMark);
    }

    // ------------------------------------------------------------------ admin

    function setGuardian(address newGuardian) external onlyOwner {
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }

    function grantAgent(address agent, uint64 expiry) external onlyOwner {
        if (agent == address(0)) revert ZeroAddress();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        agents[agent] = Agent({active: true, expiry: expiry});
        emit AgentGranted(agent, expiry);
    }

    function revokeAgent(address agent) external onlyOwnerOrGuardian {
        agents[agent] = Agent({active: false, expiry: 0});
        emit AgentRevoked(agent, msg.sender);
    }

    function pause() external onlyOwnerOrGuardian {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setMaxDrawdownBps(uint16 bps) external onlyOwner {
        if (bps < MIN_DRAWDOWN_BPS || bps > BPS_DENOM) revert InvalidDrawdown();
        maxDrawdownBps = bps;
        emit MaxDrawdownSet(bps);
    }

    function setAutoExitOnTrip(bool enabled) external onlyOwner {
        autoExitOnTrip = enabled;
        emit AutoExitOnTripSet(enabled);
    }

    /// @notice Whitelist or update a strategy cap. A new strategy is trusted by the owner;
    ///         a malicious adapter could pull funds. To disable, set `allowed=false` after
    ///         exiting any residual assets.
    function setStrategy(address strategy, bool allowed, uint16 capBps) external onlyOwner {
        if (strategy == address(0)) revert ZeroAddress();
        if (allowed && (capBps == 0 || capBps > BPS_DENOM)) revert InvalidCap();
        if (!allowed && IStrategy(strategy).totalAssets() != 0) revert StrategyHasAssets();
        if (allowed) {
            if (IStrategy(strategy).asset() != usdc) revert BadStrategy();
            if (IStrategy(strategy).vault() != address(this)) revert BadStrategy();
        }
        _setStrategy(strategy, allowed, allowed ? capBps : uint16(0));
    }

    /// @notice Owner (or guardian) unwind of one strategy back to cash. Works while paused or tripped.
    function exitStrategy(address strategy) external onlyOwnerOrGuardian nonReentrant {
        uint256 withdrawn = IStrategy(strategy).withdrawAll();
        emit StrategyExited(strategy, withdrawn);
        _checkpoint();
    }

    function exitAll() external onlyOwnerOrGuardian nonReentrant {
        _exitAll();
        _checkpoint();
    }

    /// @notice Clear the breaker after a trip. Does not unpause; call `unpause` separately if needed.
    function resetTrip() external onlyOwner {
        tripped = false;
        _checkpoint();
        emit BreakerReset(msg.sender, highWaterMark);
    }

    // ------------------------------------------------------------------ agent + breaker

    /// @notice Move one strategy toward `targetAssets` (USDC units). Only cash ↔ this
    ///         strategy. Reverts if the vault is paused, tripped, or already past the
    ///         drawdown limit, or if the resulting allocation exceeds the strategy cap.
    function rebalance(address strategy, uint256 targetAssets) external nonReentrant whenNotPaused {
        _onlyActiveAgent();
        if (tripped) revert BreakerTripped();
        if (canTrip()) revert DrawdownLimitHit();

        StrategyConfig memory s = strategies[strategy];
        if (!s.allowed) revert StrategyNotAllowed();

        uint256 current = IStrategy(strategy).totalAssets();
        if (targetAssets > current) {
            uint256 need = targetAssets - current;
            if (need > cash()) revert InsufficientCash();
            IERC20(usdc).forceApprove(strategy, need);
            IStrategy(strategy).deposit(need);
            IERC20(usdc).forceApprove(strategy, 0);
        } else if (targetAssets < current) {
            uint256 pull = current - targetAssets;
            uint256 got = IStrategy(strategy).withdraw(pull);
            if (got == 0) revert InsufficientStrategyAssets();
        }

        uint256 held = IStrategy(strategy).totalAssets();
        uint256 tv = totalValue();
        if (held > 0 && (tv == 0 || held * BPS_DENOM > tv * s.capBps)) {
            revert ExceedsAllocationCap(held, tv, s.capBps);
        }

        _checkpoint();
        emit Rebalanced(msg.sender, strategy, targetAssets, held, tv);
    }

    /// @notice Anyone may trip once drawdown reaches the owner's limit. Sets `tripped`,
    ///         blocking the agent, and if `autoExitOnTrip` is set, unwinds every strategy to cash.
    function trip() external nonReentrant {
        if (!canTrip()) revert CannotTrip();
        tripped = true;
        uint256 v = totalValue();
        uint256 dd = drawdownBps();
        bool exited = autoExitOnTrip;
        if (exited) {
            _exitAll();
            v = totalValue();
        }
        emit Tripped(msg.sender, v, highWaterMark, dd, exited);
    }

    /// @notice Raise the high-water mark if NAV has grown (interest). Callable by anyone.
    function checkpoint() external {
        _checkpoint();
    }

    // ------------------------------------------------------------------ internals

    function _onlyActiveAgent() internal view {
        Agent memory a = agents[msg.sender];
        if (!a.active) revert NotAgent();
        if (a.expiry <= block.timestamp) revert AgentExpired();
    }

    function _checkpoint() internal {
        uint256 v = totalValue();
        if (v > highWaterMark) {
            highWaterMark = v;
            emit HighWaterMarkSet(v);
        }
    }

    /// @dev Best effort: one strategy that cannot exit (e.g. Aave at 100% utilization) must not
    ///      block the breaker from latching or the other strategies from exiting. [audit M-1]
    function _exitAll() internal {
        uint256 n = _strategyList.length;
        for (uint256 i; i < n; ++i) {
            address s = _strategyList[i];
            try IStrategy(s).withdrawAll() returns (uint256 withdrawn) {
                if (withdrawn > 0) emit StrategyExited(s, withdrawn);
            } catch (bytes memory reason) {
                if (gasleft() < EXIT_GAS_RESERVE) revert ExitOutOfGas();
                emit StrategyExitFailed(s, reason);
            }
        }
    }

    /// @dev Reverts if any allowed strategy is over its cap. Yield can still drift
    ///      slightly above between actions; this is enforced after owner withdraws and agent rebalances.
    function _assertCaps() internal view {
        uint256 tv = totalValue();
        uint256 n = _strategyList.length;
        for (uint256 i; i < n; ++i) {
            address strat = _strategyList[i];
            StrategyConfig memory s = strategies[strat];
            if (!s.allowed) continue;
            uint256 held = IStrategy(strat).totalAssets();
            if (held > 0 && (tv == 0 || held * BPS_DENOM > tv * s.capBps)) {
                revert ExceedsAllocationCap(held, tv, s.capBps);
            }
        }
    }

    function _setStrategy(address strategy, bool allowed, uint16 capBps) internal {
        StrategyConfig storage s = strategies[strategy];
        if (s.index == 0) {
            _strategyList.push(strategy);
            s.index = uint32(_strategyList.length);
        }
        s.allowed = allowed;
        s.capBps = capBps;
        emit StrategySet(strategy, allowed, capBps);
    }
}
