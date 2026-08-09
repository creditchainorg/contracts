// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { CreditNFTFactory } from "../src/CreditNFTFactory.sol";

/// @notice Deploys the fee-free creator factory for a public test network.
contract DeployCreditNFTFactory is Script {
    uint256 private constant CREDITCHAIN_MAINNET = 2026042405;

    error MainnetDeploymentBlocked();

    function run() external returns (CreditNFTFactory factory) {
        if (block.chainid == CREDITCHAIN_MAINNET) revert MainnetDeploymentBlocked();

        vm.startBroadcast();
        factory = new CreditNFTFactory();
        vm.stopBroadcast();

        console2.log("CreditNFTFactory", address(factory));
    }
}
