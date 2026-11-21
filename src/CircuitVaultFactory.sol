// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CircuitVault} from "./CircuitVault.sol";

/// @title CircuitVaultFactory
/// @notice Deploys one CircuitVault per call, owned by the caller, wired to this chain's
///         official USDC, Aave V3 Pool and aUSDC token. Default breaker is 10% drawdown
///         and the v1 Aave adapter is capped at 80%.
contract CircuitVaultFactory {
    address public immutable usdc;
    address public immutable pool;
    address public immutable aToken;

    mapping(address owner => address[]) internal _vaultsOf;

    event VaultCreated(address indexed owner, address indexed vault, address aaveStrategy);

    error ZeroAddress();

    constructor(address usdc_, address pool_, address aToken_) {
        if (usdc_ == address(0) || pool_ == address(0) || aToken_ == address(0)) revert ZeroAddress();
        usdc = usdc_;
        pool = pool_;
        aToken = aToken_;
    }

    function createVault() external returns (address vault) {
        CircuitVault v = new CircuitVault(
            msg.sender,
            usdc,
            pool,
            aToken,
            1000, // DEFAULT_MAX_DRAWDOWN_BPS (10%)
            8000 // DEFAULT_AAVE_CAP_BPS (80%)
        );
        vault = address(v);
        _vaultsOf[msg.sender].push(vault);
        emit VaultCreated(msg.sender, vault, v.aaveStrategy());
    }

    /// @notice Create a vault with a custom drawdown limit and Aave allocation cap.
    function createVaultWithPolicy(uint16 maxDrawdownBps, uint16 aaveCapBps) external returns (address vault) {
        CircuitVault v = new CircuitVault(msg.sender, usdc, pool, aToken, maxDrawdownBps, aaveCapBps);
        vault = address(v);
        _vaultsOf[msg.sender].push(vault);
        emit VaultCreated(msg.sender, vault, v.aaveStrategy());
    }

    function vaultsOf(address owner) external view returns (address[] memory) {
        return _vaultsOf[owner];
    }
}
