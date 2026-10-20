// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";
import { Standards } from "./Standards.sol";

/// Deploys (or confirms) every standard at its deterministic address on the target chain.
///
///   Dry run, prints addresses:   forge script script/DeployStandards.s.sol --rpc-url <rpc>
///   Deploy:                      forge script script/DeployStandards.s.sol --rpc-url <rpc> \
///                                  --broadcast --account <keystore-name>
///   TESTNET=true selects the ERC-8004 testnet registries for PaidReviews.
///
/// Idempotent: a contract already at its address is left alone. Anyone may run it on any chain;
/// the result is the same contracts at the same addresses whoever pays the gas.
contract DeployStandards is Script {
    function run() external {
        bool testnet = vm.envOr("TESTNET", false);
        require(
            Standards.DEPLOYER.code.length != 0, "no deterministic-deployment proxy on this chain"
        );

        vm.startBroadcast();
        address vault = Standards.deploy(Standards.SALT_VAULT, Standards.vaultInitCode());
        address escape = Standards.deploy(Standards.SALT_ESCAPE, Standards.escapeInitCode());
        address reviews =
            Standards.deploy(Standards.SALT_REVIEWS, Standards.reviewsInitCode(testnet));
        vm.stopBroadcast();

        console2.log("chainId                ", block.chainid);
        console2.log("AgentMandateVault      ", vault);
        console2.log("QuantumEscapeRegistry  ", escape);
        console2.log("PaidReviews            ", reviews);
        console2.log("PaidReviews registries ", testnet ? "ERC-8004 testnet" : "ERC-8004 mainnet");
    }
}
