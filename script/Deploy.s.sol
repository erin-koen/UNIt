// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/UNIt.sol";
import "../src/UNItHook.sol";
import "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy UNIt token
        UNIt unitToken = new UNIt(address(0)); // Revenue recipient will be set later

        // Deploy UNItHook
        address poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        address collateralToken = vm.envAddress("COLLATERAL_TOKEN_ADDRESS");
        UNItHook hook = new UNItHook(poolManager, address(unitToken), collateralToken);

        // Log deployed addresses
        console2.log("UNIt Token deployed at:", address(unitToken));
        console2.log("UNItHook deployed at:", address(hook));

        vm.stopBroadcast();
    }
}
