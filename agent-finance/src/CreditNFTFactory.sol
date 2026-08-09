// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import { CreditNFTCollection } from "./CreditNFTCollection.sol";

/// @title CreditNFTFactory
/// @notice Permissionless, fee-free creator launchpad for immutable
/// CreditNFTCollection deployments. The factory has no owner, upgrade key, or
/// authority over collections it creates.
contract CreditNFTFactory {
    uint256 public collectionCount;
    mapping(uint256 => address) public collectionAt;
    mapping(address => bool) public createdHere;

    event CollectionCreated(
        uint256 indexed collectionIndex,
        address indexed collection,
        address indexed creator,
        string name,
        string symbol,
        uint256 maxSupply,
        bytes32 provenanceHash
    );

    function createCollection(
        string calldata name,
        string calldata symbol,
        uint256 maxSupply,
        string calldata contractURI,
        bytes32 provenanceHash,
        address royaltyReceiver,
        uint96 royaltyBps
    ) external returns (address collection) {
        collection = address(
            new CreditNFTCollection(
                name,
                symbol,
                msg.sender,
                maxSupply,
                contractURI,
                provenanceHash,
                royaltyReceiver,
                royaltyBps
            )
        );

        uint256 index = ++collectionCount;
        collectionAt[index] = collection;
        createdHere[collection] = true;
        emit CollectionCreated(
            index, collection, msg.sender, name, symbol, maxSupply, provenanceHash
        );
    }
}
