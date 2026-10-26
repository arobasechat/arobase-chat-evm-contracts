// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Upgradeable} from "./base/Upgradeable.sol";

contract PushRelays is Upgradeable {
    uint256 public constant MAX_SUBSCRIPTION = 8192;
    uint256 public constant VAPID_LENGTH = 65;

    struct Relay {
        address operator;
        bool active;
        bytes32 encKey;
        bytes vapid;
        string name;
        string info;
    }

    Relay[] private _relays;

    event RelayChanged(uint256 indexed id, address indexed operator, bool active);
    event Subscribed(uint256 indexed relayId, bytes ciphertext);

    error NotOperator();
    error UnknownRelay();
    error InactiveRelay();
    error BadKey();
    error TooLarge();

    function initialize(address owner_) external initializer {
        __Upgradeable_init(owner_);
    }

    modifier onlyOperator(uint256 id) {
        if (id >= _relays.length) revert UnknownRelay();
        if (_relays[id].operator != msg.sender) revert NotOperator();
        _;
    }

    function register(string calldata name, string calldata info, bytes32 encKey, bytes calldata vapid)
        external
        returns (uint256 id)
    {
        _check(encKey, vapid);
        id = _relays.length;
        _relays.push(Relay(msg.sender, true, encKey, vapid, name, info));
        emit RelayChanged(id, msg.sender, true);
    }

    function update(uint256 id, string calldata name, string calldata info, bytes32 encKey, bytes calldata vapid, bool active)
        external
        onlyOperator(id)
    {
        _check(encKey, vapid);
        Relay storage r = _relays[id];
        r.name = name;
        r.info = info;
        r.encKey = encKey;
        r.vapid = vapid;
        r.active = active;
        emit RelayChanged(id, msg.sender, active);
    }

    function transferRelay(uint256 id, address operator) external onlyOperator(id) {
        _relays[id].operator = operator;
        emit RelayChanged(id, operator, _relays[id].active);
    }

    function subscribe(uint256 relayId, bytes calldata ciphertext) external {
        if (relayId >= _relays.length) revert UnknownRelay();
        if (!_relays[relayId].active) revert InactiveRelay();
        if (ciphertext.length > MAX_SUBSCRIPTION) revert TooLarge();
        emit Subscribed(relayId, ciphertext);
    }

    function count() external view returns (uint256) {
        return _relays.length;
    }

    function get(uint256 id) external view returns (Relay memory) {
        if (id >= _relays.length) revert UnknownRelay();
        return _relays[id];
    }

    function all() external view returns (Relay[] memory) {
        return _relays;
    }

    function _check(bytes32 encKey, bytes calldata vapid) private pure {
        if (encKey == bytes32(0) || vapid.length != VAPID_LENGTH || vapid[0] != 0x04) revert BadKey();
    }
}
