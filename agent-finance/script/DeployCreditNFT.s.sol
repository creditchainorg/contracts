// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { CreditNFTCollection } from "../src/CreditNFTCollection.sol";
import { CreditNFTMarket } from "../src/CreditNFTMarket.sol";

/// @notice Deploys the public-testnet NFT reference collection and market.
/// Mainnet is deliberately blocked until the contracts are independently audited
/// and CreditChain's mainnet readiness gates have passed.
contract DeployCreditNFT is Script {
    uint256 private constant CREDITCHAIN_MAINNET = 2026042405;
    uint256 private constant MAX_ROYALTY_BPS = 1_000;
    uint256 private constant MAX_MARKET_FEE_BPS = 250;

    error MainnetDeploymentBlocked();
    error InvalidRoyaltyBps();
    error InvalidMarketFeeBps();

    function run() external returns (CreditNFTCollection collection, CreditNFTMarket market) {
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
        address feeRecipient = vm.envAddress("NFT_MARKET_FEE_RECIPIENT");
        uint256 marketFeeBpsValue = vm.envUint("NFT_MARKET_FEE_BPS");
        if (marketFeeBpsValue > MAX_MARKET_FEE_BPS) revert InvalidMarketFeeBps();
        // Both values are capped above, far below uint96 max.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint96 royaltyBps = uint96(royaltyBpsValue);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint96 marketFeeBps = uint96(marketFeeBpsValue);

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
        market = new CreditNFTMarket(feeRecipient, marketFeeBps);
        vm.stopBroadcast();

        console2.log("CreditNFTCollection", address(collection));
        console2.log("CreditNFTMarket", address(market));
    }
}
