// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CreditAgentFinance} from "../src/CreditAgentFinance.sol";

/// @title Deploy
/// @notice Deploys CreditAgentFinance to whichever CreditChain network the
///         `--rpc-url` flag points at.
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy \
///       --rpc-url <testnet|argos_testnet|...> \
///       --private-key $PRIVATE_KEY \
///       --broadcast \
///       --json
///
/// The address depends only on the deployer and its nonce. A deployer
/// dedicated to this script, used at nonce 0, gets the same address on every
/// fresh network.
contract Deploy is Script {
    function run() external returns (CreditAgentFinance deployed) {
        // vm.startBroadcast() picks up --private-key from the forge CLI.
        vm.startBroadcast();
        deployed = new CreditAgentFinance();
        vm.stopBroadcast();

        // Parseable output for whatever records the deployment.
        console.log("CreditAgentFinance deployed at:", address(deployed));
        console.log("chain id:", block.chainid);
        console.log("deployer:", msg.sender);
    }
}
