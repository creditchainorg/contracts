// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AgentClearing } from "../src/AgentClearing.sol";

/// Behavioural tests for the clearing rails.
///
/// The happy path is one test. The rest are the ways an agent, a service, or a
/// bystander could try to take value that is not theirs — because this contract
/// holds collateral and settles claims signed off-chain, which is exactly the
/// shape where a missing check costs somebody real money.
contract AgentClearingTest is Test {
    AgentClearing internal clearing;

    uint256 internal payerKey = 0xA11CE;
    uint256 internal otherKey = 0xB0B;
    address internal payer;
    address internal other;
    address internal payee = address(0xBEEF);

    function setUp() public {
        clearing = new AgentClearing();
        payer = vm.addr(payerKey);
        other = vm.addr(otherKey);
        vm.deal(payer, 100 ether);
        vm.deal(other, 100 ether);
    }

    // ---------------------------------------------------------------- helpers

    function _sign(uint256 key, uint256 channelId, uint256 cumulative)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = clearing.voucherDigest(channelId, cumulative);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _openFunded(uint256 commit, uint256 cap) internal returns (uint256 id) {
        vm.startPrank(payer);
        clearing.deposit{ value: commit }();
        id = clearing.openChannel(payee, commit, cap, uint64(block.timestamp + 1 days));
        vm.stopPrank();
    }

    /// Total value the contract owes everyone. Must never exceed what it holds.
    function _liabilities(address[] memory who) internal view returns (uint256 total) {
        for (uint256 i = 0; i < who.length; ++i) {
            total += clearing.available(who[i]) + clearing.reserved(who[i]);
        }
    }

    // ------------------------------------------------------- the case it exists for

    function test_thousandsOfPaymentsCostOneOnChainOperation() public {
        uint256 id = _openFunded(10 ether, 10 ether);

        // 5,000 off-chain payments of 0.001 ether. Each is a new signature over a
        // running total; none of them touch the chain.
        uint256 cumulative;
        bytes memory latest;
        for (uint256 i = 0; i < 5_000; ++i) {
            cumulative += 0.001 ether;
            latest = _sign(payerKey, id, cumulative);
        }

        // Only the last voucher is ever presented.
        uint256 gasBefore = gasleft();
        vm.prank(payee);
        clearing.redeem(id, cumulative, latest);
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(clearing.available(payee), 5 ether, "payee banks the whole run");
        assertLt(gasUsed, 100_000, "one redemption regardless of payment count");
    }

    // ------------------------------------------------------------------ deposit

    function test_depositAndWithdraw() public {
        vm.startPrank(payer);
        clearing.deposit{ value: 3 ether }();
        assertEq(clearing.available(payer), 3 ether);
        clearing.withdraw(1 ether);
        assertEq(clearing.available(payer), 2 ether);
        vm.stopPrank();
        assertEq(address(clearing).balance, 2 ether);
    }

    function test_reservedCollateralCannotBeWithdrawn() public {
        _openFunded(5 ether, 5 ether);
        // Everything went into the channel, so there is nothing free left.
        assertEq(clearing.available(payer), 0);
        assertEq(clearing.reserved(payer), 5 ether);
        vm.prank(payer);
        vm.expectRevert(AgentClearing.InsufficientAvailable.selector);
        clearing.withdraw(1 wei);
    }

    // ------------------------------------------------------------------ payment

    function test_redeemPaysTheDeltaOnly() public {
        uint256 id = _openFunded(10 ether, 10 ether);

        vm.prank(payee);
        clearing.redeem(id, 3 ether, _sign(payerKey, id, 3 ether));
        assertEq(clearing.available(payee), 3 ether);

        // A later voucher owes the difference, not the whole total again.
        vm.prank(payee);
        clearing.redeem(id, 5 ether, _sign(payerKey, id, 5 ether));
        assertEq(clearing.available(payee), 5 ether, "delta, not double-paid");
    }

    function test_staleVoucherIsRejectedNotReplayed() public {
        uint256 id = _openFunded(10 ether, 10 ether);
        bytes memory v3 = _sign(payerKey, id, 3 ether);

        vm.prank(payee);
        clearing.redeem(id, 3 ether, v3);

        // Presenting the same voucher again must not pay twice.
        vm.prank(payee);
        vm.expectRevert(AgentClearing.NothingToRedeem.selector);
        clearing.redeem(id, 3 ether, v3);
        assertEq(clearing.available(payee), 3 ether);
    }

    function test_voucherAboveCapIsRefused() public {
        uint256 id = _openFunded(1 ether, 1 ether);
        bytes memory over = _sign(payerKey, id, 2 ether);
        vm.prank(payee);
        vm.expectRevert(AgentClearing.CapExceeded.selector);
        clearing.redeem(id, 2 ether, over);
    }

    function test_signatureFromAnyoneElseIsRefused() public {
        uint256 id = _openFunded(5 ether, 5 ether);
        bytes memory forged = _sign(otherKey, id, 1 ether);
        vm.prank(payee);
        vm.expectRevert(AgentClearing.BadSignature.selector);
        clearing.redeem(id, 1 ether, forged);
    }

    /// Both halves of the curve recover the same signer. Accepting the upper half
    /// would let one voucher be presented under two distinct signatures.
    function test_malleableSignatureIsRefused() public {
        uint256 id = _openFunded(5 ether, 5 ether);
        bytes32 digest = clearing.voucherDigest(id, 1 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, digest);

        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 flippedS = bytes32(n - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;

        vm.prank(payee);
        vm.expectRevert(AgentClearing.BadSignature.selector);
        clearing.redeem(id, 1 ether, abi.encodePacked(r, flippedS, flippedV));
    }

    function test_voucherForAnotherChannelDoesNotApply() public {
        uint256 a = _openFunded(5 ether, 5 ether);
        vm.startPrank(payer);
        clearing.deposit{ value: 5 ether }();
        uint256 b = clearing.openChannel(payee, 5 ether, 5 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        // Signed for channel a, presented against channel b: the digest binds the
        // channel id, so the recovered signer will not match.
        bytes memory wrongChannel = _sign(payerKey, a, 1 ether);
        vm.prank(payee);
        vm.expectRevert(AgentClearing.BadSignature.selector);
        clearing.redeem(b, 1 ether, wrongChannel);
    }

    // ------------------------------------------------------------ close window

    function test_closeWindowLetsThePayeeBankAnInFlightVoucher() public {
        uint256 id = _openFunded(4 ether, 4 ether);
        bytes memory v = _sign(payerKey, id, 4 ether);

        // Payer tries to walk away with the collateral.
        vm.prank(payer);
        clearing.startClose(id);

        // Reclaiming before the window elapses is refused.
        vm.expectRevert(AgentClearing.NotExpiredOrClosed.selector);
        clearing.closeChannel(id);

        // The payee still banks what it was owed.
        vm.prank(payee);
        clearing.redeem(id, 4 ether, v);
        assertEq(clearing.available(payee), 4 ether);
    }

    function test_closeReturnsOnlyUnredeemedCollateral() public {
        uint256 id = _openFunded(10 ether, 10 ether);
        vm.prank(payee);
        clearing.redeem(id, 4 ether, _sign(payerKey, id, 4 ether));

        vm.prank(payer);
        clearing.startClose(id);
        vm.warp(block.timestamp + clearing.CLOSE_WINDOW() + 1);
        clearing.closeChannel(id);

        assertEq(clearing.available(payer), 6 ether, "unspent collateral returns");
        assertEq(clearing.reserved(payer), 0);
        assertEq(clearing.available(payee), 4 ether, "already-banked value untouched");
    }

    function test_expiredChannelStopsAcceptingVouchers() public {
        uint256 id = _openFunded(5 ether, 5 ether);
        bytes memory v = _sign(payerKey, id, 1 ether);
        vm.warp(block.timestamp + 2 days);
        vm.prank(payee);
        vm.expectRevert(AgentClearing.Expired.selector);
        clearing.redeem(id, 1 ether, v);
    }

    // ------------------------------------------------------------ clearing

    function test_batchNetsManyVouchersIntoOneWritePerAccount() public {
        // One payer, three channels to the same payee: the classic agent pattern
        // of paying several services that all settle to one operator.
        vm.startPrank(payer);
        clearing.deposit{ value: 9 ether }();
        uint256 c1 = clearing.openChannel(payee, 3 ether, 3 ether, uint64(block.timestamp + 1 days));
        uint256 c2 = clearing.openChannel(payee, 3 ether, 3 ether, uint64(block.timestamp + 1 days));
        uint256 c3 = clearing.openChannel(payee, 3 ether, 3 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        AgentClearing.Voucher[] memory vs = new AgentClearing.Voucher[](3);
        vs[0] = AgentClearing.Voucher(c1, 2 ether, _sign(payerKey, c1, 2 ether));
        vs[1] = AgentClearing.Voucher(c2, 1 ether, _sign(payerKey, c2, 1 ether));
        vs[2] = AgentClearing.Voucher(c3, 3 ether, _sign(payerKey, c3, 3 ether));

        vm.expectEmit(false, false, false, true);
        emit AgentClearing.BatchSettled(3, 6 ether, 1); // three vouchers, one account
        clearing.settleBatch(vs);

        assertEq(clearing.available(payee), 6 ether);
    }

    function test_batchSkipsStaleVouchersWithoutFailingTheWholeBatch() public {
        vm.startPrank(payer);
        clearing.deposit{ value: 6 ether }();
        uint256 c1 = clearing.openChannel(payee, 3 ether, 3 ether, uint64(block.timestamp + 1 days));
        uint256 c2 = clearing.openChannel(payee, 3 ether, 3 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        // c1 is already settled; a batch including it must still settle c2.
        vm.prank(payee);
        clearing.redeem(c1, 2 ether, _sign(payerKey, c1, 2 ether));

        AgentClearing.Voucher[] memory vs = new AgentClearing.Voucher[](2);
        vs[0] = AgentClearing.Voucher(c1, 2 ether, _sign(payerKey, c1, 2 ether)); // stale
        vs[1] = AgentClearing.Voucher(c2, 1 ether, _sign(payerKey, c2, 1 ether));
        clearing.settleBatch(vs);

        assertEq(clearing.available(payee), 3 ether, "stale skipped, fresh applied");
    }

    function test_batchCannotInventObligations() public {
        uint256 id = _openFunded(5 ether, 5 ether);
        AgentClearing.Voucher[] memory vs = new AgentClearing.Voucher[](1);
        // A bystander submits a voucher they signed themselves.
        vs[0] = AgentClearing.Voucher(id, 5 ether, _sign(otherKey, id, 5 ether));
        vm.prank(other);
        vm.expectRevert(AgentClearing.BadSignature.selector);
        clearing.settleBatch(vs);
    }

    // --------------------------------------------------------------- credit

    function test_backingReportsUndercollateralisation() public {
        vm.startPrank(payer);
        clearing.deposit{ value: 1 ether }();
        // Cap 4, collateral 1: three quarters of this channel is credit.
        uint256 id = clearing.openChannel(payee, 1 ether, 4 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        assertEq(clearing.backing(id), 2500, "reported as 25% backed");
    }

    /// A payee that accepted credit can only ever bank the collateral. The
    /// contract does not conjure the shortfall — it caps the payout and leaves
    /// the rest as what it always was: an unsecured claim.
    function test_creditBeyondCollateralIsNotPaidOut() public {
        vm.startPrank(payer);
        clearing.deposit{ value: 1 ether }();
        uint256 id = clearing.openChannel(payee, 1 ether, 4 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        vm.prank(payee);
        clearing.redeem(id, 4 ether, _sign(payerKey, id, 4 ether));

        assertEq(clearing.available(payee), 1 ether, "paid only what was collateralised");
        assertEq(address(clearing).balance, 1 ether, "no value invented");
    }

    // ------------------------------------------------------------- solvency

    /// The invariant that matters: the contract can always pay what its books say.
    function test_solvencyHoldsAcrossAFullLifecycle() public {
        address[] memory who = new address[](2);
        who[0] = payer;
        who[1] = payee;

        uint256 id = _openFunded(8 ether, 8 ether);
        assertGe(address(clearing).balance, _liabilities(who));

        vm.prank(payee);
        clearing.redeem(id, 3 ether, _sign(payerKey, id, 3 ether));
        assertGe(address(clearing).balance, _liabilities(who));

        vm.prank(payer);
        clearing.startClose(id);
        vm.warp(block.timestamp + clearing.CLOSE_WINDOW() + 1);
        clearing.closeChannel(id);
        assertGe(address(clearing).balance, _liabilities(who));

        vm.prank(payee);
        clearing.withdraw(3 ether);
        assertGe(address(clearing).balance, _liabilities(who));
        assertEq(address(clearing).balance, 5 ether);
    }

    function testFuzz_redeemNeverExceedsCommittedCollateral(uint96 commit, uint96 claim) public {
        commit = uint96(bound(commit, 1, 50 ether));
        claim = uint96(bound(claim, 1, 50 ether));

        vm.startPrank(payer);
        clearing.deposit{ value: commit }();
        uint256 id =
            clearing.openChannel(payee, commit, 50 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        vm.prank(payee);
        try clearing.redeem(id, claim, _sign(payerKey, id, claim)) { } catch { }

        assertLe(clearing.available(payee), commit, "payout never exceeds collateral");
        assertGe(address(clearing).balance, clearing.available(payee) + clearing.reserved(payer));
    }
}
