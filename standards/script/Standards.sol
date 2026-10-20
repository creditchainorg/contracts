// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import { AgentMandateVault } from "../src/agm/AgentMandateVault.sol";
import { QuantumEscapeRegistry } from "../src/quantum/QuantumEscapeRegistry.sol";
import { PaidReviews } from "../src/reputation/PaidReviews.sol";
import {
    IERC8004Identity,
    IERC8004Reputation,
    IX402BatchSettlement
} from "../src/reputation/External.sol";

/// @title Standards — where every contract in this project lives, on every EVM chain
/// @notice Each contract is created by the deterministic-deployment proxy with a fixed salt, so
///         its address is `keccak256(0xff ++ proxy ++ salt ++ keccak256(initCode))[12:]` and
///         nothing about the chain enters it. The same build on any chain gives the same
///         addresses, and anyone can check one by recomputing it.
library Standards {
    /// Arachnid's deterministic-deployment proxy. In CreditChain's genesis; on nearly every EVM
    /// chain; deployable anywhere else from its well-known pre-signed transaction.
    address internal constant DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 internal constant SALT_VAULT = keccak256("creditchain.standards/AgentMandateVault/2");
    bytes32 internal constant SALT_ESCAPE =
        keccak256("creditchain.standards/QuantumEscapeRegistry/1");
    bytes32 internal constant SALT_REVIEWS = keccak256("creditchain.standards/PaidReviews/1");

    /// Canonical third-party contracts PaidReviews builds on. ERC-8004 publishes one pair of
    /// registry addresses for mainnets and another for testnets; x402 uses one address for both.
    address internal constant ERC8004_IDENTITY_MAINNET = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address internal constant ERC8004_REPUTATION_MAINNET =
        0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;
    address internal constant ERC8004_IDENTITY_TESTNET = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    address internal constant ERC8004_REPUTATION_TESTNET =
        0x8004B663056A597Dffe9eCcC1965A193B7388713;
    address internal constant X402_BATCH_SETTLEMENT = 0x4020074e9dF2ce1deE5A9C1b5c3f541D02a10003;

    function vaultInitCode() internal pure returns (bytes memory) {
        return type(AgentMandateVault).creationCode;
    }

    function escapeInitCode() internal pure returns (bytes memory) {
        return type(QuantumEscapeRegistry).creationCode;
    }

    function reviewsInitCode(bool testnet) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(PaidReviews).creationCode,
            abi.encode(
                testnet ? ERC8004_IDENTITY_TESTNET : ERC8004_IDENTITY_MAINNET,
                testnet ? ERC8004_REPUTATION_TESTNET : ERC8004_REPUTATION_MAINNET,
                X402_BATCH_SETTLEMENT
            )
        );
    }

    function addressOf(bytes32 salt, bytes memory initCode) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), DEPLOYER, salt, keccak256(initCode)))
                )
            )
        );
    }

    /// Create through the proxy unless already there. Returns the address either way.
    /// @dev The proxy's calldata is `salt ++ initCode`; it returns the new address (20 bytes).
    function deploy(bytes32 salt, bytes memory initCode) internal returns (address at) {
        at = addressOf(salt, initCode);
        if (at.code.length != 0) return at;
        (bool ok,) = DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok && at.code.length != 0, "Standards: deterministic deployment failed");
    }
}
