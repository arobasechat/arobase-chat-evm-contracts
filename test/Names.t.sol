// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {Names} from "../src/Names.sol";
import {Sig} from "../src/lib/Sig.sol";

contract NamesTest is Base {
    Names internal names;

    function setUp() public override {
        super.setUp();
        names = Names(_proxy(address(new Names()), abi.encodeCall(Names.initialize, (gov))));
    }

    function _sig(uint256 pk, string memory name, uint64 nonce) internal view returns (bytes memory) {
        return _sigFor(pk, vm.addr(pk), name, nonce);
    }

    function _sigFor(uint256 pk, address author, string memory name, uint64 nonce) internal view returns (bytes memory) {
        return _sign(pk, _digest(keccak256(abi.encode(names.NAME_TYPEHASH(), author, keccak256(bytes(name)), nonce))));
    }

    function _claim(uint256 pk, string memory name) internal {
        address author = vm.addr(pk);
        uint64 nonce = names.nonces(author);
        names.claim(author, name, nonce, _sig(pk, name, nonce));
    }

    function test_claimAndResolve() public {
        _claim(alicePk, "alice_42");
        assertEq(names.resolve("alice_42"), alice);
        assertEq(names.nameOf(alice), "alice_42");
        assertFalse(names.available("alice_42"));
    }

    function test_cannotTakeSomeoneElsesName() public {
        _claim(alicePk, "camille");
        uint64 nonce = names.nonces(bob);
        bytes memory sig = _sig(bobPk, "camille", nonce);
        vm.expectRevert(Names.NameTaken.selector);
        names.claim(bob, "camille", nonce, sig);
    }

    function test_renameReleasesOldName() public {
        _claim(alicePk, "first");
        _claim(alicePk, "second");
        assertEq(names.resolve("first"), address(0));
        assertEq(names.resolve("second"), alice);
        _claim(bobPk, "first");
        assertEq(names.resolve("first"), bob);
        (string[] memory list, address[] memory owners) = names.page(0, 10);
        assertEq(list.length, 3);
        assertEq(bytes(list[0]).length, 0);
        assertEq(list[1], "second");
        assertEq(owners[2], bob);
    }

    function test_rejectsInvalidNames() public {
        string[5] memory bad = ["ab", "Alice", "with space", "accent\xc3\xa9", "waytoolongname_123456"];
        for (uint256 i; i < bad.length; ++i) assertFalse(names.isValid(bad[i]));
        assertTrue(names.isValid("ok_name_9"));
        uint64 nonce = names.nonces(alice);
        bytes memory sig = _sig(alicePk, "Alice", nonce);
        vm.expectRevert(Names.InvalidName.selector);
        names.claim(alice, "Alice", nonce, sig);
    }

    function test_rejectsForgedSignature() public {
        uint64 nonce = names.nonces(alice);
        bytes memory sig = _sig(bobPk, "stolen", nonce);
        vm.expectRevert(Sig.BadSignature.selector);
        names.claim(alice, "stolen", nonce, sig);
    }

    function test_replayRejected() public {
        uint64 nonce = names.nonces(alice);
        bytes memory sig = _sig(alicePk, "once", nonce);
        names.claim(alice, "once", nonce, sig);
        vm.expectRevert(Names.BadNonce.selector);
        names.claim(alice, "once", nonce, sig);
    }

    function test_sessionKeyCannotClaim() public {
        uint64 expiry = uint64(block.timestamp + 1 days);
        uint64 nonce = names.nonces(alice);
        bytes memory sig = abi.encodePacked(_sigFor(sessionPk, alice, "via_session", nonce), _delegation(alicePk, sessionKey, expiry));
        vm.expectRevert(Sig.IdentityRequired.selector);
        names.claim(alice, "via_session", nonce, sig);
    }

    function test_namesOf() public {
        _claim(alicePk, "aaa");
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        string[] memory out = names.namesOf(users);
        assertEq(out[0], "aaa");
        assertEq(bytes(out[1]).length, 0);
    }
}
