// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Sig} from "./lib/Sig.sol";
import {Upgradeable} from "./base/Upgradeable.sol";
import {Sessions} from "./base/Sessions.sol";

contract Content is Upgradeable, Sessions {
    struct Meta {
        address author;
        uint48 blockNumber;
        uint40 ts;
        uint8 kind;
        bytes32 parentId;
    }

    struct Extra {
        uint32 reposts;
        uint32 quotes;
        bool retracted;
        bytes32 viewerRepost;
        uint8 viewerChoice;
        uint32[4] poll;
    }

    uint256 public constant MAX_PAYLOAD = 8192;
    uint256 public constant MAX_FUTURE_DRIFT = 5 minutes;
    uint256 public constant MIN_TAG = 2;
    uint256 public constant MAX_TAG = 50;
    uint256 public constant MAX_TAGS_PER_POST = 10;
    uint256 public constant MAX_MENTIONS = 10;

    uint8 public constant KIND_POST = 0;
    uint8 public constant KIND_COMMENT = 1;
    uint8 public constant KIND_NOTE = 2;
    uint8 public constant KIND_PROFILE = 3;
    uint8 public constant KIND_REPOST = 4;
    uint8 public constant KIND_RETRACT = 5;
    uint8 public constant KIND_VOTE = 6;
    uint8 public constant POLL_OPTIONS = 4;
    uint8 public constant MAX_KIND = KIND_VOTE + POLL_OPTIONS - 1;

    uint8 public constant SOURCE_ALL = 0;
    uint8 public constant SOURCE_AUTHOR = 1;
    uint8 public constant SOURCE_CHILDREN = 2;
    uint8 public constant SOURCE_TAG = 3;

    uint8 public constant MENTION = 1;
    uint8 public constant REPLY = 2;
    uint8 public constant NOTE = 3;
    uint8 public constant REPOST = 4;
    uint8 public constant QUOTE = 5;

    mapping(bytes32 => Meta) public posts;
    mapping(address => bytes32[]) public byAuthor;
    mapping(bytes32 => bytes32[]) public children;
    mapping(address => mapping(uint8 => bytes32)) public latest;
    bytes32[] public ids;
    bool public indexing;

    mapping(bytes32 => bytes32[]) private _byTag;
    mapping(bytes32 => string) public tagName;
    bytes32[] private _tags;
    mapping(bytes32 => bool) public retracted;
    mapping(bytes32 => uint32) public repostCount;
    mapping(bytes32 => uint32) public quoteCount;
    mapping(bytes32 => mapping(address => bytes32)) public repostOf;
    mapping(bytes32 => mapping(address => uint8)) public pollChoice;
    mapping(bytes32 => uint32[4]) private _pollCounts;

    event Message(bytes32 indexed id, address indexed author, uint8 indexed kind, bytes payload, bytes sig);
    event Tagged(bytes32 indexed tagHash, bytes32 indexed postId, address indexed author);
    event Notify(address indexed to, address indexed from, uint8 indexed reason, bytes32 postId);
    event Retracted(bytes32 indexed postId, address indexed author);
    event IndexingChanged(bool enabled);

    error AlreadyPublished(bytes32 id);
    error PayloadTooLarge();
    error FromTheFuture();
    error SelfNote();
    error UnknownSource();
    error UnknownKind();

    function initialize(address owner_, bool indexing_) external initializer {
        __Upgradeable_init(owner_);
        indexing = indexing_;
    }

    function setIndexing(bool enabled) external onlyOwner {
        indexing = enabled;
        emit IndexingChanged(enabled);
    }

    function publish(
        address author,
        uint8 kind,
        bytes32 parentId,
        uint64 ts,
        bytes calldata payload,
        bytes calldata sig
    ) external returns (bytes32 id) {
        if (payload.length > MAX_PAYLOAD) revert PayloadTooLarge();
        if (kind > MAX_KIND) revert UnknownKind();
        if (ts > block.timestamp + MAX_FUTURE_DRIFT) revert FromTheFuture();
        _verify(author, Sig.messageHash(author, kind, parentId, ts, payload), sig);

        Meta storage parent = posts[parentId];
        if (kind == KIND_NOTE && parent.author == author) revert SelfNote();

        id = keccak256(sig);
        if (posts[id].author != address(0)) revert AlreadyPublished(id);

        posts[id] = Meta(author, uint48(block.number), uint40(ts), kind, parentId);
        byAuthor[author].push(id);
        ids.push(id);
        if (parentId != bytes32(0)) children[parentId].push(id);
        latest[author][kind] = id;

        emit Message(id, author, kind, payload, sig);
        if (indexing) _index(id, author, kind, parentId, parent.author, parent.kind, payload);
    }

    function count() external view returns (uint256) {
        return ids.length;
    }

    function authorCount(address author) external view returns (uint256) {
        return byAuthor[author].length;
    }

    function childCount(bytes32 parentId) external view returns (uint256) {
        return children[parentId].length;
    }

    function page(uint8 source, bytes32 key, uint256 end, uint256 limit)
        external
        view
        returns (bytes32[] memory out, Meta[] memory metas, uint256 total)
    {
        bytes32[] storage list = _list(source, key);
        total = list.length;
        if (end > total) end = total;
        uint256 n = limit < end ? limit : end;
        out = new bytes32[](n);
        metas = new Meta[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = list[end - 1 - i];
            metas[i] = posts[out[i]];
        }
    }

    function getMetas(bytes32[] calldata keys) external view returns (Meta[] memory out) {
        out = new Meta[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            out[i] = posts[keys[i]];
        }
    }

    function latestMany(address[] calldata authors, uint8 kind) external view returns (bytes32[] memory out) {
        out = new bytes32[](authors.length);
        for (uint256 i; i < authors.length; ++i) {
            out[i] = latest[authors[i]][kind];
        }
    }

    function extras(bytes32[] calldata keys, address viewer) external view returns (Extra[] memory out) {
        out = new Extra[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            bytes32 id = keys[i];
            out[i] = Extra(
                repostCount[id], quoteCount[id], retracted[id], repostOf[id][viewer], pollChoice[id][viewer], _pollCounts[id]
            );
        }
    }

    function tagCount() external view returns (uint256) {
        return _tags.length;
    }

    function tagCounts(bytes32[] calldata hashes) external view returns (uint256[] memory out) {
        out = new uint256[](hashes.length);
        for (uint256 i; i < hashes.length; ++i) {
            out[i] = _byTag[hashes[i]].length;
        }
    }

    function tagsPage(uint256 offset, uint256 limit)
        external
        view
        returns (string[] memory names, uint256[] memory counts)
    {
        uint256 len = _tags.length;
        if (offset >= len) return (names, counts);
        uint256 n = len - offset < limit ? len - offset : limit;
        names = new string[](n);
        counts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 h = _tags[offset + i];
            names[i] = tagName[h];
            counts[i] = _byTag[h].length;
        }
    }

    function _list(uint8 source, bytes32 key) private view returns (bytes32[] storage) {
        if (source == SOURCE_ALL) return ids;
        if (source == SOURCE_AUTHOR) return byAuthor[address(uint160(uint256(key)))];
        if (source == SOURCE_CHILDREN) return children[key];
        if (source == SOURCE_TAG) return _byTag[key];
        revert UnknownSource();
    }

    function _index(
        bytes32 id,
        address author,
        uint8 kind,
        bytes32 parentId,
        address parentAuthor,
        uint8 parentKind,
        bytes calldata payload
    ) private {
        if (kind == KIND_PROFILE) return;
        if (kind >= KIND_REPOST) {
            if (parentAuthor == address(0)) return;
            if (kind == KIND_REPOST) _repost(id, author, parentId, parentAuthor, parentKind);
            else if (kind == KIND_RETRACT) _retract(author, parentId, parentAuthor, parentKind);
            else if (parentKind == KIND_POST) _vote(author, parentId, kind - KIND_VOTE);
            return;
        }
        if (kind != KIND_POST && parentAuthor != address(0) && parentAuthor != author) {
            emit Notify(parentAuthor, author, kind == KIND_COMMENT ? REPLY : NOTE, id);
        }
        if (kind == KIND_NOTE) return;
        _indexTags(id, author, payload);
        _mentions(id, author, parentAuthor, payload);
        if (kind == KIND_POST) _quote(id, author, payload);
    }

    function _repost(bytes32 id, address author, bytes32 parentId, address parentAuthor, uint8 parentKind) private {
        if (parentKind > KIND_COMMENT || retracted[parentId] || repostOf[parentId][author] != bytes32(0)) return;
        repostOf[parentId][author] = id;
        ++repostCount[parentId];
        if (parentAuthor != author) emit Notify(parentAuthor, author, REPOST, id);
    }

    function _retract(address author, bytes32 target, address targetAuthor, uint8 targetKind) private {
        if (targetAuthor != author || retracted[target]) return;
        retracted[target] = true;
        emit Retracted(target, author);
        if (targetKind != KIND_REPOST) return;
        bytes32 original = posts[target].parentId;
        if (repostOf[original][author] == target) {
            delete repostOf[original][author];
            --repostCount[original];
        }
    }

    function _vote(address voter, bytes32 poll, uint8 choice) private {
        uint8 prev = pollChoice[poll][voter];
        if (prev == choice + 1) return;
        if (prev != 0) --_pollCounts[poll][prev - 1];
        pollChoice[poll][voter] = choice + 1;
        ++_pollCounts[poll][choice];
    }

    function _quote(bytes32 id, address author, bytes calldata payload) private {
        bytes memory key = bytes('"quote":"0x');
        uint256 len = payload.length;
        if (len < key.length + 64) return;
        for (uint256 i; i + key.length + 64 <= len; ++i) {
            bool hit = true;
            for (uint256 j; j < key.length; ++j) {
                if (payload[i + j] != key[j]) {
                    hit = false;
                    break;
                }
            }
            if (!hit) continue;
            uint256 value;
            for (uint256 j; j < 64; ++j) {
                uint8 d = _nibble(payload[i + key.length + j]);
                if (d > 15) return;
                value = (value << 4) | d;
            }
            bytes32 quoted = bytes32(value);
            address quotedAuthor = posts[quoted].author;
            if (quotedAuthor == address(0) || quoted == id) return;
            ++quoteCount[quoted];
            if (quotedAuthor != author) emit Notify(quotedAuthor, author, QUOTE, id);
            return;
        }
    }

    function _indexTags(bytes32 id, address author, bytes calldata payload) private {
        bytes32[MAX_TAGS_PER_POST] memory seen;
        uint256 found;
        uint256 len = payload.length;
        for (uint256 i; i < len && found < MAX_TAGS_PER_POST; ++i) {
            if (payload[i] != "#") continue;
            uint256 start = i + 1;
            uint256 end = start;
            while (end < len && end - start <= MAX_TAG && _isTagByte(payload[end])) ++end;
            uint256 n = end - start;
            i = end - 1;
            if (n < MIN_TAG || n > MAX_TAG) continue;
            bytes memory tag = new bytes(n);
            for (uint256 j; j < n; ++j) {
                bytes1 c = payload[start + j];
                tag[j] = c >= "A" && c <= "Z" ? bytes1(uint8(c) + 32) : c;
            }
            bytes32 h = keccak256(tag);
            bool dup;
            for (uint256 j; j < found; ++j) {
                if (seen[j] == h) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            seen[found++] = h;
            if (_byTag[h].length == 0) {
                tagName[h] = string(tag);
                _tags.push(h);
            }
            _byTag[h].push(id);
            emit Tagged(h, id, author);
        }
    }

    function _mentions(bytes32 id, address author, address skip, bytes calldata payload) private {
        address[MAX_MENTIONS] memory seen;
        uint256 found;
        uint256 len = payload.length;
        for (uint256 i; i + 42 < len && found < MAX_MENTIONS; ++i) {
            if (payload[i] != "@" || payload[i + 1] != "0" || (payload[i + 2] != "x" && payload[i + 2] != "X")) continue;
            uint160 value;
            bool ok = true;
            for (uint256 j; j < 40; ++j) {
                uint8 d = _nibble(payload[i + 3 + j]);
                if (d > 15) {
                    ok = false;
                    break;
                }
                value = (value << 4) | d;
            }
            if (!ok || (i + 43 < len && _nibble(payload[i + 43]) <= 15)) continue;
            i += 42;
            address to = address(value);
            if (to == author || to == skip || to == address(0)) continue;
            bool dup;
            for (uint256 j; j < found; ++j) {
                if (seen[j] == to) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            seen[found++] = to;
            emit Notify(to, author, MENTION, id);
        }
    }

    function _nibble(bytes1 c) private pure returns (uint8) {
        if (c >= "0" && c <= "9") return uint8(c) - 48;
        if (c >= "a" && c <= "f") return uint8(c) - 87;
        if (c >= "A" && c <= "F") return uint8(c) - 55;
        return 255;
    }

    function _isTagByte(bytes1 c) private pure returns (bool) {
        return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || uint8(c) >= 0x80;
    }
}
