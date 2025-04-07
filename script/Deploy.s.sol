// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../lib/forge-std/src/Script.sol";
import "../src/UNIt.sol";
import "../src/UNItHook.sol";
import "../lib/v4-core/src/interfaces/IPoolManager.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy UNIt token
        address revenueRecipient = vm.envAddress("REVENUE_RECIPIENT_ADDRESS");
        UNIt unitToken = new UNIt(revenueRecipient);

        // Deploy UNItHook
        address poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        address collateralToken = vm.envAddress("COLLATERAL_TOKEN_ADDRESS");
        UNItHook hook = new UNItHook(poolManager, address(unitToken), collateralToken);

        // Log deployed addresses
        console2.log("UNIt Token deployed at:", address(unitToken));
        console2.log("UNItHook deployed at:", address(hook));
        console2.log("Revenue recipient set to:", revenueRecipient);

        vm.stopBroadcast();
    }
}
