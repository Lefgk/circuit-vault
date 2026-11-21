// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Official, hard-coded addresses for Ethereum mainnet, Base and local anvil.
///         Deploy scripts and fork tests must use these; they are never taken from user input.
library DeployConfig {
    struct Chain {
        string name;
        bool isMainnet;
        address usdc;
        address pool;
        address poolAddressesProvider;
        address aToken;
    }

    uint256 internal constant ETHEREUM = 1;
    uint256 internal constant BASE = 8453;
    uint256 internal constant ANVIL = 31337;

    address internal constant USDC_ETHEREUM = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant POOL_ETHEREUM = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant POOL_BASE = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant PROVIDER_ETHEREUM = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address internal constant PROVIDER_BASE = 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D;
    // Official Aave V3 aUSDC (verified on fork via UNDERLYING_ASSET_ADDRESS + POOL).
    address internal constant ATOKEN_ETHEREUM = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address internal constant ATOKEN_BASE = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;

    function get(uint256 chainId) internal pure returns (Chain memory) {
        if (chainId == ETHEREUM) {
            return Chain("Ethereum mainnet", true, USDC_ETHEREUM, POOL_ETHEREUM, PROVIDER_ETHEREUM, ATOKEN_ETHEREUM);
        }
        if (chainId == BASE) {
            return Chain("Base", true, USDC_BASE, POOL_BASE, PROVIDER_BASE, ATOKEN_BASE);
        }
        if (chainId == ANVIL) {
            return Chain("Local anvil", false, address(0), address(0), address(0), address(0));
        }
        revert("DeployConfig: unsupported chain (only 1, 8453, 31337)");
    }
}
