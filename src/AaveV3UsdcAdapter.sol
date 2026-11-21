// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IPool, IAToken} from "./interfaces/IAave.sol";

/// @title AaveV3UsdcAdapter
/// @notice Per-vault adapter that supplies USDC to the official Aave V3 Pool and
///         reports aToken balance as NAV. Only the owning vault may deposit or withdraw.
/// @dev    PROTOTYPE - NOT AUDITED.
contract AaveV3UsdcAdapter is IStrategy {
    using SafeERC20 for IERC20;

    address public immutable vault;
    address public immutable usdc;
    IPool public immutable pool;
    address public immutable aToken;

    error NotVault();
    error ZeroAddress();
    error ZeroAmount();
    error BadAToken();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(address vault_, address usdc_, address pool_, address aToken_) {
        if (vault_ == address(0) || usdc_ == address(0) || pool_ == address(0) || aToken_ == address(0)) {
            revert ZeroAddress();
        }
        if (IAToken(aToken_).UNDERLYING_ASSET_ADDRESS() != usdc_) revert BadAToken();
        if (IAToken(aToken_).POOL() != pool_) revert BadAToken();
        vault = vault_;
        usdc = usdc_;
        pool = IPool(pool_);
        aToken = aToken_;
        IERC20(usdc_).forceApprove(pool_, type(uint256).max);
    }

    function asset() external view returns (address) {
        return usdc;
    }

    function totalAssets() public view returns (uint256) {
        return IAToken(aToken).balanceOf(address(this));
    }

    function deposit(uint256 amount) external onlyVault {
        if (amount == 0) revert ZeroAmount();
        IERC20(usdc).safeTransferFrom(vault, address(this), amount);
        pool.supply(usdc, amount, address(this), 0);
    }

    function withdraw(uint256 amount) external onlyVault returns (uint256 withdrawn) {
        if (amount == 0) revert ZeroAmount();
        withdrawn = pool.withdraw(usdc, amount, vault);
    }

    function withdrawAll() external onlyVault returns (uint256 withdrawn) {
        uint256 bal = totalAssets();
        if (bal == 0) return 0;
        withdrawn = pool.withdraw(usdc, type(uint256).max, vault);
    }
}
