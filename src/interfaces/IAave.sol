// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Aave V3 Pool surface used by AaveV3UsdcAdapter.
interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IPoolAddressesProvider {
    function getPool() external view returns (address);
}

/// @notice Aave V3 aToken used to mark USDC supplied through the adapter.
interface IAToken {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
    function POOL() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
}
