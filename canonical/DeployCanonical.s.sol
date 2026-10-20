// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";

/// Deploys every contract in manifest.json at its canonical address, from the init code in
/// initcode/ (run fetch-initcode.py --check first). Same result as deploy.sh, for when the signing
/// key must not appear on a command line: the key comes from the DEPLOYER_KEY environment variable.
///
///   cd canonical
///   DEPLOYER_KEY=… forge script DeployCanonical.s.sol --rpc-url <rpc> --broadcast
contract DeployCanonical is Script {
    address constant PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        require(PROXY.code.length != 0, "no deterministic-deployment proxy on this chain");
        string memory manifest = vm.readFile("manifest.json");
        uint256 key = vm.envUint("DEPLOYER_KEY");

        for (uint256 i = 0;; i++) {
            string memory at = string.concat(".contracts[", vm.toString(i), "]");
            if (!vm.keyExistsJson(manifest, at)) break;
            string memory name = vm.parseJsonString(manifest, string.concat(at, ".name"));
            address target = vm.parseJsonAddress(manifest, string.concat(at, ".address"));
            bytes32 salt = vm.parseJsonBytes32(manifest, string.concat(at, ".salt"));
            if (target.code.length != 0) {
                console2.log("present  ", name, target);
                continue;
            }
            bytes memory initCode =
                vm.parseBytes(vm.trim(vm.readFile(string.concat("initcode/", name, ".hex"))));
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), PROXY, salt, keccak256(initCode)))))
            );
            require(predicted == target, string.concat(name, ": init code does not give its canonical address"));
            vm.broadcast(key);
            (bool ok,) = PROXY.call(abi.encodePacked(salt, initCode));
            require(ok, string.concat(name, ": deployment failed"));
            console2.log("deployed ", name, target);
        }
    }
}
