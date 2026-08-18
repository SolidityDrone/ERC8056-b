// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ScaledUIToken} from "../src/ScaledUIToken.sol";

contract DeployScaledUIToken is Script {
    function run() external {
        vm.startBroadcast();
        new ScaledUIToken("Scaled UI Token", "SUI", msg.sender);
        vm.stopBroadcast();
    }
}
