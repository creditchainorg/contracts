// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";
import { Standards } from "./Standards.sol";

/// Deploys (or confirms) every standard at its deterministic address on the target chain.
///
///   Dry run, prints addresses:   forge script script/DeployStandards.s.sol --rpc-url <rpc>
///   Deploy:                      forge script script/DeployStandards.s.sol --rpc-url <rpc> \
///                                  --broadcast --account <keystore-name>
///   TESTNET=true selects the ERC-8004 testnet registries for PaidReviews; WITH_REVIEWS=false
///   skips PaidReviews; DEPLOYER_KEY=… signs without putting the key on the command line.
///
/// Idempotent: a contract already at its address is left alone. Anyone may run it on any chain;
/// the result is the same contracts at the same addresses whoever pays the gas.
contract DeployStandards is Script {
    function run() external {
        bool testnet = vm.envOr("TESTNET", false);
        // A chain that cannot have the canonical ERC-8004 registries (Argos lacks the Safe
        // singleton factory they are created through) gets no PaidReviews: it would have
        // nothing to post to.
        bool withReviews = vm.envOr("WITH_REVIEWS", true);
        require(
            Standards.DEPLOYER.code.length != 0, "no deterministic-deployment proxy on this chain"
        );

        // DEPLOYER_KEY keeps the signing key off the command line; otherwise use forge's own
        // --account / --private-key options.
        uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));
        if (key != 0) vm.startBroadcast(key);
        else vm.startBroadcast();
        address vault = Standards.deploy(Standards.SALT_VAULT, Standards.vaultInitCode());
        address escape = Standards.deploy(Standards.SALT_ESCAPE, Standards.escapeInitCode());
        address reviews = withReviews
            ? Standards.deploy(Standards.SALT_REVIEWS, Standards.reviewsInitCode(testnet))
            : address(0);
        vm.stopBroadcast();

        console2.log("chainId                ", block.chainid);
        console2.log("AgentMandateVault      ", vault);
        console2.log("QuantumEscapeRegistry  ", escape);
        console2.log("PaidReviews            ", reviews);
        console2.log("PaidReviews registries ", testnet ? "ERC-8004 testnet" : "ERC-8004 mainnet");
    }
}
