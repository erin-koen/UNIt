// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../lib/forge-std/src/Script.sol";
import "../lib/v4-core/src/interfaces/IPoolManager.sol";
import "../lib/v4-core/src/types/PoolKey.sol";
import "../lib/v4-core/src/types/Currency.sol";
import "../lib/v4-core/src/libraries/TickMath.sol";
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
            hooks: IHooks(hook)
        });

        // Initialize the pool with 1:1 price ratio
        uint160 initialSqrtPriceX96 = uint160(1 << 96); // 1:1 price ratio
        IPoolManager(poolManager).initialize(poolKey, initialSqrtPriceX96);

        console2.log("Pool initialized with key:");
        console2.log("Currency0:", collateralToken);
        console2.log("Currency1:", unitToken);
        console2.log("Fee:", poolKey.fee);
        console2.log("TickSpacing:", poolKey.tickSpacing);
        console2.log("Hooks:", address(poolKey.hooks));
        console2.log("Initial sqrtPriceX96:", uint256(initialSqrtPriceX96));

        vm.stopBroadcast();
    }
}
