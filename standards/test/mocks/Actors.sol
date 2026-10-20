// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import { IAgentMandateVault } from "../../src/agm/IAgentMandateVault.sol";

/// A smart-contract agent: accepts a signature when its single authorised key signed the digest.
contract Erc1271Agent {
    address public immutable key;

    constructor(address key_) {
        key = key_;
    }

    function isValidSignature(bytes32 digest, bytes calldata sig) external view returns (bytes4) {
        if (sig.length != 65) return 0xffffffff;
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        return ecrecover(digest, v, r, s) == key ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// A recipient that tries to re-enter the vault when paid.
contract ReentrantRecipient {
    IAgentMandateVault public immutable vault;
    uint256 public mandateId;
    uint8 public mode; // 1 = spend again, 2 = withdraw, 3 = revoke

    constructor(IAgentMandateVault v) {
        vault = v;
    }

    function arm(uint256 id, uint8 m) external {
        mandateId = id;
        mode = m;
    }

    receive() external payable {
        if (mode == 1) vault.spend(mandateId, address(this), 1, bytes32(0));
        if (mode == 2) vault.withdraw(mandateId, 1);
        if (mode == 3) vault.revoke(mandateId);
    }
}

/// A recipient that refuses the native coin.
contract RejectingRecipient {
    receive() external payable {
        revert("no");
    }
}
