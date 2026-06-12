// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract HelloCreditChain {
    address public immutable deployer;
    string private message;

    event MessageChanged(address indexed caller, string oldMessage, string newMessage);

    constructor(string memory initialMessage) {
        deployer = msg.sender;
        message = initialMessage;
    }

    function read() external view returns (string memory) {
        return message;
    }

    function write(string calldata newMessage) external {
        string memory oldMessage = message;
        message = newMessage;
        emit MessageChanged(msg.sender, oldMessage, newMessage);
    }
}
