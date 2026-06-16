// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentSpendVault} from "../src/AgentSpendVault.sol";

/// Deploys the AgentSpendVault. Broadcast with the operator key:
///   forge script script/DeployAgentSpendVault.s.sol --rpc-url testnet \
///     --private-key $PRIVATE_KEY --broadcast
contract DeployAgentSpendVault is Script {
    function run() external returns (AgentSpendVault vault) {
        vm.startBroadcast();
        vault = new AgentSpendVault();
        console.log("AgentSpendVault deployed at:", address(vault));
        vm.stopBroadcast();
    }
}
