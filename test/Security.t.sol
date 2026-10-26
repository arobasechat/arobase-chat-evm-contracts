// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {Social} from "../src/Social.sol";
import {Content} from "../src/Content.sol";
import {Vault, ISessionRegistry} from "../src/Vault.sol";
import {Sig} from "../src/lib/Sig.sol";

contract SecurityTest is Base {
    uint64 internal expiry;
    bytes internal deleg;

    function setUp() public override {
        super.setUp();
        expiry = uint64(block.timestamp + 30 days);
        deleg = _delegation(alicePk, sessionKey, expiry);
    }

    function _dsig(bytes32 h) internal view returns (bytes memory) {
        return abi.encodePacked(_sign(sessionPk, h), deleg);
    }

    function _sessionPublish(uint8 kind, bytes32 parent, uint64 ts, bytes memory payload) internal returns (bytes32) {
        return content.publish(alice, kind, parent, ts, payload, _dsig(_messageHash(alice, kind, parent, ts, payload)));
    }

    function test_backdatedMessageFromExpiredSessionIsRejected() public {
        bytes32 post = _publish(alicePk, 0, bytes32(0), bytes("my post"));
        vm.warp(block.timestamp + 365 days);
        uint64 ts = expiry - 1;
        bytes memory payload = bytes("{\"name\":\"pwned\"}");
        bytes memory sig = _dsig(_messageHash(alice, 3, bytes32(0), ts, payload));
        vm.expectRevert(Sig.SessionExpired.selector);
        content.publish(alice, 3, bytes32(0), ts, payload, sig);
        sig = _dsig(_messageHash(alice, 5, post, ts, ""));
        vm.expectRevert(Sig.SessionExpired.selector);
        content.publish(alice, 5, post, ts, "", sig);
        assertFalse(content.retracted(post));
    }

    function test_revocationIsEnforcedOnContentWithTheSameSignature() public {
        _sessionPublish(0, bytes32(0), uint64(block.timestamp), "before");
        bytes memory revokeSig = _sign(alicePk, _revokeHash(alice, sessionKey));
        social.revoke(alice, sessionKey, revokeSig);
        content.revoke(alice, sessionKey, revokeSig);
        assertGt(content.sessionRevokedAt(alice, sessionKey), 0);
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _dsig(_messageHash(alice, 0, bytes32(0), ts, "after"));
        vm.expectRevert(Sig.SessionRevoked.selector);
        content.publish(alice, 0, bytes32(0), ts, "after", sig);
    }

    function test_sessionCanOnlyRevokeItself() public {
        address other = vm.addr(0xBEEF);
        bytes memory sig = _dsig(_revokeHash(alice, other));
        vm.expectRevert(Sig.BadSignature.selector);
        social.revoke(alice, other, sig);
        social.revoke(alice, sessionKey, _dsig(_revokeHash(alice, sessionKey)));
        assertGt(social.sessionRevokedAt(alice, sessionKey), 0);
        vm.expectRevert(Sig.BadSignature.selector);
        social.revoke(alice, other, _sign(bobPk, _revokeHash(alice, other)));
    }

    function test_revocationCannotBeFrontRunWithTheNonce() public {
        uint64 n = social.nonces(alice);
        bytes32 h = _actionHash(alice, 10, keccak256("p"), 1, n);
        social.submit(Social.Action(alice, 10, keccak256("p"), 1, n, _dsig(h)));
        social.revoke(alice, sessionKey, _sign(alicePk, _revokeHash(alice, sessionKey)));
        n = social.nonces(alice);
        h = _actionHash(alice, 10, keccak256("q"), 1, n);
        Social.Action memory a = Social.Action(alice, 10, keccak256("q"), 1, n, _dsig(h));
        vm.expectRevert(Social.BadSignature.selector);
        social.submit(a);
    }

    function test_encryptionKeyAndRolesNeedTheIdentity() public {
        uint64 n = social.nonces(alice);
        bytes32 h = _actionHash(alice, 13, bytes32(uint256(0xbad)), 0, n);
        vm.expectRevert(Social.IdentityRequired.selector);
        social.submit(Social.Action(alice, 13, bytes32(uint256(0xbad)), 0, n, _dsig(h)));
        h = _actionHash(alice, 20, _addrTarget(carol), 2, n);
        vm.expectRevert(Social.IdentityRequired.selector);
        social.submit(Social.Action(alice, 20, _addrTarget(carol), 2, n, _dsig(h)));
        social.submit(_action(alicePk, 13, bytes32(uint256(0x900d)), 0));
        assertEq(social.encKey(alice), bytes32(uint256(0x900d)));
    }

    function test_revokedSessionCannotWriteTheVault() public {
        Vault vault = Vault(_proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (gov, ISessionRegistry(address(social))))));
        bytes32 st = keccak256("Save(address author,bytes32 key,uint64 version,bytes32 dataHash)");
        vault.save(alice, "bm", 1, "x", _dsig(_digest(keccak256(abi.encode(st, alice, bytes32("bm"), uint64(1), keccak256("x"))))));
        social.revoke(alice, sessionKey, _sign(alicePk, _revokeHash(alice, sessionKey)));
        bytes memory sig = _dsig(_digest(keccak256(abi.encode(st, alice, bytes32("bm"), uint64(2), keccak256("y")))));
        vm.expectRevert(Sig.SessionRevoked.selector);
        vault.save(alice, "bm", 2, "y", sig);
    }

    function test_privateMessageSignaturesCannotBePublished() public {
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(alicePk, _messageHash(alice, 30, bytes32(0), ts, "secret"));
        vm.expectRevert(Content.UnknownKind.selector);
        content.publish(alice, 30, bytes32(0), ts, "secret", sig);
    }

    function test_noteRatersAreListedOnce() public {
        bytes32 note = keccak256("note");
        social.submit(_action(bobPk, 15, note, 1));
        social.submit(_action(bobPk, 15, note, 0));
        social.submit(_action(bobPk, 15, note, 1));
        social.submit(_action(bobPk, 15, note, 0));
        social.submit(_action(bobPk, 15, note, 1));
        assertEq(social.noteRaters(note, 0, 10).length, 1);
        assertEq(social.helpfulCount(note), 1);
    }

    function test_withdrawnStakeNoLongerHides() public {
        bytes32 target = keccak256("victim post");
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        stake.deposit{value: 1 ether}();
        social.submit(_action(bobPk, 12, target, 1));
        assertGt(social.hideScore(target), 0);
        vm.prank(bob);
        stake.requestWithdraw(1 ether);
        assertEq(social.hideScore(target), 0);
        vm.warp(block.timestamp + 7 days);
        vm.prank(bob);
        stake.withdraw();
        vm.prank(bob);
        stake.depositFor{value: 1 ether}(carol);
        social.submit(_action(carolPk, 12, target, 1));
        assertEq(social.hideScore(target), int256(uint256(social.voteWeight(carol))));
        assertEq(social.modVoterCount(target), 2);
        social.submit(_action(bobPk, 12, target, 0));
        assertEq(social.modVoterCount(target), 1);
    }
}
