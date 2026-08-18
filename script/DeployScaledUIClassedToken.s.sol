// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ScaledUIClassedToken} from "../src/ScaledUIClassedToken.sol";

contract DeployScaledUIClassedToken is Script {
    function run() external {
        vm.startBroadcast();
        new ScaledUIClassedToken("Classed UI Token", "CUI", msg.sender);
        vm.stopBroadcast();
    }
}
