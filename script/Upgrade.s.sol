// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

contract Upgrade is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        string memory artifact = vm.envString("ARTIFACT");
        bytes memory args = vm.envOr("CONSTRUCTOR_ARGS", bytes(""));
        vm.startBroadcast(pk);
        address impl = deployCode(artifact, args);
        vm.stopBroadcast();
        console2.log("Implementation", impl);
        vm.writeJson(
            vm.serializeAddress("upgrade", "implementation", impl),
            string.concat("deployments/upgrade-", vm.toString(block.chainid), ".json")
        );
    }
}
