// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ERC8056TokenClasses} from "../src/ERC8056TokenClasses.sol";

contract DeployERC8056TokenClasses is Script {
    function run() external {
        vm.startBroadcast();
        new ERC8056TokenClasses("Classed UI Token", "CUI", msg.sender);
        vm.stopBroadcast();
    }
}
