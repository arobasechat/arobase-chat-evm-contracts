// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Content} from "../src/Content.sol";
import {Social} from "../src/Social.sol";
import {Stake} from "../src/Stake.sol";
import {Registry} from "../src/Registry.sol";
import {Inbox} from "../src/Inbox.sol";

abstract contract Base is Test {
    bytes32 internal constant DOMAIN_SEPARATOR = keccak256(
        abi.encode(keccak256("EIP712Domain(string name,string version)"), keccak256("arobase.chat"), keccak256("1"))
    );
    bytes32 internal constant MESSAGE_TYPEHASH =
        keccak256("Message(address author,uint8 kind,bytes32 parentId,uint64 ts,bytes32 payloadHash)");
    bytes32 internal constant ACTION_TYPEHASH =
        keccak256("Action(address author,uint8 kind,bytes32 target,int8 value,uint64 nonce)");
    bytes32 internal constant SESSION_TYPEHASH = keccak256("Session(address key,uint64 expiry)");

    Content internal content;
    Social internal social;
    Stake internal stake;
    Registry internal registry;
    Inbox internal inbox;

    uint256 internal alicePk = 0xA11CE;
    uint256 internal bobPk = 0xB0B;
    uint256 internal carolPk = 0xCA201;
    uint256 internal sessionPk = 0x5E5510;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal sessionKey;
    address internal gov = makeAddr("gov");

    function setUp() public virtual {
        vm.warp(1_760_000_000);
        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);
        carol = vm.addr(carolPk);
        sessionKey = vm.addr(sessionPk);

        content = _newContent(true);
        stake = new Stake(7 days);
        address[] memory admins = new address[](1);
        admins[0] = alice;
        social = Social(
            _proxy(address(new Social()), abi.encodeCall(Social.initialize, (gov, stake, 0.01 ether, 0.01 ether, admins)))
        );
        registry = Registry(_proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (gov))));
        inbox = Inbox(_proxy(address(new Inbox()), abi.encodeCall(Inbox.initialize, (gov))));
    }

    function _proxy(address impl, bytes memory init) internal returns (address) {
        return address(new ERC1967Proxy(impl, init));
    }

    function _newContent(bool indexing) internal returns (Content) {
        return Content(_proxy(address(new Content()), abi.encodeCall(Content.initialize, (gov, indexing))));
    }

    function _digest(bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _sign(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
        return abi.encodePacked(r, s, v);
    }

    function _messageHash(address author, uint8 kind, bytes32 parentId, uint64 ts, bytes memory payload)
        internal
        pure
        returns (bytes32)
    {
        return _digest(keccak256(abi.encode(MESSAGE_TYPEHASH, author, kind, parentId, ts, keccak256(payload))));
    }

    function _actionHash(address author, uint8 kind, bytes32 target, int8 value, uint64 nonce)
        internal
        pure
        returns (bytes32)
    {
        return _digest(keccak256(abi.encode(ACTION_TYPEHASH, author, kind, target, value, nonce)));
    }

    function _delegation(uint256 identityPk, address key, uint64 expiry) internal pure returns (bytes memory) {
        return abi.encodePacked(
            _sign(identityPk, _digest(keccak256(abi.encode(SESSION_TYPEHASH, key, expiry)))), bytes8(expiry)
        );
    }

    function _publish(uint256 pk, uint8 kind, bytes32 parentId, bytes memory payload) internal returns (bytes32) {
        address author = vm.addr(pk);
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(pk, _messageHash(author, kind, parentId, ts, payload));
        return content.publish(author, kind, parentId, ts, payload, sig);
    }

    function _action(uint256 pk, uint8 kind, bytes32 target, int8 value)
        internal
        view
        returns (Social.Action memory a)
    {
        address author = vm.addr(pk);
        uint64 nonce = social.nonces(author);
        a = Social.Action(author, kind, target, value, nonce, _sign(pk, _actionHash(author, kind, target, value, nonce)));
    }

    function _revokeHash(address author, address key) internal pure returns (bytes32) {
        return _digest(keccak256(abi.encode(keccak256("Revoke(address author,address key)"), author, key)));
    }

    function _addrTarget(address who) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(who)));
    }
}
