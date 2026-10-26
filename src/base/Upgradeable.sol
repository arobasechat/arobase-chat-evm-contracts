// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

abstract contract Upgradeable is Initializable, UUPSUpgradeable {
    bytes32 private constant OWNER_SLOT = 0x2c133d591570595739aea9e848d9686b7f2b7e4902cbc5e6b4994f4835f91000;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error ZeroOwner();

    modifier onlyOwner() {
        if (msg.sender != owner()) revert NotOwner();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function owner() public view returns (address o) {
        bytes32 slot = OWNER_SLOT;
        assembly {
            o := sload(slot)
        }
    }

    function transferOwnership(address next) external onlyOwner {
        if (next == address(0)) revert ZeroOwner();
        _setOwner(next);
    }

    function implementation() external view returns (address) {
        return _implementationAddress();
    }

    function __Upgradeable_init(address owner_) internal onlyInitializing {
        if (owner_ == address(0)) revert ZeroOwner();
        _setOwner(owner_);
    }

    function _setOwner(address next) private {
        address prev = owner();
        bytes32 slot = OWNER_SLOT;
        assembly {
            sstore(slot, next)
        }
        emit OwnershipTransferred(prev, next);
    }

    function _implementationAddress() private view returns (address impl) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assembly {
            impl := sload(slot)
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
