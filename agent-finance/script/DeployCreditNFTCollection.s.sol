// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { CreditNFTCollection } from "../src/CreditNFTCollection.sol";

/// @notice Creator-facing deployment for a collection that lists into the
/// shared, source-verified CreditChain Market. Mainnet stays blocked until the
/// reference contract and chain have passed their independent launch gates.
contract DeployCreditNFTCollection is Script {
    uint256 private constant CREDITCHAIN_MAINNET = 2026042405;
    uint256 private constant MAX_ROYALTY_BPS = 1_000;

    error MainnetDeploymentBlocked();
    error InvalidRoyaltyBps();

    function run() external returns (CreditNFTCollection collection) {
        if (block.chainid == CREDITCHAIN_MAINNET) revert MainnetDeploymentBlocked();

        string memory name = vm.envString("NFT_NAME");
        string memory symbol = vm.envString("NFT_SYMBOL");
        address initialOwner = vm.envAddress("NFT_OWNER");
        uint256 maxSupply = vm.envUint("NFT_MAX_SUPPLY");
        string memory contractUri = vm.envString("NFT_CONTRACT_URI");
        bytes32 provenanceHash = vm.envBytes32("NFT_PROVENANCE_HASH");
        address royaltyReceiver = vm.envAddress("NFT_ROYALTY_RECEIVER");
        uint256 royaltyBpsValue = vm.envUint("NFT_ROYALTY_BPS");
        if (royaltyBpsValue > MAX_ROYALTY_BPS) revert InvalidRoyaltyBps();
        // Capped at 1,000 above, far below uint96 max.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint96 royaltyBps = uint96(royaltyBpsValue);

        vm.startBroadcast();
        collection = new CreditNFTCollection(
            name,
            symbol,
            initialOwner,
            maxSupply,
            contractUri,
            provenanceHash,
            royaltyReceiver,
            royaltyBps
        );
        vm.stopBroadcast();

        console2.log("CreditNFTCollection", address(collection));
    }
}
