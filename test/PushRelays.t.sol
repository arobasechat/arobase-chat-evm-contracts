// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {PushRelays} from "../src/PushRelays.sol";

contract PushRelaysTest is Base {
    PushRelays internal relays;
    address internal op = makeAddr("op");
    bytes internal vapid;

    function setUp() public override {
        super.setUp();
        relays = PushRelays(_proxy(address(new PushRelays()), abi.encodeCall(PushRelays.initialize, (gov))));
        vapid = abi.encodePacked(bytes1(0x04), keccak256("x"), keccak256("y"));
    }

    function test_registerAndSubscribe() public {
        vm.prank(op);
        uint256 id = relays.register("Relais", "https://example.org", keccak256("enc"), vapid);
        assertEq(id, 0);
        assertEq(relays.count(), 1);
        PushRelays.Relay memory r = relays.get(0);
        assertEq(r.operator, op);
        assertTrue(r.active);
        assertEq(r.vapid, vapid);

        vm.recordLogs();
        relays.subscribe(0, hex"deadbeef");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[1], bytes32(uint256(0)));
    }

    function test_onlyOperatorUpdates() public {
        vm.prank(op);
        relays.register("Relais", "", keccak256("enc"), vapid);
        vm.expectRevert(PushRelays.NotOperator.selector);
        relays.update(0, "x", "", keccak256("enc"), vapid, false);
        vm.prank(op);
        relays.update(0, "x", "", keccak256("enc2"), vapid, false);
        vm.expectRevert(PushRelays.InactiveRelay.selector);
        relays.subscribe(0, hex"01");
        vm.prank(op);
        relays.transferRelay(0, address(this));
        relays.update(0, "x", "", keccak256("enc2"), vapid, true);
        relays.subscribe(0, hex"01");
    }

    function test_rejectsBadInput() public {
        vm.expectRevert(PushRelays.BadKey.selector);
        relays.register("r", "", bytes32(0), vapid);
        vm.expectRevert(PushRelays.BadKey.selector);
        relays.register("r", "", keccak256("enc"), hex"0401");
        vm.expectRevert(PushRelays.UnknownRelay.selector);
        relays.subscribe(3, hex"01");
        relays.register("r", "", keccak256("enc"), vapid);
        vm.expectRevert(PushRelays.TooLarge.selector);
        relays.subscribe(0, new bytes(8193));
    }
}
