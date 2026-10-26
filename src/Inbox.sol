// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Upgradeable} from "./base/Upgradeable.sol";

contract Inbox is Upgradeable {
    uint256 public constant MAX_ENVELOPE = 1024;
    uint256 public constant MAX_INVITES = 64;
    uint256 public constant MAX_CIPHERTEXT = 16384;

    event Invite(bytes envelope);
    event Encrypted(bytes32 indexed tag, bytes ciphertext);

    error TooLarge();

    function initialize(address owner_) external initializer {
        __Upgradeable_init(owner_);
    }

    function invite(bytes[] calldata envelopes) external {
        if (envelopes.length > MAX_INVITES) revert TooLarge();
        for (uint256 i; i < envelopes.length; ++i) {
            if (envelopes[i].length > MAX_ENVELOPE) revert TooLarge();
            emit Invite(envelopes[i]);
        }
    }

    function send(bytes32 tag, bytes calldata ciphertext) external {
        if (ciphertext.length > MAX_CIPHERTEXT) revert TooLarge();
        emit Encrypted(tag, ciphertext);
    }
}
