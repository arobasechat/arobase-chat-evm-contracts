// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {Inbox} from "../src/Inbox.sol";

contract InboxTest is Base {
    event Invite(bytes envelope);
    event Encrypted(bytes32 indexed tag, bytes ciphertext);

    function test_eventsCarryNoRecipientOrConversation() public {
        bytes[] memory envs = new bytes[](2);
        envs[0] = hex"01";
        envs[1] = hex"02";
        vm.expectEmit(address(inbox));
        emit Invite(hex"01");
        vm.expectEmit(address(inbox));
        emit Invite(hex"02");
        inbox.invite(envs);
        vm.expectEmit(address(inbox));
        emit Encrypted(bytes32("tag"), hex"beef");
        inbox.send(bytes32("tag"), hex"beef");
    }

    function test_limits() public {
        bytes[] memory envs = new bytes[](65);
        vm.expectRevert(Inbox.TooLarge.selector);
        inbox.invite(envs);
        envs = new bytes[](1);
        envs[0] = new bytes(1025);
        vm.expectRevert(Inbox.TooLarge.selector);
        inbox.invite(envs);
        vm.expectRevert(Inbox.TooLarge.selector);
        inbox.send(bytes32(0), new bytes(16385));
    }
}
