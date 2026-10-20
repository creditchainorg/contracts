// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { AgentMandateVault } from "../../src/agm/AgentMandateVault.sol";
import { IAgentMandateVault } from "../../src/agm/IAgentMandateVault.sol";
import { MockERC20, FeeOnTransferERC20 } from "../mocks/Tokens.sol";

/// Drives the vault with random but well-formed actions from several owners, agents and relayers,
/// across the native coin, a plain ERC-20 and a fee-on-transfer ERC-20. Calls that the vault
/// rejects simply revert; the invariants are checked after every successful step.
contract VaultHandler is Test {
    AgentMandateVault public immutable vault;
    address[3] public assets;
    address[3] public owners;
    uint256[3] public agentKeys;
    address public shop = address(0x5409);

    /// What entered and left the vault, per asset, as the vault itself experienced it.
    mapping(address => uint256) public ghostIn;
    mapping(address => uint256) public ghostOut;
    uint256 public nonceSeed;

    constructor(AgentMandateVault v, MockERC20 token, FeeOnTransferERC20 feeToken) {
        vault = v;
        assets = [address(0), address(token), address(feeToken)];
        for (uint256 i = 0; i < 3; i++) {
            owners[i] = address(uint160(0x0A0 + i));
            agentKeys[i] = 0xA9E0 + i;
            vm.deal(owners[i], 1e30);
            token.mint(owners[i], 1e30);
            feeToken.mint(owners[i], 1e30);
            vm.startPrank(owners[i]);
            token.approve(address(v), type(uint256).max);
            feeToken.approve(address(v), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _holdings(address asset) internal view returns (uint256) {
        if (asset == address(0)) return address(vault).balance;
        return MockERC20(asset).balanceOf(address(vault));
    }

    function _mandate(uint256 seed) internal view returns (uint256 id, bool ok) {
        uint256 n = vault.mandateCount();
        if (n == 0) return (0, false);
        return (seed % n + 1, true);
    }

    /// `rails` packs the limits: 5 x 48 bits of budget, perTx, window, window seconds, max fee,
    /// plus one allowlist bit. Zero in any field means "no limit", as in the vault.
    function create(uint256 who, uint256 assetSeed, uint96 amount, uint256 rails) external {
        address asset = assets[assetSeed % 3];
        IAgentMandateVault.MandateTerms memory t;
        t.agent = vm.addr(agentKeys[who % 3]);
        t.asset = asset;
        t.amount = amount;
        t.budget = uint48(rails);
        t.perTxMax = uint48(rails >> 48);
        t.windowLimit = uint48(rails >> 96);
        t.windowSeconds = uint64(uint48(rails >> 144) % 2 days);
        t.maxRelayFee = uint48(rails >> 192);
        t.allowlistEnabled = (rails >> 240) & 1 == 1;
        _create(owners[who % 3], t);
    }

    function _create(address owner, IAgentMandateVault.MandateTerms memory t) internal {
        uint256 before = _holdings(t.asset);
        vm.prank(owner);
        uint256 id = vault.createMandate{ value: t.asset == address(0) ? t.amount : 0 }(t);
        ghostIn[t.asset] += _holdings(t.asset) - before;
        if (t.allowlistEnabled) {
            vm.prank(owner);
            vault.allowRecipient(id, shop, true);
        }
    }

    function fund(uint256 seed, uint96 amount) external {
        (uint256 id, bool ok) = _mandate(seed);
        if (!ok) return;
        IAgentMandateVault.Mandate memory m = vault.mandate(id);
        address funder = owners[seed % 3];
        uint256 before = _holdings(m.asset);
        vm.prank(funder);
        vault.fund{ value: m.asset == address(0) ? amount : 0 }(id, amount);
        ghostIn[m.asset] += _holdings(m.asset) - before;
    }

    function spend(uint256 seed, uint96 amount) external {
        (uint256 id, bool ok) = _mandate(seed);
        if (!ok) return;
        IAgentMandateVault.Mandate memory m = vault.mandate(id);
        address to = seed % 4 == 0 ? m.owner : shop;
        uint256 before = _holdings(m.asset);
        vm.prank(m.agent);
        vault.spend(id, to, amount, bytes32(seed));
        ghostOut[m.asset] += before - _holdings(m.asset);
    }

    function spendSigned(uint256 seed, uint96 amount, uint96 fee) external {
        (uint256 id, bool ok) = _mandate(seed);
        if (!ok) return;
        IAgentMandateVault.Mandate memory m = vault.mandate(id);
        uint256 key;
        for (uint256 i = 0; i < 3; i++) {
            if (vm.addr(agentKeys[i]) == m.agent) key = agentKeys[i];
        }
        if (key == 0) return;
        IAgentMandateVault.SpendAuthorization memory a = IAgentMandateVault.SpendAuthorization({
            mandateId: id,
            recipient: shop,
            amount: amount,
            receipt: keccak256(abi.encode(seed)),
            fee: fee,
            nonce: ++nonceSeed,
            deadline: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, vault.spendDigest(a));
        uint256 before = _holdings(m.asset);
        vm.prank(address(uint160(0x2E1A + seed % 5)));
        vault.spendWithSignature(a, abi.encodePacked(r, s, v));
        ghostOut[m.asset] += before - _holdings(m.asset);
    }

    function withdraw(uint256 seed, uint96 amount) external {
        (uint256 id, bool ok) = _mandate(seed);
        if (!ok) return;
        IAgentMandateVault.Mandate memory m = vault.mandate(id);
        uint256 before = _holdings(m.asset);
        vm.prank(m.owner);
        vault.withdraw(id, amount);
        ghostOut[m.asset] += before - _holdings(m.asset);
    }

    function revoke(uint256 seed) external {
        (uint256 id, bool ok) = _mandate(seed);
        if (!ok) return;
        IAgentMandateVault.Mandate memory m = vault.mandate(id);
        uint256 before = _holdings(m.asset);
        vm.prank(m.owner);
        vault.revoke(id);
        ghostOut[m.asset] += before - _holdings(m.asset);
    }

    function pause(uint256 seed, bool paused) external {
        (uint256 id, bool ok) = _mandate(seed);
        if (!ok) return;
        vm.prank(vault.mandate(id).owner);
        vault.setPaused(id, paused);
    }

    function rotate(uint256 seed, uint256 keySeed) external {
        (uint256 id, bool ok) = _mandate(seed);
        if (!ok) return;
        vm.prank(vault.mandate(id).owner);
        vault.rotateAgent(id, vm.addr(agentKeys[keySeed % 3]));
    }

    function warp(uint32 secs) external {
        vm.warp(block.timestamp + secs % 3 days);
    }
}

contract AgentMandateVaultInvariants is Test {
    AgentMandateVault vault;
    VaultHandler handler;
    MockERC20 token;
    FeeOnTransferERC20 feeToken;

    function setUp() public {
        vault = new AgentMandateVault();
        token = new MockERC20("T", "T", 18);
        feeToken = new FeeOnTransferERC20();
        handler = new VaultHandler(vault, token, feeToken);
        targetContract(address(handler));
    }

    /// Solvency, per asset: the vault holds exactly the sum of its mandates' balances.
    function invariant_solventPerAsset() public view {
        address[3] memory assets = [address(0), address(token), address(feeToken)];
        uint256[3] memory sums;
        uint256 n = vault.mandateCount();
        for (uint256 id = 1; id <= n; id++) {
            IAgentMandateVault.Mandate memory m = vault.mandate(id);
            for (uint256 a = 0; a < 3; a++) {
                if (m.asset == assets[a]) sums[a] += m.balance;
            }
        }
        assertEq(address(vault).balance, sums[0], "native");
        assertEq(token.balanceOf(address(vault)), sums[1], "erc20");
        assertEq(feeToken.balanceOf(address(vault)), sums[2], "fee-on-transfer");
    }

    /// Conservation: what is held is what came in minus what went out.
    function invariant_conservation() public view {
        assertEq(address(vault).balance, handler.ghostIn(address(0)) - handler.ghostOut(address(0)));
        assertEq(
            token.balanceOf(address(vault)),
            handler.ghostIn(address(token)) - handler.ghostOut(address(token))
        );
    }

    /// Every rail holds for every mandate, whatever was signed and whoever relayed it.
    function invariant_railsHold() public view {
        uint256 n = vault.mandateCount();
        for (uint256 id = 1; id <= n; id++) {
            IAgentMandateVault.Mandate memory m = vault.mandate(id);
            if (m.budget != 0) assertLe(m.spent, m.budget, "budget");
            if (m.windowLimit != 0) assertLe(m.windowSpent, m.windowLimit, "window");
            assertLe(m.spentToOwner, m.spent, "self-spend within spend");
            if (m.revoked) assertEq(m.balance, 0, "revoked holds nothing");
        }
    }
}
