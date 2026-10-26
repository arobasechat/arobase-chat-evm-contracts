// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {Media} from "../src/Media.sol";

contract MediaTest is Base {
    Media internal media;

    function setUp() public override {
        super.setUp();
        media = Media(_proxy(address(new Media()), abi.encodeCall(Media.initialize, (gov))));
    }

    function test_storeEmitsContentAddressedBlob() public {
        bytes memory data = hex"ffd8ffe000104a464946";
        vm.recordLogs();
        bytes32 id = media.store("image/jpeg", data);
        assertEq(id, keccak256(data));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[1], id);
        (string memory mime, bytes memory stored) = abi.decode(logs[0].data, (string, bytes));
        assertEq(mime, "image/jpeg");
        assertEq(stored, data);
    }

    function test_rejectsBadInput() public {
        vm.expectRevert(Media.Empty.selector);
        media.store("image/png", "");
        vm.expectRevert(Media.BadMime.selector);
        media.store("text/html", hex"01");
        vm.expectRevert(Media.BadMime.selector);
        media.store("image/svg+xml", hex"01");
        vm.expectRevert(Media.BadMime.selector);
        media.store("image/png; charset=x", hex"01");
        vm.expectRevert(Media.TooLarge.selector);
        media.store("image/webp", new bytes(131_073));
    }
}
