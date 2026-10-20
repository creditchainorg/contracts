// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Standards } from "../script/Standards.sol";

/// The promise of this project: the same contracts at the same addresses on every chain.
contract DeployTest is Test {
    /// Runtime code of the deterministic-deployment proxy, as preinstalled in CreditChain's
    /// genesis and present on Ethereum (codeKeccak 0x2fa86add…4989).
    bytes constant PROXY_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    function setUp() public {
        vm.etch(Standards.DEPLOYER, PROXY_CODE);
    }

    function test_proxyCodeIsTheCanonicalOne() public view {
        assertEq(
            keccak256(Standards.DEPLOYER.code),
            0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989
        );
    }

    function _deployAll(bool testnet)
        internal
        returns (address[3] memory at, bytes32[3] memory codehash)
    {
        at[0] = Standards.deploy(Standards.SALT_VAULT, Standards.vaultInitCode());
        at[1] = Standards.deploy(Standards.SALT_ESCAPE, Standards.escapeInitCode());
        at[2] = Standards.deploy(Standards.SALT_REVIEWS, Standards.reviewsInitCode(testnet));
        for (uint256 i = 0; i < 3; i++) {
            codehash[i] = at[i].codehash;
        }
    }

    /// CreditChain mainnet and Base give identical addresses and identical code.
    function test_sameAddressesOnEveryChain() public {
        uint256 snap = vm.snapshotState();
        vm.chainId(2026042405); // CreditChain mainnet
        (address[3] memory cc, bytes32[3] memory ccCode) = _deployAll(false);

        vm.revertToState(snap);
        vm.chainId(8453); // Base
        (address[3] memory base, bytes32[3] memory baseCode) = _deployAll(false);

        for (uint256 i = 0; i < 3; i++) {
            assertEq(cc[i], base[i], "address differs between chains");
            assertEq(ccCode[i], baseCode[i], "code differs between chains");
            assertTrue(cc[i].code.length > 0);
        }
    }

    function test_addressesArePredictedBeforeDeployment() public {
        address v = Standards.addressOf(Standards.SALT_VAULT, Standards.vaultInitCode());
        assertEq(v.code.length, 0);
        assertEq(Standards.deploy(Standards.SALT_VAULT, Standards.vaultInitCode()), v);
    }

    function test_deployIsIdempotent() public {
        address first = Standards.deploy(Standards.SALT_ESCAPE, Standards.escapeInitCode());
        address second = Standards.deploy(Standards.SALT_ESCAPE, Standards.escapeInitCode());
        assertEq(first, second);
    }

    function test_testnetReviewsDifferOnlyInRegistries() public pure {
        assertTrue(
            Standards.addressOf(Standards.SALT_REVIEWS, Standards.reviewsInitCode(true))
                != Standards.addressOf(Standards.SALT_REVIEWS, Standards.reviewsInitCode(false))
        );
    }
}
