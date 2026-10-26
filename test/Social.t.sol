// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {Social} from "../src/Social.sol";
import {Upgradeable} from "../src/base/Upgradeable.sol";

contract SocialTest is Base {
    bytes32 internal postId = keccak256("post");

    function test_likeDislikeRetract() public {
        social.submit(_action(bobPk, 10, postId, 1));
        assertEq(social.likeCount(postId), 1);
        social.submit(_action(bobPk, 10, postId, 1));
        assertEq(social.likeCount(postId), 1);
        social.submit(_action(bobPk, 10, postId, -1));
        assertEq(social.likeCount(postId), 0);
        assertEq(social.dislikeCount(postId), 1);
        social.submit(_action(bobPk, 10, postId, 0));
        assertEq(social.dislikeCount(postId), 0);
        assertEq(social.nonces(bob), 4);
    }

    function test_selfReactionNotCounted() public {
        social.submit(_action(alicePk, 10, postId, 1));
        social.submit(_action(bobPk, 10, postId, 1));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = postId;
        address[] memory authors = new address[](1);
        authors[0] = alice;
        Social.PostStat[] memory st = social.postStats(ids, authors, bob);
        assertEq(st[0].likes, 1);
        assertEq(st[0].viewerReaction, 1);
    }

    function test_replayRejected() public {
        Social.Action memory a = _action(bobPk, 10, postId, 1);
        social.submit(a);
        vm.expectRevert(Social.BadNonce.selector);
        social.submit(a);
    }

    function test_forgedActionRejected() public {
        Social.Action memory a = _action(bobPk, 10, postId, 1);
        a.author = carol;
        vm.expectRevert(Social.BadSignature.selector);
        social.submit(a);
    }

    function test_followLists() public {
        social.submit(_action(bobPk, 11, _addrTarget(alice), 1));
        social.submit(_action(carolPk, 11, _addrTarget(alice), 1));
        social.submit(_action(bobPk, 11, _addrTarget(carol), 1));
        assertTrue(social.isFollowing(bob, alice));
        assertEq(social.followerCount(alice), 2);
        assertEq(social.followingCount(bob), 2);
        address[] memory list = social.following(bob, 0, 10);
        assertEq(list.length, 2);
        social.submit(_action(bobPk, 11, _addrTarget(alice), 0));
        assertEq(social.followerCount(alice), 1);
        list = social.following(bob, 0, 10);
        assertEq(list.length, 1);
        assertEq(list[0], carol);
        list = social.followers(alice, 0, 10);
        assertEq(list.length, 1);
        assertEq(list[0], carol);
    }

    function test_cannotFollowSelf() public {
        Social.Action memory a = _action(bobPk, 11, _addrTarget(bob), 1);
        vm.expectRevert(Social.InvalidValue.selector);
        social.submit(a);
    }

    function test_batchSkipsInvalid() public {
        Social.Action[] memory batch = new Social.Action[](3);
        batch[0] = _action(bobPk, 10, postId, 1);
        batch[1] = _action(carolPk, 10, postId, 5);
        batch[2] = _action(carolPk, 11, _addrTarget(alice), 1);
        uint256 applied = social.submitBatch(batch);
        assertEq(applied, 2);
        assertEq(social.likeCount(postId), 1);
        assertTrue(social.isFollowing(carol, alice));
    }

    function test_sequentialBatchNonces() public {
        Social.Action[] memory batch = new Social.Action[](3);
        for (uint256 i; i < 3; ++i) {
            bytes32 target = keccak256(abi.encode(i));
            uint64 nonce = uint64(i);
            batch[i] = Social.Action(bob, 10, target, 1, nonce, _sign(bobPk, _actionHash(bob, 10, target, 1, nonce)));
        }
        assertEq(social.submitBatch(batch), 3);
        assertEq(social.nonces(bob), 3);
    }

    function test_sessionKeyAndRevocation() public {
        uint64 expiry = uint64(block.timestamp + 1 days);
        bytes memory del = _delegation(bobPk, sessionKey, expiry);
        uint64 nonce = social.nonces(bob);
        bytes memory sig = abi.encodePacked(_sign(sessionPk, _actionHash(bob, 10, postId, 1, nonce)), del);
        social.submit(Social.Action(bob, 10, postId, 1, nonce, sig));
        assertEq(social.likeCount(postId), 1);

        social.revoke(bob, sessionKey, _sign(bobPk, _revokeHash(bob, sessionKey)));
        assertEq(social.sessionRevokedAt(bob, sessionKey), block.timestamp);

        nonce = social.nonces(bob);
        sig = abi.encodePacked(_sign(sessionPk, _actionHash(bob, 10, postId, 0, nonce)), del);
        vm.expectRevert(Social.BadSignature.selector);
        social.submit(Social.Action(bob, 10, postId, 0, nonce, sig));
    }

    function test_rolesOnlyAdmin() public {
        Social.Action memory a = _action(bobPk, 20, _addrTarget(carol), 1);
        vm.expectRevert(Social.NotAuthorized.selector);
        social.submit(a);
        social.submit(_action(alicePk, 20, _addrTarget(bob), 1));
        assertEq(social.role(bob), 1);
        (address[] memory list, uint8[] memory roles) = social.staff();
        assertEq(list.length, 2);
        assertEq(roles[1], 1);
        social.submit(_action(alicePk, 20, _addrTarget(bob), 0));
        (list,) = social.staff();
        assertEq(list.length, 1);
    }

    function test_lastAdminProtected() public {
        Social.Action memory a = _action(alicePk, 20, _addrTarget(alice), 0);
        vm.expectRevert(Social.LastAdmin.selector);
        social.submit(a);
    }

    function test_governanceSetsRole() public {
        vm.prank(gov);
        social.setRole(bob, 2);
        assertEq(social.adminCount(), 2);
        vm.expectRevert(Upgradeable.NotOwner.selector);
        social.setRole(carol, 2);
    }

    function test_voteWeightRequiresStakeOrAge() public {
        assertEq(social.voteWeight(bob), 0);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        stake.deposit{value: 1 ether}();
        assertEq(social.voteWeight(bob), 11);
        social.submit(_action(carolPk, 10, postId, 1));
        vm.warp(block.timestamp + 61 days);
        assertEq(social.voteWeight(carol), 3);
    }

    function test_modVoteScoreAndFlags() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        stake.deposit{value: 0.04 ether}();
        social.submit(_action(bobPk, 12, postId, 1));
        assertEq(social.hideScore(postId), 3);
        social.submit(_action(bobPk, 12, postId, -1));
        assertEq(social.hideScore(postId), -3);
        social.submit(_action(bobPk, 12, postId, 0));
        assertEq(social.hideScore(postId), 0);
        assertEq(social.flagCount(postId), 0);

        social.submit(_action(alicePk, 12, postId, 1));
        assertEq(social.flagCount(postId), 1);
        assertTrue(social.modFlag(postId, alice));
        address[] memory mods = new address[](2);
        mods[0] = bob;
        mods[1] = alice;
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = postId;
        assertEq(social.flagsBy(ids, mods)[0], 2);
        social.submit(_action(alicePk, 12, postId, 0));
        assertEq(social.flagCount(postId), 0);
    }

    function test_noteRatings() public {
        bytes32 note = keccak256("note");
        social.submit(_action(bobPk, 15, note, 1));
        social.submit(_action(carolPk, 15, note, -1));
        social.submit(_action(carolPk, 15, note, 1));
        assertEq(social.helpfulCount(note), 2);
        assertEq(social.notHelpfulCount(note), 0);
        assertEq(social.noteRaters(note, 0, 10).length, 2);
    }

    function test_encKeyAndStats() public {
        bytes32 key = keccak256("x25519");
        social.submit(_action(bobPk, 13, key, 0));
        social.submit(_action(bobPk, 11, _addrTarget(alice), 1));
        address[] memory users = new address[](1);
        users[0] = bob;
        Social.UserStat[] memory st = social.userStats(users, alice);
        assertEq(st[0].encKey, key);
        assertEq(st[0].following, 1);
        assertTrue(st[0].followsViewer);
        assertEq(st[0].nonce, 2);
    }

    function test_unknownKind() public {
        Social.Action memory a = _action(bobPk, 99, postId, 1);
        vm.expectRevert(Social.UnknownKind.selector);
        social.submit(a);
    }
}
