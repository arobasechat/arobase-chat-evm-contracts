// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Sig} from "./lib/Sig.sol";
import {Upgradeable} from "./base/Upgradeable.sol";

interface ISessionRegistry {
    function sessionRevokedAt(address author, address key) external view returns (uint64);
}

contract Vault is Upgradeable {
    struct Entry {
        uint64 version;
        uint64 blockNumber;
        bytes32 dataHash;
    }

    bytes32 public constant SAVE_TYPEHASH =
        keccak256("Save(address author,bytes32 key,uint64 version,bytes32 dataHash)");
    uint256 public constant MAX_DATA = 16384;

    mapping(address => mapping(bytes32 => Entry)) private _entries;
    ISessionRegistry public sessions;

    event SessionsSet(address sessions);
    event Saved(address indexed author, bytes32 indexed key, uint64 version, bytes data);

    error TooLarge();
    error StaleVersion();

    function initialize(address owner_, ISessionRegistry sessions_) external initializer {
        __Upgradeable_init(owner_);
        sessions = sessions_;
        emit SessionsSet(address(sessions_));
    }

    function setSessions(ISessionRegistry sessions_) external onlyOwner {
        sessions = sessions_;
        emit SessionsSet(address(sessions_));
    }

    function save(address author, bytes32 key, uint64 version, bytes calldata data, bytes calldata sig) external {
        if (data.length > MAX_DATA) revert TooLarge();
        if (version != _entries[author][key].version + 1) revert StaleVersion();
        bytes32 dataHash = keccak256(data);
        if (msg.sender != author) {
            bytes32 structHash = keccak256(abi.encode(SAVE_TYPEHASH, author, key, version, dataHash));
            address signer = Sig.verify(author, Sig.digest(structHash), sig);
            if (signer != author && address(sessions) != address(0) && sessions.sessionRevokedAt(author, signer) != 0) {
                revert Sig.SessionRevoked();
            }
        }
        _entries[author][key] = Entry(version, uint64(block.number), dataHash);
        emit Saved(author, key, version, data);
    }

    function entry(address author, bytes32 key) external view returns (Entry memory) {
        return _entries[author][key];
    }

    function entries(address author, bytes32[] calldata keys) external view returns (Entry[] memory out) {
        out = new Entry[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            out[i] = _entries[author][keys[i]];
        }
    }
}
