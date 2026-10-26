// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Sig} from "../lib/Sig.sol";

abstract contract Sessions {
    bytes32 private constant SESSIONS_SLOT = 0x455954aba41e04ad70739943d2beae821422b828d68b0d7f7e8dbeb2b352eb00;

    struct SessionsStorage {
        mapping(address => mapping(address => uint64)) revokedAt;
    }

    event SessionRevoked(address indexed author, address indexed key);

    function revoke(address author, address key, bytes calldata sig) external {
        if (!Sig.revoker(author, key, sig)) revert Sig.BadSignature();
        mapping(address => uint64) storage r = _sessions().revokedAt[author];
        if (r[key] != 0) return;
        r[key] = uint64(block.timestamp);
        emit SessionRevoked(author, key);
    }

    function sessionRevokedAt(address author, address key) public view returns (uint64) {
        return _sessions().revokedAt[author][key];
    }

    function revokedAtMany(address[] calldata authors, address[] calldata keys) external view returns (uint64[] memory out) {
        out = new uint64[](authors.length);
        for (uint256 i; i < authors.length; ++i) {
            out[i] = _sessions().revokedAt[authors[i]][keys[i]];
        }
    }

    function _verify(address author, bytes32 hash, bytes calldata sig) internal view returns (address signer) {
        signer = Sig.verify(author, hash, sig);
        if (signer != author && _sessions().revokedAt[author][signer] != 0) revert Sig.SessionRevoked();
    }

    function _tryVerify(address author, bytes32 hash, bytes calldata sig) internal view returns (bool ok, address signer) {
        (ok, signer) = Sig.tryVerify(author, hash, sig);
        if (ok && signer != author && _sessions().revokedAt[author][signer] != 0) ok = false;
    }

    function _sessions() private pure returns (SessionsStorage storage $) {
        bytes32 slot = SESSIONS_SLOT;
        assembly {
            $.slot := slot
        }
    }
}
