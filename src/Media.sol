// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Upgradeable} from "./base/Upgradeable.sol";

contract Media is Upgradeable {
    uint256 public constant MAX_SIZE = 131_072;

    event Stored(bytes32 indexed id, address indexed uploader, string mime, bytes data);

    error TooLarge();
    error Empty();
    error BadMime();

    function initialize(address owner_) external initializer {
        __Upgradeable_init(owner_);
    }

    function store(string calldata mime, bytes calldata data) external returns (bytes32 id) {
        if (data.length == 0) revert Empty();
        if (data.length > MAX_SIZE) revert TooLarge();
        if (!isAllowedMime(mime)) revert BadMime();
        id = keccak256(data);
        emit Stored(id, msg.sender, mime, data);
    }

    function isAllowedMime(string calldata mime) public pure returns (bool) {
        bytes32 h = keccak256(bytes(mime));
        return h == keccak256("image/png") || h == keccak256("image/jpeg") || h == keccak256("image/webp")
            || h == keccak256("image/gif");
    }
}
