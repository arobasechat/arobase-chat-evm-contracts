// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {Registry} from "../src/Registry.sol";
import {Social} from "../src/Social.sol";
import {Stake} from "../src/Stake.sol";
import {Names} from "../src/Names.sol";
import {PushRelays} from "../src/PushRelays.sol";
import {Media} from "../src/Media.sol";
import {Vault, ISessionRegistry} from "../src/Vault.sol";
import {Content} from "../src/Content.sol";
import {Inbox} from "../src/Inbox.sol";
import {Paymaster} from "../src/Paymaster.sol";
import {Sessions} from "../src/base/Sessions.sol";

contract Deploy is Script {
    address internal constant ENTRYPOINT_V08 = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;
    address internal constant SIMPLE_7702_V08 = 0xe6Cae83BdE06E4c305530e199D7217f42808555B;
    string internal constant KEY = "deployment";

    address internal deployer;
    TimelockController internal timelock;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        deployer = vm.addr(pk);
        bool social = keccak256(bytes(vm.envString("ROLE"))) == keccak256("social");

        vm.startBroadcast(pk);
        timelock = _timelock();
        vm.serializeUint(KEY, "chainId", block.chainid);
        vm.serializeUint(KEY, "deployBlock", block.number);
        vm.serializeAddress(KEY, "timelock", address(timelock));
        address[] memory targets;
        bytes4[][] memory selectors;
        (targets, selectors) = social ? _social() : _content();
        if (vm.envOr("SPONSOR", false)) _paymaster(targets, selectors);
        vm.stopBroadcast();

        string memory json = vm.serializeString(KEY, "role", social ? "social" : "content");
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }

    function _timelock() private returns (TimelockController) {
        address[] memory proposers = new address[](1);
        proposers[0] = vm.envOr("TIMELOCK_PROPOSER", deployer);
        address[] memory executors = new address[](1);
        return new TimelockController(vm.envOr("TIMELOCK_DELAY", uint256(0)), proposers, executors, address(0));
    }

    function _proxy(string memory name, address impl, bytes memory init) private returns (address proxy) {
        proxy = address(new ERC1967Proxy(impl, init));
        vm.serializeAddress(KEY, name, proxy);
        console2.log(name, proxy);
    }

    function _social() private returns (address[] memory targets, bytes4[][] memory selectors) {
        address owner = address(timelock);
        Stake stake = new Stake(uint64(vm.envOr("STAKE_COOLDOWN", uint256(7 days))));
        vm.serializeAddress(KEY, "stake", address(stake));

        address[] memory admins = vm.envOr("INITIAL_ADMINS", ",", new address[](0));
        if (admins.length == 0) {
            admins = new address[](1);
            admins[0] = deployer;
        }
        address social = _proxy(
            "social",
            address(new Social()),
            abi.encodeCall(
                Social.initialize,
                (
                    owner,
                    stake,
                    vm.envOr("MIN_STAKE", uint256(0.01 ether)),
                    vm.envOr("STAKE_UNIT", uint256(0.01 ether)),
                    admins
                )
            )
        );
        Registry registry =
            Registry(_proxy("registry", address(new Registry()), abi.encodeCall(Registry.initialize, (deployer))));
        registry.setSocial(social, address(stake));
        address names = _proxy("names", address(new Names()), abi.encodeCall(Names.initialize, (owner)));
        address push = _proxy("pushRelays", address(new PushRelays()), abi.encodeCall(PushRelays.initialize, (owner)));
        address media = _proxy("media", address(new Media()), abi.encodeCall(Media.initialize, (owner)));
        address vault = _proxy("vault", address(new Vault()), abi.encodeCall(Vault.initialize, (owner, ISessionRegistry(social))));

        targets = new address[](5);
        selectors = new bytes4[][](5);
        targets[0] = social;
        selectors[0] = _three(Social.submit.selector, Social.submitBatch.selector, Sessions.revoke.selector);
        targets[1] = names;
        selectors[1] = _one(Names.claim.selector);
        targets[2] = push;
        selectors[2] = _one(PushRelays.subscribe.selector);
        targets[3] = media;
        selectors[3] = _one(Media.store.selector);
        targets[4] = vault;
        selectors[4] = _one(Vault.save.selector);
    }

    function _content() private returns (address[] memory targets, bytes4[][] memory selectors) {
        address owner = address(timelock);
        address content = _proxy(
            "content",
            address(new Content()),
            abi.encodeCall(Content.initialize, (owner, vm.envOr("INDEXING", true)))
        );
        address inbox = _proxy("inbox", address(new Inbox()), abi.encodeCall(Inbox.initialize, (owner)));

        targets = new address[](2);
        selectors = new bytes4[][](2);
        targets[0] = content;
        selectors[0] = _pair(Content.publish.selector, Sessions.revoke.selector);
        targets[1] = inbox;
        selectors[1] = _pair(Inbox.invite.selector, Inbox.send.selector);
    }

    function _paymaster(address[] memory targets, bytes4[][] memory selectors) private {
        IEntryPoint ep = IEntryPoint(vm.envOr("ENTRYPOINT", ENTRYPOINT_V08));
        Paymaster paymaster = Paymaster(
            _proxy(
                "paymaster",
                address(new Paymaster(ep)),
                abi.encodeCall(
                    Paymaster.initialize,
                    (
                        deployer,
                        uint8(vm.envOr("POW_DIFFICULTY", uint256(16))),
                        vm.envOr("MAX_COST_PER_OP", uint256(0.05 ether)),
                        vm.envOr("DAILY_BUDGET", uint256(0)),
                        uint32(vm.envOr("PER_SENDER_DAILY", uint256(0))),
                        vm.envOr("ACCOUNT_IMPL", SIMPLE_7702_V08),
                        _limits()
                    )
                )
            )
        );
        for (uint256 i; i < targets.length; ++i) {
            paymaster.setTarget(targets[i], selectors[i], true);
        }
        if (!vm.envOr("SKIP_FUNDING", false)) {
            paymaster.addStake{value: vm.envOr("PAYMASTER_STAKE", uint256(1 ether))}(
                uint32(vm.envOr("PAYMASTER_UNSTAKE_DELAY", uint256(1 days)))
            );
            uint256 deposit = vm.envOr("PAYMASTER_DEPOSIT", uint256(0));
            if (deposit > 0) paymaster.deposit{value: deposit}();
        }
        paymaster.transferOwnership(address(timelock));
        vm.serializeAddress(KEY, "entryPoint", address(ep));
    }

    function _limits() private view returns (Paymaster.Limits memory) {
        return Paymaster.Limits({
            preVerificationGas: uint32(vm.envOr("LIMIT_PRE_VERIFICATION_GAS", uint256(150_000))),
            preVerificationGasPerByte: uint32(vm.envOr("LIMIT_PRE_VERIFICATION_GAS_PER_BYTE", uint256(48))),
            priorityFee: uint96(vm.envOr("LIMIT_PRIORITY_FEE", uint256(2 gwei)))
        });
    }

    function _one(bytes4 a) private pure returns (bytes4[] memory out) {
        out = new bytes4[](1);
        out[0] = a;
    }

    function _three(bytes4 a, bytes4 b, bytes4 c) private pure returns (bytes4[] memory out) {
        out = new bytes4[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _pair(bytes4 a, bytes4 b) private pure returns (bytes4[] memory out) {
        out = new bytes4[](2);
        out[0] = a;
        out[1] = b;
    }
}
