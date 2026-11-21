// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/// @notice Simple in-vault USDC holding strategy for unit tests.
contract MockStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public immutable vault;
    address public immutable usdc;
    uint256 public held;

    error NotVault();
    error ZeroAmount();

    constructor(address vault_, address usdc_) {
        vault = vault_;
        usdc = usdc_;
    }

    function asset() external view returns (address) {
        return usdc;
    }

    function totalAssets() public view returns (uint256) {
        return held;
    }

    function deposit(uint256 amount) external {
        if (msg.sender != vault) revert NotVault();
        if (amount == 0) revert ZeroAmount();
        IERC20(usdc).safeTransferFrom(vault, address(this), amount);
        held += amount;
    }

    function withdraw(uint256 amount) external returns (uint256) {
        if (msg.sender != vault) revert NotVault();
        if (amount == 0) revert ZeroAmount();
        if (amount > held) amount = held;
        held -= amount;
        IERC20(usdc).safeTransfer(vault, amount);
        return amount;
    }

    function withdrawAll() external returns (uint256 amount) {
        if (msg.sender != vault) revert NotVault();
        amount = held;
        if (amount == 0) return 0;
        held = 0;
        IERC20(usdc).safeTransfer(vault, amount);
    }

    /// @notice Test hook: steal or lose funds so the breaker can be tripped.
    function impair(uint256 loss) external {
        if (loss > held) loss = held;
        held -= loss;
        IERC20(usdc).safeTransfer(msg.sender, loss);
    }

    function accrue(uint256 extra) external {
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), extra);
        held += extra;
    }
}
