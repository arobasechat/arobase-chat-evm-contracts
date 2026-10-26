// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Sig} from "./lib/Sig.sol";
import {Upgradeable} from "./base/Upgradeable.sol";
import {Sessions} from "./base/Sessions.sol";
import {Stake} from "./Stake.sol";

contract Social is Upgradeable, Sessions {
    struct Action {
        address author;
        uint8 kind;
        bytes32 target;
        int8 value;
        uint64 nonce;
        bytes sig;
    }

    struct PostStat {
        uint256 likes;
        uint256 dislikes;
        int256 hideScore;
        uint32 flags;
        int8 viewerReaction;
        int8 viewerVote;
    }

    struct UserStat {
        uint256 followers;
        uint256 following;
        uint8 role;
        bool viewerFollows;
        bool followsViewer;
        bytes32 encKey;
        uint64 nonce;
        uint64 firstSeen;
        uint64 weight;
    }

    struct NoteStat {
        uint32 helpful;
        uint32 notHelpful;
        int8 viewerRating;
    }

    uint8 public constant KIND_REACT = 10;
    uint8 public constant KIND_FOLLOW = 11;
    uint8 public constant KIND_MOD_VOTE = 12;
    uint8 public constant KIND_ENC_KEY = 13;
    uint8 public constant KIND_RATE_NOTE = 15;
    uint8 public constant KIND_ROLE = 20;

    uint8 public constant ROLE_USER = 0;
    uint8 public constant ROLE_MODERATOR = 1;
    uint8 public constant ROLE_ADMIN = 2;

    uint256 public constant MAX_MOD_VOTERS = 256;

    Stake public stake;
    uint256 public minStake;
    uint256 public stakeUnit;

    mapping(address => uint64) public nonces;
    mapping(address => uint64) public firstSeen;

    mapping(bytes32 => uint256) public likeCount;
    mapping(bytes32 => uint256) public dislikeCount;
    mapping(bytes32 => mapping(address => int8)) public reaction;

    mapping(address => mapping(address => bool)) public isFollowing;
    mapping(address => uint256) public followerCount;
    mapping(address => address[]) private _following;
    mapping(address => address[]) private _followers;
    mapping(address => mapping(address => uint256)) private _followingIdx;
    mapping(address => mapping(address => uint256)) private _followersIdx;

    mapping(address => uint8) public role;
    address[] private _staff;
    mapping(address => uint256) private _staffIdx;
    uint256 public adminCount;

    mapping(bytes32 => mapping(address => int8)) public modVote;
    mapping(bytes32 => address[]) private _modVoters;
    mapping(bytes32 => mapping(address => uint256)) private _modVoterIdx;
    mapping(bytes32 => mapping(address => bool)) public modFlag;
    mapping(bytes32 => uint32) public flagCount;

    mapping(bytes32 => mapping(address => int8)) public noteRating;
    mapping(bytes32 => uint32) public helpfulCount;
    mapping(bytes32 => uint32) public notHelpfulCount;
    mapping(bytes32 => address[]) private _noteRaters;
    mapping(bytes32 => mapping(address => bool)) private _noteRated;

    mapping(address => bytes32) public encKey;

    event Acted(
        address indexed author, uint8 indexed kind, bytes32 indexed target, int8 value, uint64 nonce, address signer
    );
    event Rejected(uint256 indexed index, address indexed author, bytes4 reason);
    event RoleChanged(address indexed account, uint8 role, address indexed by);
    event StakeChanged(address indexed stake, uint256 minStake, uint256 stakeUnit);

    error BadNonce();
    error BadSignature();
    error IdentityRequired();
    error TooManyVoters();
    error UnknownKind();
    error InvalidValue();
    error NotAuthorized();
    error LastAdmin();

    function initialize(address owner_, Stake stake_, uint256 minStake_, uint256 stakeUnit_, address[] calldata admins)
        external
        initializer
    {
        __Upgradeable_init(owner_);
        _setStake(stake_, minStake_, stakeUnit_);
        for (uint256 i; i < admins.length; ++i) {
            _setRole(admins[i], ROLE_ADMIN, address(0));
        }
    }

    function submit(Action calldata a) external {
        bytes4 err = _apply(a);
        if (err != bytes4(0)) {
            assembly {
                mstore(0, err)
                revert(0, 4)
            }
        }
    }

    function submitBatch(Action[] calldata actions) external returns (uint256 applied) {
        for (uint256 i; i < actions.length; ++i) {
            bytes4 err = _apply(actions[i]);
            if (err == bytes4(0)) {
                ++applied;
            } else {
                emit Rejected(i, actions[i].author, err);
            }
        }
    }

    function setStake(Stake stake_, uint256 minStake_, uint256 stakeUnit_) external onlyOwner {
        _setStake(stake_, minStake_, stakeUnit_);
    }

    function setRole(address account, uint8 newRole) external onlyOwner {
        if (newRole > ROLE_ADMIN) revert InvalidValue();
        if (role[account] == ROLE_ADMIN && newRole != ROLE_ADMIN && adminCount == 1) revert LastAdmin();
        _setRole(account, newRole, msg.sender);
    }

    function _apply(Action calldata a) private returns (bytes4) {
        if (a.nonce != nonces[a.author]) return BadNonce.selector;
        bytes32 hash = Sig.actionHash(a.author, a.kind, a.target, a.value, a.nonce);
        (bool ok, address signer) = _tryVerify(a.author, hash, a.sig);
        if (!ok) return BadSignature.selector;

        bytes4 err;
        uint8 kind = a.kind;
        if ((kind == KIND_ENC_KEY || kind == KIND_ROLE) && signer != a.author) return IdentityRequired.selector;
        if (kind == KIND_REACT) err = _react(a.author, a.target, a.value);
        else if (kind == KIND_FOLLOW) err = _follow(a.author, address(uint160(uint256(a.target))), a.value);
        else if (kind == KIND_MOD_VOTE) err = _modVote(a.author, a.target, a.value);
        else if (kind == KIND_ENC_KEY) encKey[a.author] = a.target;
        else if (kind == KIND_RATE_NOTE) err = _rateNote(a.author, a.target, a.value);
        else if (kind == KIND_ROLE) err = _roleAction(a.author, address(uint160(uint256(a.target))), a.value);
        else err = UnknownKind.selector;
        if (err != bytes4(0)) return err;

        unchecked {
            nonces[a.author] = a.nonce + 1;
        }
        if (firstSeen[a.author] == 0) firstSeen[a.author] = uint64(block.timestamp);
        emit Acted(a.author, kind, a.target, a.value, a.nonce, signer);
        return bytes4(0);
    }

    function _setStake(Stake stake_, uint256 minStake_, uint256 stakeUnit_) private {
        stake = stake_;
        minStake = minStake_;
        stakeUnit = stakeUnit_ == 0 ? 1 : stakeUnit_;
        emit StakeChanged(address(stake_), minStake_, stakeUnit);
    }

    function _react(address author, bytes32 target, int8 value) private returns (bytes4) {
        if (value < -1 || value > 1) return InvalidValue.selector;
        int8 prev = reaction[target][author];
        if (prev == value) return bytes4(0);
        if (prev == 1) --likeCount[target];
        else if (prev == -1) --dislikeCount[target];
        if (value == 1) ++likeCount[target];
        else if (value == -1) ++dislikeCount[target];
        reaction[target][author] = value;
        return bytes4(0);
    }

    function _follow(address author, address target, int8 value) private returns (bytes4) {
        if (target == author || target == address(0)) return InvalidValue.selector;
        if (value == 1) {
            if (isFollowing[author][target]) return bytes4(0);
            isFollowing[author][target] = true;
            ++followerCount[target];
            _following[author].push(target);
            _followingIdx[author][target] = _following[author].length;
            _followers[target].push(author);
            _followersIdx[target][author] = _followers[target].length;
        } else if (value == 0) {
            if (!isFollowing[author][target]) return bytes4(0);
            isFollowing[author][target] = false;
            --followerCount[target];
            _removeFrom(_following[author], _followingIdx[author], target);
            _removeFrom(_followers[target], _followersIdx[target], author);
        } else {
            return InvalidValue.selector;
        }
        return bytes4(0);
    }

    function _modVote(address author, bytes32 target, int8 value) private returns (bytes4) {
        if (value < -1 || value > 1) return InvalidValue.selector;
        if (value == 0) {
            _removeFrom(_modVoters[target], _modVoterIdx[target], author);
        } else if (_modVoterIdx[target][author] == 0) {
            if (_modVoters[target].length >= MAX_MOD_VOTERS) return TooManyVoters.selector;
            _modVoters[target].push(author);
            _modVoterIdx[target][author] = _modVoters[target].length;
        }
        modVote[target][author] = value;

        if (role[author] >= ROLE_MODERATOR) {
            bool flagged = value == 1;
            if (flagged != modFlag[target][author]) {
                modFlag[target][author] = flagged;
                if (flagged) ++flagCount[target];
                else --flagCount[target];
            }
        }
        return bytes4(0);
    }

    function _rateNote(address author, bytes32 note, int8 value) private returns (bytes4) {
        if (value < -1 || value > 1) return InvalidValue.selector;
        int8 prev = noteRating[note][author];
        if (prev == value) return bytes4(0);
        if (prev == 1) --helpfulCount[note];
        else if (prev == -1) --notHelpfulCount[note];
        else if (!_noteRated[note][author]) {
            _noteRated[note][author] = true;
            _noteRaters[note].push(author);
        }
        if (value == 1) ++helpfulCount[note];
        else if (value == -1) ++notHelpfulCount[note];
        noteRating[note][author] = value;
        return bytes4(0);
    }

    function _roleAction(address author, address target, int8 value) private returns (bytes4) {
        if (role[author] != ROLE_ADMIN) return NotAuthorized.selector;
        if (value < 0 || value > int8(ROLE_ADMIN) || target == address(0)) return InvalidValue.selector;
        uint8 newRole = uint8(value);
        if (role[target] == ROLE_ADMIN && newRole != ROLE_ADMIN && adminCount == 1) return LastAdmin.selector;
        _setRole(target, newRole, author);
        return bytes4(0);
    }

    function _setRole(address account, uint8 newRole, address by) private {
        uint8 prev = role[account];
        if (prev == newRole) return;
        if (prev == ROLE_ADMIN) --adminCount;
        if (newRole == ROLE_ADMIN) ++adminCount;
        role[account] = newRole;
        if (prev == ROLE_USER) {
            _staff.push(account);
            _staffIdx[account] = _staff.length;
        } else if (newRole == ROLE_USER) {
            _removeFrom(_staff, _staffIdx, account);
        }
        emit RoleChanged(account, newRole, by);
    }

    function _removeFrom(address[] storage list, mapping(address => uint256) storage idx, address who) private {
        uint256 i = idx[who];
        if (i == 0) return;
        uint256 last = list.length;
        if (i != last) {
            address moved = list[last - 1];
            list[i - 1] = moved;
            idx[moved] = i;
        }
        list.pop();
        delete idx[who];
    }

    function voteWeight(address account) public view returns (uint64) {
        uint256 amount;
        if (address(stake) != address(0)) (amount,) = stake.stakeOf(account);
        uint64 seen = firstSeen[account];
        uint256 age = seen == 0 ? 0 : block.timestamp - seen;
        bool staked = amount >= minStake && amount > 0;
        if (!staked && age < 30 days) return 0;
        uint256 w = 1 + Math.min(age / 30 days, 12);
        if (staked) w += Math.min(Math.sqrt(amount / stakeUnit), 50);
        return uint64(w);
    }

    function hideScore(bytes32 target) public view returns (int256 score) {
        address[] storage voters = _modVoters[target];
        for (uint256 i; i < voters.length; ++i) {
            address v = voters[i];
            score += int256(uint256(voteWeight(v))) * modVote[target][v];
        }
    }

    function modVoterCount(bytes32 target) external view returns (uint256) {
        return _modVoters[target].length;
    }

    function modVoters(bytes32 target, uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _slice(_modVoters[target], offset, limit);
    }

    function followingCount(address account) external view returns (uint256) {
        return _following[account].length;
    }

    function following(address account, uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _slice(_following[account], offset, limit);
    }

    function followers(address account, uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _slice(_followers[account], offset, limit);
    }

    function staff() external view returns (address[] memory list, uint8[] memory roles) {
        list = _staff;
        roles = new uint8[](list.length);
        for (uint256 i; i < list.length; ++i) {
            roles[i] = role[list[i]];
        }
    }

    function noteRaters(bytes32 note, uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _slice(_noteRaters[note], offset, limit);
    }

    function noteRatings(bytes32 note, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory raters, int8[] memory values)
    {
        raters = _slice(_noteRaters[note], offset, limit);
        values = new int8[](raters.length);
        for (uint256 i; i < raters.length; ++i) {
            values[i] = noteRating[note][raters[i]];
        }
    }

    function postStats(bytes32[] calldata ids, address[] calldata authors, address viewer)
        external
        view
        returns (PostStat[] memory out)
    {
        if (authors.length != ids.length) revert InvalidValue();
        out = new PostStat[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            bytes32 id = ids[i];
            int8 own = reaction[id][authors[i]];
            out[i] = PostStat(
                likeCount[id] - (own == 1 ? 1 : 0),
                dislikeCount[id] - (own == -1 ? 1 : 0),
                hideScore(id),
                flagCount[id],
                reaction[id][viewer],
                modVote[id][viewer]
            );
        }
    }

    function userStats(address[] calldata users, address viewer) external view returns (UserStat[] memory out) {
        out = new UserStat[](users.length);
        for (uint256 i; i < users.length; ++i) {
            address u = users[i];
            out[i] = UserStat(
                followerCount[u],
                _following[u].length,
                role[u],
                isFollowing[viewer][u],
                isFollowing[u][viewer],
                encKey[u],
                nonces[u],
                firstSeen[u],
                voteWeight(u)
            );
        }
    }

    function noteStats(bytes32[] calldata notes, address viewer) external view returns (NoteStat[] memory out) {
        out = new NoteStat[](notes.length);
        for (uint256 i; i < notes.length; ++i) {
            bytes32 n = notes[i];
            out[i] = NoteStat(helpfulCount[n], notHelpfulCount[n], noteRating[n][viewer]);
        }
    }

    function flagsBy(bytes32[] calldata ids, address[] calldata moderators)
        external
        view
        returns (uint256[] memory bitmaps)
    {
        bitmaps = new uint256[](ids.length);
        uint256 m = moderators.length > 256 ? 256 : moderators.length;
        for (uint256 i; i < ids.length; ++i) {
            uint256 bits;
            for (uint256 j; j < m; ++j) {
                if (modFlag[ids[i]][moderators[j]]) bits |= 1 << j;
            }
            bitmaps[i] = bits;
        }
    }

    function _slice(address[] storage list, uint256 offset, uint256 limit) private view returns (address[] memory out) {
        uint256 len = list.length;
        if (offset >= len) return out;
        uint256 n = len - offset < limit ? len - offset : limit;
        out = new address[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = list[offset + i];
        }
    }
}
