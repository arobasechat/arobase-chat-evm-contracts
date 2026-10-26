// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {Content} from "../src/Content.sol";
import {Sig} from "../src/lib/Sig.sol";

contract ContentTest is Base {
    function test_publishStoresMetaAndIndexes() public {
        vm.roll(42);
        bytes32 id = _publish(alicePk, 0, bytes32(0), bytes('{"v":1,"text":"hello","ts":1}'));
        (address author, uint48 blockNumber, uint40 ts, uint8 kind, bytes32 parentId) = content.posts(id);
        assertEq(author, alice);
        assertEq(blockNumber, 42);
        assertEq(ts, block.timestamp);
        assertEq(kind, 0);
        assertEq(parentId, bytes32(0));
        assertEq(content.count(), 1);
        assertEq(content.authorCount(alice), 1);
        assertEq(content.latest(alice, 0), id);
    }

    function test_idIsHashOfSignature() public {
        bytes memory payload = bytes("x");
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(alicePk, _messageHash(alice, 0, bytes32(0), ts, payload));
        bytes32 id = content.publish(alice, 0, bytes32(0), ts, payload, sig);
        assertEq(id, keccak256(sig));
    }

    function test_replicationOnOtherChainYieldsSameId() public {
        bytes memory payload = bytes("replicated");
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(alicePk, _messageHash(alice, 0, bytes32(0), ts, payload));
        bytes32 a = content.publish(alice, 0, bytes32(0), ts, payload, sig);
        Content other = _newContent(true);
        vm.chainId(999);
        vm.prank(bob);
        bytes32 b = other.publish(alice, 0, bytes32(0), ts, payload, sig);
        assertEq(a, b);
    }

    function test_revertsOnDuplicate() public {
        bytes memory payload = bytes("dup");
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(alicePk, _messageHash(alice, 0, bytes32(0), ts, payload));
        bytes32 id = content.publish(alice, 0, bytes32(0), ts, payload, sig);
        vm.expectRevert(abi.encodeWithSelector(Content.AlreadyPublished.selector, id));
        content.publish(alice, 0, bytes32(0), ts, payload, sig);
    }

    function test_revertsOnForgedAuthor() public {
        bytes memory payload = bytes("forged");
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(bobPk, _messageHash(alice, 0, bytes32(0), ts, payload));
        vm.expectRevert(Sig.BadSignature.selector);
        content.publish(alice, 0, bytes32(0), ts, payload, sig);
    }

    function test_revertsOnTamperedPayload() public {
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(alicePk, _messageHash(alice, 0, bytes32(0), ts, bytes("a")));
        vm.expectRevert(Sig.BadSignature.selector);
        content.publish(alice, 0, bytes32(0), ts, bytes("b"), sig);
    }

    function test_revertsWhenFromTheFuture() public {
        uint64 ts = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sign(alicePk, _messageHash(alice, 0, bytes32(0), ts, bytes("f")));
        vm.expectRevert(Content.FromTheFuture.selector);
        content.publish(alice, 0, bytes32(0), ts, bytes("f"), sig);
    }

    function test_sessionKeyDelegation() public {
        uint64 expiry = uint64(block.timestamp + 30 days);
        bytes memory payload = bytes("via session");
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = abi.encodePacked(
            _sign(sessionPk, _messageHash(alice, 0, bytes32(0), ts, payload)), _delegation(alicePk, sessionKey, expiry)
        );
        assertEq(sig.length, 138);
        bytes32 id = content.publish(alice, 0, bytes32(0), ts, payload, sig);
        (address author,,,,) = content.posts(id);
        assertEq(author, alice);
    }

    function test_sessionKeyExpired() public {
        uint64 expiry = uint64(block.timestamp - 1);
        bytes memory payload = bytes("late");
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = abi.encodePacked(
            _sign(sessionPk, _messageHash(alice, 0, bytes32(0), ts, payload)), _delegation(alicePk, sessionKey, expiry)
        );
        vm.expectRevert(Sig.SessionExpired.selector);
        content.publish(alice, 0, bytes32(0), ts, payload, sig);
    }

    function test_sessionKeyDelegatedByWrongIdentity() public {
        uint64 expiry = uint64(block.timestamp + 1 days);
        bytes memory payload = bytes("nope");
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = abi.encodePacked(
            _sign(sessionPk, _messageHash(alice, 0, bytes32(0), ts, payload)), _delegation(bobPk, sessionKey, expiry)
        );
        vm.expectRevert(Sig.BadSignature.selector);
        content.publish(alice, 0, bytes32(0), ts, payload, sig);
    }

    function test_childrenAndPagination() public {
        bytes32 root = _publish(alicePk, 0, bytes32(0), bytes("root"));
        bytes32[] memory replies = new bytes32[](5);
        for (uint256 i; i < 5; ++i) {
            vm.warp(block.timestamp + 1);
            replies[i] = _publish(bobPk, 1, root, abi.encodePacked("reply", i));
        }
        assertEq(content.childCount(root), 5);
        (bytes32[] memory page,,) = content.page(2, root, type(uint256).max, 2);
        assertEq(page.length, 2);
        assertEq(page[0], replies[4]);
        assertEq(page[1], replies[3]);
        (page,,) = content.page(2, root, 3, 10);
        assertEq(page.length, 3);
        assertEq(page[0], replies[2]);
        assertEq(page[2], replies[0]);
        (page,,) = content.page(0, bytes32(0), type(uint256).max, 100);
        assertEq(page.length, 6);
        assertEq(page[5], root);

        (bytes32[] memory got, Content.Meta[] memory metas, uint256 total) =
            content.page(2, root, type(uint256).max, 2);
        assertEq(total, 5);
        assertEq(got[0], replies[4]);
        assertEq(metas[0].author, bob);
        (got,, total) = content.page(1, bytes32(uint256(uint160(alice))), type(uint256).max, 10);
        assertEq(total, 1);
        assertEq(got[0], root);
    }

    function test_getMetasAndLatestMany() public {
        bytes32 a = _publish(alicePk, 3, bytes32(0), bytes('{"name":"Alice"}'));
        bytes32 b = _publish(bobPk, 0, bytes32(0), bytes("bob post"));
        bytes32[] memory keys = new bytes32[](2);
        keys[0] = a;
        keys[1] = b;
        Content.Meta[] memory metas = content.getMetas(keys);
        assertEq(metas[0].author, alice);
        assertEq(metas[1].author, bob);
        address[] memory authors = new address[](2);
        authors[0] = alice;
        authors[1] = bob;
        bytes32[] memory profiles = content.latestMany(authors, 3);
        assertEq(profiles[0], a);
        assertEq(profiles[1], bytes32(0));
    }

    function test_cannotNoteOwnPost() public {
        bytes32 post = _publish(alicePk, 0, bytes32(0), bytes("mine"));
        bytes memory payload = bytes("self note");
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(alicePk, _messageHash(alice, 2, post, ts, payload));
        vm.expectRevert(Content.SelfNote.selector);
        content.publish(alice, 2, post, ts, payload, sig);
        _publish(bobPk, 2, post, bytes("other note"));
        assertEq(content.childCount(post), 1);
    }

    function test_payloadTooLarge() public {
        bytes memory payload = new bytes(8193);
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(alicePk, _messageHash(alice, 0, bytes32(0), ts, payload));
        vm.expectRevert(Content.PayloadTooLarge.selector);
        content.publish(alice, 0, bytes32(0), ts, payload, sig);
    }

    function testFuzz_publishAnyPayload(bytes calldata payload, uint8 kind) public {
        vm.assume(payload.length <= 8192);
        kind = uint8(bound(kind, 0, content.MAX_KIND()));
        bytes32 id = _publish(carolPk, kind, bytes32(0), payload);
        (address author,,, uint8 k,) = content.posts(id);
        assertEq(author, carol);
        assertEq(k, kind);
    }
}
