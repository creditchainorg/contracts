// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {HelloCreditChain} from "../src/HelloCreditChain.sol";

contract Deploy is Script {
    function run() external returns (HelloCreditChain deployed) {
        vm.startBroadcast();
        deployed = new HelloCreditChain("Hello, CreditChain");
        vm.stopBroadcast();

        console2.log("HELLO_CREDITCHAIN_ADDRESS=%s", address(deployed));
    }
}
