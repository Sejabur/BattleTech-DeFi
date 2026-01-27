// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/BattleEngine.sol";
import {UniversalRouter} from "@uniswap/universal-router/contracts/UniversalRouter.sol";

/**
 * @title Deploy
 * @notice This script deploys the BattleEngine contract on Base.
 */
contract Deploy is Script {
    function run() external {
        // Load deployer's private key.
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey); // Explicitly derive the deployer's address

        console.log("Deployer address (Expected):", deployer);

        // Load configuration addresses.
        address universalRouterAddress = vm.envAddress("UNIVERSAL_ROUTER_ADDRESS");
        address admin = vm.envAddress("ADMIN_ADDRESS");

        // Set fee parameters.
        uint256 platformFee = 200; // 2%
        uint256 highestBidderFee = 0; // 0%
        uint256 poolFee = 200; // 2%

        //Ensure transactions are sent from the correct account
        vm.startBroadcast(deployerKey);

        //Pass the explicit deployer address as the owner
        BattleEngine battleEngine = new BattleEngine(
            deployer,  // Owner should be the deployer!
            UniversalRouter(payable(universalRouterAddress)),
            payable(admin),
            platformFee,
            highestBidderFee,
            poolFee
        );

        console.log("BattleEngine deployed at:", address(battleEngine));
        console.log("Contract Owner:", battleEngine.owner()); //Print actual owner after deployment

        vm.stopBroadcast();
    }
}
