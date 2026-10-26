// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Upgradeable} from "./base/Upgradeable.sol";

contract Registry is Upgradeable {
    struct ChainConfig {
        uint256 chainId;
        string name;
        address content;
        address inbox;
        uint8 role;
        bool active;
        string[] rpcs;
    }

    uint8 public constant ROLE_SOCIAL = 0;
    uint8 public constant ROLE_FREE = 1;
    uint8 public constant ROLE_ANCHORED = 2;

    ChainConfig[] private _chains;
    address public social;
    address public stake;
    uint64 public version;
    uint64 public deployBlock;

    mapping(bytes32 => bytes) public params;
    bytes32[] private _paramKeys;
    mapping(bytes32 => bool) private _paramKnown;

    event ConfigChanged(uint64 version);

    error UnknownChain(uint256 index);
    error NoActiveChain();
    error InvalidRole();

    function initialize(address owner_) external initializer {
        __Upgradeable_init(owner_);
        deployBlock = uint64(block.number);
    }

    function addChain(ChainConfig calldata cfg) external onlyOwner returns (uint256 index) {
        if (cfg.role > ROLE_ANCHORED) revert InvalidRole();
        _chains.push(cfg);
        index = _chains.length - 1;
        _bump();
    }

    function updateChain(uint256 index, ChainConfig calldata cfg) external onlyOwner {
        if (index >= _chains.length) revert UnknownChain(index);
        if (cfg.role > ROLE_ANCHORED) revert InvalidRole();
        _chains[index] = cfg;
        _requireActive();
        _bump();
    }

    function setChainActive(uint256 index, bool active) external onlyOwner {
        if (index >= _chains.length) revert UnknownChain(index);
        _chains[index].active = active;
        _requireActive();
        _bump();
    }

    function setRpcs(uint256 index, string[] calldata rpcs) external onlyOwner {
        if (index >= _chains.length) revert UnknownChain(index);
        _chains[index].rpcs = rpcs;
        _bump();
    }

    function setSocial(address social_, address stake_) external onlyOwner {
        social = social_;
        stake = stake_;
        _bump();
    }

    function setParam(bytes32 key, bytes calldata value) external onlyOwner {
        _setParam(key, value);
        _bump();
    }

    function setParams(bytes32[] calldata keys, bytes[] calldata values) external onlyOwner {
        for (uint256 i; i < keys.length; ++i) {
            _setParam(keys[i], values[i]);
        }
        _bump();
    }

    function chainCount() external view returns (uint256) {
        return _chains.length;
    }

    function chain(uint256 index) external view returns (ChainConfig memory) {
        return _chains[index];
    }

    function getChains() external view returns (ChainConfig[] memory) {
        return _chains;
    }

    function getParams() public view returns (bytes32[] memory keys, bytes[] memory values) {
        keys = _paramKeys;
        values = new bytes[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            values[i] = params[keys[i]];
        }
    }

    function snapshot()
        external
        view
        returns (
            uint64 version_,
            address social_,
            address stake_,
            ChainConfig[] memory chains_,
            bytes32[] memory keys,
            bytes[] memory values
        )
    {
        (keys, values) = getParams();
        return (version, social, stake, _chains, keys, values);
    }

    function _setParam(bytes32 key, bytes calldata value) private {
        if (!_paramKnown[key]) {
            _paramKnown[key] = true;
            _paramKeys.push(key);
        }
        params[key] = value;
    }

    function _requireActive() private view {
        for (uint256 i; i < _chains.length; ++i) {
            if (_chains[i].active && _chains[i].role != ROLE_SOCIAL) return;
        }
        revert NoActiveChain();
    }

    function _bump() private {
        emit ConfigChanged(++version);
    }
}
