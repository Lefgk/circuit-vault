// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice USDC strategy adapter. May only be called by its vault. Funds leave the
///         adapter only back to the vault (or into the approved venue, e.g. Aave).
interface IStrategy {
    function asset() external view returns (address);
    function vault() external view returns (address);
    function totalAssets() external view returns (uint256);
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external returns (uint256 withdrawn);
    function withdrawAll() external returns (uint256 withdrawn);
}
