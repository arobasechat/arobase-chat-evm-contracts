// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {Content} from "../src/Content.sol";

contract IndexingTest is Base {
    bytes32 internal constant NOTIFY = keccak256("Notify(address,address,uint8,bytes32)");

    function _notifies() internal returns (address[] memory to, uint8[] memory reasons) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; ++i) if (logs[i].topics[0] == NOTIFY) ++n;
        to = new address[](n);
        reasons = new uint8[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != NOTIFY) continue;
            to[n] = address(uint160(uint256(logs[i].topics[1])));
            reasons[n++] = uint8(uint256(logs[i].topics[3]));
        }
    }

    function _hex(address a) internal pure returns (string memory) {
        return vm.toString(a);
    }

    function test_hashtagsAreIndexedOnce() public {
        bytes32 id = _publish(alicePk, 0, bytes32(0), bytes('{"text":"#Gnosis et #gnosis puis #arc #x"}'));
        bytes32 h = keccak256("gnosis");
        (bytes32[] memory got,, uint256 total) = content.page(3, h, type(uint256).max, 10);
        assertEq(total, 1);
        assertEq(got[0], id);
        assertEq(content.tagCount(), 2);
        (string[] memory names, uint256[] memory counts) = content.tagsPage(0, 10);
        assertEq(names[0], "gnosis");
        assertEq(counts[0], 1);
        assertEq(content.tagName(keccak256("arc")), "arc");
    }

    function test_replyNoteAndMentionNotify() public {
        bytes32 post = _publish(alicePk, 0, bytes32(0), bytes("root"));
        vm.recordLogs();
        _publish(bobPk, 1, post, bytes(string.concat('{"text":"hey @', _hex(carol), ' et @', _hex(alice), '"}')));
        (address[] memory to, uint8[] memory reasons) = _notifies();
        assertEq(to.length, 2);
        assertEq(to[0], alice);
        assertEq(reasons[0], content.REPLY());
        assertEq(to[1], carol);
        assertEq(reasons[1], content.MENTION());
        vm.recordLogs();
        _publish(carolPk, 2, post, bytes("note"));
        (to, reasons) = _notifies();
        assertEq(to[0], alice);
        assertEq(reasons[0], content.NOTE());
    }

    function test_repostRetractAndUndo() public {
        bytes32 post = _publish(alicePk, 0, bytes32(0), bytes("original"));
        bytes32 repost = _publish(bobPk, 4, post, bytes(""));
        _publish(bobPk, 4, post, bytes("again"));
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = post;
        Content.Extra[] memory e = content.extras(keys, bob);
        assertEq(e[0].reposts, 1);
        assertEq(e[0].viewerRepost, repost);
        _publish(bobPk, 5, repost, bytes(""));
        e = content.extras(keys, bob);
        assertEq(e[0].reposts, 0);
        assertEq(e[0].viewerRepost, bytes32(0));
        _publish(carolPk, 5, post, bytes(""));
        assertFalse(content.retracted(post));
        _publish(alicePk, 5, post, bytes(""));
        assertTrue(content.retracted(post));
    }

    function test_pollVotesCanChange() public {
        bytes32 poll = _publish(alicePk, 0, bytes32(0), bytes('{"poll":{"options":["a","b"]}}'));
        _publish(bobPk, 6, poll, bytes(""));
        vm.warp(block.timestamp + 1);
        _publish(carolPk, 7, poll, bytes(""));
        vm.warp(block.timestamp + 1);
        _publish(bobPk, 7, poll, bytes(""));
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = poll;
        Content.Extra[] memory e = content.extras(keys, bob);
        assertEq(e[0].poll[0], 0);
        assertEq(e[0].poll[1], 2);
        assertEq(e[0].viewerChoice, 2);
    }

    function test_quoteCountsAndNotifies() public {
        bytes32 post = _publish(alicePk, 0, bytes32(0), bytes("quoted"));
        vm.recordLogs();
        _publish(bobPk, 0, bytes32(0), bytes(string.concat('{"text":"lol","quote":"', vm.toString(post), '"}')));
        (address[] memory to, uint8[] memory reasons) = _notifies();
        assertEq(to[0], alice);
        assertEq(reasons[0], content.QUOTE());
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = post;
        assertEq(content.extras(keys, bob)[0].quotes, 1);
    }

    function test_indexingCanBeDisabled() public {
        Content anchor = _newContent(false);
        bytes memory payload = bytes("#anchored");
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(alicePk, _messageHash(alice, 0, bytes32(0), ts, payload));
        anchor.publish(alice, 0, bytes32(0), ts, payload, sig);
        assertEq(anchor.tagCount(), 0);
        vm.prank(gov);
        anchor.setIndexing(true);
        assertTrue(anchor.indexing());
    }
}
