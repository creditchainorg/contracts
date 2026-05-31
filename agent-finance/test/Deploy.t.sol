// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreditAgentFinance} from "../src/CreditAgentFinance.sol";

/// Sanity test for the deploy path. Anything beyond "deploys, has bytecode,
/// and the deployer can register an agent" is out of scope for this MVP test
/// pack — protocol semantics live in the implementation tests written
/// alongside each Agent Finance entrypoint as those land.
contract DeployTest is Test {
    CreditAgentFinance internal cc;

    function setUp() public {
        cc = new CreditAgentFinance();
    }

    function test_HasBytecode() public view {
        uint256 size;
        address a = address(cc);
        assembly {
            size := extcodesize(a)
        }
        assertGt(size, 0, "contract has no runtime bytecode");
    }
}
