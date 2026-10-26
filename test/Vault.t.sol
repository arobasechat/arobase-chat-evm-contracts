// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {Vault, ISessionRegistry} from "../src/Vault.sol";
import {Sig} from "../src/lib/Sig.sol";

contract VaultTest is Base {
    Vault internal vault;
    bytes32 internal constant KEY = "sync";

    function setUp() public override {
        super.setUp();
        vault = Vault(_proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (gov, ISessionRegistry(address(social))))));
    }

    function _saveSig(uint256 pk, address author, uint64 version, bytes memory data) internal view returns (bytes memory) {
        return _sign(pk, _digest(keccak256(abi.encode(vault.SAVE_TYPEHASH(), author, KEY, version, keccak256(data)))));
    }

    function test_relayedSaveWithSignature() public {
        vm.roll(77);
        bytes memory data = hex"c0ffee";
        vm.prank(bob);
        vault.save(alice, KEY, 1, data, _saveSig(alicePk, alice, 1, data));
        Vault.Entry memory e = vault.entry(alice, KEY);
        assertEq(e.version, 1);
        assertEq(e.blockNumber, 77);
        assertEq(e.dataHash, keccak256(data));
    }

    function test_sessionKeySave() public {
        bytes memory data = hex"01";
        uint64 expiry = uint64(block.timestamp + 1 days);
        bytes memory sig = abi.encodePacked(
            _sign(sessionPk, _digest(keccak256(abi.encode(vault.SAVE_TYPEHASH(), alice, KEY, uint64(1), keccak256(data))))),
            _delegation(alicePk, sessionKey, expiry)
        );
        vault.save(alice, KEY, 1, data, sig);
        assertEq(vault.entry(alice, KEY).version, 1);
    }

    function test_directSaveNeedsNoSignature() public {
        vm.prank(alice);
        vault.save(alice, KEY, 1, hex"02", "");
        assertEq(vault.entry(alice, KEY).version, 1);
    }

    function test_rejectsStaleVersionAndForgery() public {
        vm.prank(alice);
        vault.save(alice, KEY, 1, hex"02", "");
        vm.prank(alice);
        vm.expectRevert(Vault.StaleVersion.selector);
        vault.save(alice, KEY, 1, hex"03", "");
        vm.prank(alice);
        vm.expectRevert(Vault.StaleVersion.selector);
        vault.save(alice, KEY, type(uint64).max, hex"03", "");
        bytes memory data = hex"04";
        bytes memory forged = _saveSig(bobPk, alice, 2, data);
        vm.expectRevert(Sig.BadSignature.selector);
        vault.save(alice, KEY, 2, data, forged);
    }

    function test_tooLarge() public {
        vm.prank(alice);
        vm.expectRevert(Vault.TooLarge.selector);
        vault.save(alice, KEY, 1, new bytes(16385), "");
    }
}
