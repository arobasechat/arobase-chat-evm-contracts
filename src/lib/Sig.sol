// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

library Sig {
    bytes32 internal constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,string version)");
    bytes32 internal constant DOMAIN_SEPARATOR =
        keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("arobase.chat"), keccak256("1")));

    bytes32 internal constant MESSAGE_TYPEHASH =
        keccak256("Message(address author,uint8 kind,bytes32 parentId,uint64 ts,bytes32 payloadHash)");
    bytes32 internal constant ACTION_TYPEHASH =
        keccak256("Action(address author,uint8 kind,bytes32 target,int8 value,uint64 nonce)");
    bytes32 internal constant SESSION_TYPEHASH = keccak256("Session(address key,uint64 expiry)");
    bytes32 internal constant REVOKE_TYPEHASH = keccak256("Revoke(address author,address key)");

    uint256 internal constant DIRECT_LEN = 65;
    uint256 internal constant DELEGATED_LEN = 138;

    error BadSignature();
    error SessionExpired();
    error SessionRevoked();
    error IdentityRequired();

    function digest(bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function messageHash(address author, uint8 kind, bytes32 parentId, uint64 ts, bytes calldata payload)
        internal
        pure
        returns (bytes32)
    {
        return digest(keccak256(abi.encode(MESSAGE_TYPEHASH, author, kind, parentId, ts, keccak256(payload))));
    }

    function actionHash(address author, uint8 kind, bytes32 target, int8 value, uint64 nonce)
        internal
        pure
        returns (bytes32)
    {
        return digest(keccak256(abi.encode(ACTION_TYPEHASH, author, kind, target, value, nonce)));
    }

    function sessionHash(address key, uint64 expiry) internal pure returns (bytes32) {
        return digest(keccak256(abi.encode(SESSION_TYPEHASH, key, expiry)));
    }

    function revokeHash(address author, address key) internal pure returns (bytes32) {
        return digest(keccak256(abi.encode(REVOKE_TYPEHASH, author, key)));
    }

    function verify(address author, bytes32 hash, bytes calldata sig) internal view returns (address signer) {
        bool ok;
        (ok, signer) = tryVerify(author, hash, sig);
        if (!ok) {
            if (sig.length == DELEGATED_LEN && signer != address(0) && block.timestamp > uint64(bytes8(sig[130:138]))) {
                revert SessionExpired();
            }
            revert BadSignature();
        }
    }

    function verifyIdentity(address author, bytes32 hash, bytes calldata sig) internal pure {
        if (sig.length != DIRECT_LEN) revert IdentityRequired();
        address signer = _tryRecover(hash, sig);
        if (signer == address(0) || signer != author) revert BadSignature();
    }

    function tryVerify(address author, bytes32 hash, bytes calldata sig) internal view returns (bool ok, address signer) {
        if (sig.length == DIRECT_LEN) {
            signer = _tryRecover(hash, sig);
            return (signer == author && signer != address(0), signer);
        }
        if (sig.length != DELEGATED_LEN) return (false, address(0));
        signer = _tryRecover(hash, sig[0:65]);
        uint64 expiry = uint64(bytes8(sig[130:138]));
        ok = signer != address(0) && block.timestamp <= expiry
            && _tryRecover(sessionHash(signer, expiry), sig[65:130]) == author;
    }

    function revoker(address author, address key, bytes calldata sig) internal view returns (bool) {
        bytes32 hash = revokeHash(author, key);
        if (sig.length == DIRECT_LEN) return _tryRecover(hash, sig) == author && author != address(0);
        (bool ok, address signer) = tryVerify(author, hash, sig);
        return ok && signer == key;
    }

    function _tryRecover(bytes32 hash, bytes calldata sig) private pure returns (address) {
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, v, r, s);
        return err == ECDSA.RecoverError.NoError ? signer : address(0);
    }
}
