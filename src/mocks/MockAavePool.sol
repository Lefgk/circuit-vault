// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Mock Aave V3 aToken (6 decimals). Minted/burned only by the mock pool.
contract MockAToken is ERC20 {
    address public immutable UNDERLYING_ASSET_ADDRESS;
    address public POOL;

    constructor(address underlying_) ERC20("Mock aUSDC", "maUSDC") {
        UNDERLYING_ASSET_ADDRESS = underlying_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setPool(address p) external {
        require(POOL == address(0), "already set");
        POOL = p;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == POOL, "only pool");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == POOL, "only pool");
        _burn(from, amount);
    }
}

/// @notice Minimal Aave V3 Pool mock for USDC supply/withdraw. No interest unless
///         a test calls `accrue` (mint extra aTokens) or `impair` (burn aTokens).
contract MockAavePool {
    using SafeERC20 for IERC20;

    address public immutable usdc;
    MockAToken public immutable aToken;

    error ZeroAmount();
    error InsufficientLiquidity();

    constructor(address usdc_, address aToken_) {
        usdc = usdc_;
        aToken = MockAToken(aToken_);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        if (amount == 0) revert ZeroAmount();
        require(asset == usdc, "asset");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(asset == usdc, "asset");
        uint256 bal = aToken.balanceOf(msg.sender);
        if (amount == type(uint256).max) amount = bal;
        if (amount == 0) revert ZeroAmount();
        if (amount > bal) revert InsufficientLiquidity();
        aToken.burn(msg.sender, amount);
        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }

    /// @notice Simulate yield by minting extra aTokens. Backs them with minted USDC if possible.
    function accrue(address user, uint256 extra) external {
        if (extra == 0) revert ZeroAmount();
        aToken.mint(user, extra);
    }

    /// @notice Simulate a loss by burning aTokens. Remaining USDC stays in the pool for withdraws
    ///         of the leftover principal (tests use this to trip the vault breaker).
    function impair(address user, uint256 loss) external {
        if (loss == 0) revert ZeroAmount();
        aToken.burn(user, loss);
    }
}
