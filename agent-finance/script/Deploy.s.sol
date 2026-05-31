// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CreditAgentFinance} from "../src/CreditAgentFinance.sol";

/// @title Deploy
/// @notice Deploys CreditAgentFinance to whichever CreditChain network the
///         `--rpc-url` flag points at. Operators run this via
///         `creditchain/deploy/scripts/deploy-agent-finance.sh`, which captures
///         the deployed address and writes it back into the per-network
///         secrets directory.
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy \
///       --rpc-url <devnet|testnet|...> \
///       --private-key $OPERATOR_PRIVATE_KEY \
///       --broadcast \
///       --json
///
/// The contract is deployed by the OpeniBank **operator** account
/// (Foundry account[2] = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC), which
/// is prefunded in genesis. Because we never bump its nonce except via this
/// script, every clean network gets the same deterministic contract
/// address at deployment-time nonce 0.
contract Deploy is Script {
    function run() external returns (CreditAgentFinance deployed) {
        // vm.startBroadcast() picks up --private-key from the forge CLI.
        vm.startBroadcast();
        deployed = new CreditAgentFinance();
        vm.stopBroadcast();

        // Print a parseable line for the shell wrapper to grep for.
        console.log("CreditAgentFinance deployed at:", address(deployed));
        console.log("chain id:", block.chainid);
        console.log("deployer:", msg.sender);
    }
}
