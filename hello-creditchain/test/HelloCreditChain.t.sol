// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HelloCreditChain} from "../src/HelloCreditChain.sol";

contract HelloCreditChainTest is Test {
    event MessageChanged(address indexed caller, string oldMessage, string newMessage);

    function testReadInitialMessage() external {
        HelloCreditChain hello = new HelloCreditChain("Hello, CreditChain");
        assertEq(hello.read(), "Hello, CreditChain");
        assertEq(hello.deployer(), address(this));
    }

    function testWriteEmitsAndStoresMessage() external {
        HelloCreditChain hello = new HelloCreditChain("Hello, CreditChain");

        vm.expectEmit(true, false, false, true);
        emit MessageChanged(address(this), "Hello, CreditChain", "Built on CCC");

        hello.write("Built on CCC");
        assertEq(hello.read(), "Built on CCC");
    }
}
