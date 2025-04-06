// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/contracts/libraries/PoolKey.sol";
import "@uniswap/v4-core/contracts/libraries/Currency.sol";
import "../src/UNItHook.sol";

contract SetupPoolScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Get contract addresses from environment
        address poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        address hook = vm.envAddress("UNIT_HOOK_ADDRESS");
        address collateralToken = vm.envAddress("COLLATERAL_TOKEN_ADDRESS");
        address unitToken = vm.envAddress("UNIT_TOKEN_ADDRESS");

        // Create pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(collateralToken),
            currency1: Currency.wrap(unitToken),
            fee: 3000, // 0.3% fee tier
            tickSpacing: 60,
            hooks: hook
        });

        // Initialize the pool
        IPoolManager(poolManager).initialize(poolKey, 0);

        console2.log("Pool initialized with key:");
        console2.log("Currency0:", collateralToken);
        console2.log("Currency1:", unitToken);
        console2.log("Fee:", poolKey.fee);
        console2.log("TickSpacing:", poolKey.tickSpacing);
        console2.log("Hooks:", poolKey.hooks);

        vm.stopBroadcast();
    }
}
