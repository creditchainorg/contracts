// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AgentReputation} from "../src/AgentReputation.sol";

/// Deploys AgentReputation, bound to an existing AgentSpendVault.
/// Usage: AGENT_VAULT=0x... forge script script/DeployAgentReputation.s.sol \
///   --rpc-url <rpc> --private-key <key> --broadcast
contract DeployAgentReputation is Script {
    function run() external {
        address vault = vm.envAddress("AGENT_VAULT");
        vm.startBroadcast();
        AgentReputation rep = new AgentReputation(vault);
        vm.stopBroadcast();
        console2.log("AgentReputation deployed:", address(rep));
        console2.log("bound to vault:", vault);
    }
}
