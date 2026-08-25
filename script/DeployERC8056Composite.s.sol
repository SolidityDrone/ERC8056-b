// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ERC8056Composite} from "../src/ERC8056Composite.sol";

contract DeployERC8056Composite is Script {
    function run() external {
        vm.startBroadcast();
        new ERC8056Composite("Classed UI Token", "CUI", msg.sender);
        vm.stopBroadcast();
    }
}
