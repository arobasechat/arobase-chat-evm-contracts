// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Sig} from "./lib/Sig.sol";
import {Upgradeable} from "./base/Upgradeable.sol";

contract Names is Upgradeable {
    bytes32 public constant NAME_TYPEHASH = keccak256("Name(address author,string name,uint64 nonce)");
    uint256 public constant MIN_LENGTH = 3;
    uint256 public constant MAX_LENGTH = 20;

    mapping(bytes32 => address) public ownerOf;
    mapping(address => string) public nameOf;
    mapping(address => uint64) public nonces;

    string[] private _log;
    address[] private _logOwner;

    event NameChanged(address indexed owner, bytes32 indexed nameHash, string name);

    error InvalidName();
    error NameTaken();
    error BadNonce();

    function initialize(address owner_) external initializer {
        __Upgradeable_init(owner_);
    }

    function claim(address author, string calldata name, uint64 nonce, bytes calldata sig) external {
        if (!isValid(name)) revert InvalidName();
        if (nonce != nonces[author]) revert BadNonce();
        bytes32 structHash = keccak256(abi.encode(NAME_TYPEHASH, author, keccak256(bytes(name)), nonce));
        Sig.verifyIdentity(author, Sig.digest(structHash), sig);

        bytes32 h = keccak256(bytes(name));
        address current = ownerOf[h];
        if (current != address(0) && current != author) revert NameTaken();

        string memory previous = nameOf[author];
        if (bytes(previous).length != 0) delete ownerOf[keccak256(bytes(previous))];

        unchecked {
            nonces[author] = nonce + 1;
        }
        ownerOf[h] = author;
        nameOf[author] = name;
        _log.push(name);
        _logOwner.push(author);
        emit NameChanged(author, h, name);
    }

    function isValid(string calldata name) public pure returns (bool) {
        bytes calldata b = bytes(name);
        if (b.length < MIN_LENGTH || b.length > MAX_LENGTH) return false;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x5f;
            if (!ok) return false;
        }
        return true;
    }

    function available(string calldata name) external view returns (bool) {
        return isValid(name) && ownerOf[keccak256(bytes(name))] == address(0);
    }

    function resolve(string calldata name) external view returns (address) {
        return ownerOf[keccak256(bytes(name))];
    }

    function namesOf(address[] calldata users) external view returns (string[] memory out) {
        out = new string[](users.length);
        for (uint256 i; i < users.length; ++i) {
            out[i] = nameOf[users[i]];
        }
    }

    function count() external view returns (uint256) {
        return _log.length;
    }

    function page(uint256 offset, uint256 limit) external view returns (string[] memory names, address[] memory owners) {
        uint256 len = _log.length;
        if (offset >= len) return (names, owners);
        uint256 n = len - offset < limit ? len - offset : limit;
        names = new string[](n);
        owners = new address[](n);
        for (uint256 i; i < n; ++i) {
            string storage name = _log[offset + i];
            address owner = _logOwner[offset + i];
            if (ownerOf[keccak256(bytes(name))] == owner) {
                names[i] = name;
                owners[i] = owner;
            }
        }
    }
}
