// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ERC8056} from "../src/ERC8056.sol";

contract DeployERC8056 is Script {
    function run() external {
        vm.startBroadcast();
        new ERC8056("Scaled UI Token", "SUI", msg.sender);
        vm.stopBroadcast();
    }
}
