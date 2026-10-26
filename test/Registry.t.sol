// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {Registry} from "../src/Registry.sol";
import {Upgradeable} from "../src/base/Upgradeable.sol";

contract RegistryTest is Base {
    function _cfg(uint8 role_, bool active) internal view returns (Registry.ChainConfig memory c) {
        string[] memory rpcs = new string[](2);
        rpcs[0] = "https://rpc-a";
        rpcs[1] = "https://rpc-b";
        c = Registry.ChainConfig(1, "Chain", address(content), address(inbox), role_, active, rpcs);
    }

    function test_onlyOwner() public {
        Registry.ChainConfig memory c = _cfg(1, true);
        vm.expectRevert(Upgradeable.NotOwner.selector);
        registry.addChain(c);
    }

    function test_versionBumpsAndSnapshot() public {
        vm.startPrank(gov);
        registry.addChain(_cfg(0, true));
        registry.addChain(_cfg(1, true));
        registry.setSocial(address(social), address(stake));
        registry.setParam("hideThreshold", abi.encode(uint256(10)));
        vm.stopPrank();
        (uint64 version, address s,, Registry.ChainConfig[] memory chains, bytes32[] memory keys,) =
            registry.snapshot();
        assertEq(version, 4);
        assertEq(s, address(social));
        assertEq(chains.length, 2);
        assertEq(chains[1].rpcs.length, 2);
        assertEq(keys.length, 1);
    }

    function test_refusesToDisableAllContentChains() public {
        vm.startPrank(gov);
        registry.addChain(_cfg(0, true));
        registry.addChain(_cfg(1, true));
        vm.expectRevert(Registry.NoActiveChain.selector);
        registry.setChainActive(1, false);
        vm.stopPrank();
    }

    function test_setParamsBatch() public {
        bytes32[] memory keys = new bytes32[](2);
        bytes[] memory values = new bytes[](2);
        keys[0] = "a";
        keys[1] = "b";
        values[0] = "1";
        values[1] = "2";
        vm.prank(gov);
        registry.setParams(keys, values);
        assertEq(registry.params("b"), bytes("2"));
        assertEq(registry.version(), 1);
    }

    function test_cannotReinitialize() public {
        vm.expectRevert();
        registry.initialize(address(this));
    }
}
