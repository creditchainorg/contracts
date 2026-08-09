// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { CreditNFTMarket } from "../src/CreditNFTMarket.sol";

/// @notice Operator-facing deployment for the shared CreditChain Market.
/// Mainnet remains blocked until contract and chain launch gates pass.
contract DeployCreditNFTMarket is Script {
    uint256 private constant CREDITCHAIN_MAINNET = 2026042405;
    uint256 private constant MAX_MARKET_FEE_BPS = 250;

    error MainnetDeploymentBlocked();
    error InvalidMarketFeeBps();

    function run() external returns (CreditNFTMarket market) {
        if (block.chainid == CREDITCHAIN_MAINNET) revert MainnetDeploymentBlocked();

        address feeRecipient = vm.envAddress("NFT_MARKET_FEE_RECIPIENT");
        uint256 marketFeeBpsValue = vm.envUint("NFT_MARKET_FEE_BPS");
        if (marketFeeBpsValue > MAX_MARKET_FEE_BPS) revert InvalidMarketFeeBps();
        // Capped at 250 above, far below uint96 max.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint96 marketFeeBps = uint96(marketFeeBpsValue);

        vm.startBroadcast();
        market = new CreditNFTMarket(feeRecipient, marketFeeBps);
        vm.stopBroadcast();

        console2.log("CreditNFTMarket", address(market));
    }
}
