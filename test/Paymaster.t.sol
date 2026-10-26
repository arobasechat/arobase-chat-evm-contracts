// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {Content} from "../src/Content.sol";
import {Social} from "../src/Social.sol";
import {Paymaster} from "../src/Paymaster.sol";
import {Upgradeable} from "../src/base/Upgradeable.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {IPaymaster} from "account-abstraction/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";
import {Simple7702Account} from "account-abstraction/accounts/Simple7702Account.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {Media} from "../src/Media.sol";

contract PaymasterTest is Base {
    address internal constant ENTRYPOINT = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;
    IEntryPoint internal ep = IEntryPoint(ENTRYPOINT);
    Paymaster internal paymaster;
    address payable internal beneficiary = payable(makeAddr("bundler"));
    address internal accountImpl;

    function _defaultLimits() internal pure returns (Paymaster.Limits memory) {
        return Paymaster.Limits({
            preVerificationGas: 150_000,
            preVerificationGasPerByte: 48,
            priorityFee: 2 gwei
        });
    }

    function setUp() public override {
        super.setUp();
        deployCodeTo("EntryPoint.sol:EntryPoint", ENTRYPOINT);
        accountImpl = address(new Simple7702Account());
        paymaster = Paymaster(
            _proxy(
                address(new Paymaster(ep)),
                abi.encodeCall(Paymaster.initialize, (address(this), 8, 1 ether, 0, 0, accountImpl, _defaultLimits()))
            )
        );
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = Content.publish.selector;
        paymaster.setTarget(address(content), sel, true);
        sel[0] = Social.submitBatch.selector;
        paymaster.setTarget(address(social), sel, true);
        paymaster.deposit{value: 10 ether}();
        paymaster.addStake{value: 1 ether}(1 days);
        vm.signAndAttachDelegation(accountImpl, sessionPk);
    }

    function _publishCall(bytes memory payload) internal view returns (bytes memory) {
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(alicePk, _messageHash(alice, 0, bytes32(0), ts, payload));
        return abi.encodeCall(Content.publish, (alice, 0, bytes32(0), ts, payload, sig));
    }

    function _mine(bytes memory callData, uint256 nonce, uint8 bits) internal view returns (uint256 pow) {
        bytes32 h = keccak256(callData);
        while (uint256(paymaster.powHash(sessionKey, nonce, h, pow)) > type(uint256).max >> bits) ++pow;
    }

    function _op(address target, bytes memory inner, bool validPow) internal view returns (PackedUserOperation memory op) {
        bytes memory callData = abi.encodeCall(BaseAccount.execute, (target, 0, inner));
        uint256 nonce = ep.getNonce(sessionKey, 0);
        uint256 pow = _mine(callData, nonce, 8);
        if (!validPow) {
            while (uint256(paymaster.powHash(sessionKey, nonce, keccak256(callData), pow)) <= type(uint256).max >> 8) ++pow;
        }
        op = PackedUserOperation({
            sender: sessionKey,
            nonce: nonce,
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32((uint256(300_000) << 128) | 600_000),
            preVerificationGas: 60_000,
            gasFees: bytes32((uint256(1 gwei) << 128) | 2 gwei),
            paymasterAndData: abi.encodePacked(address(paymaster), uint128(100_000), uint128(120_000), bytes32(pow)),
            signature: ""
        });
        op.signature = _sign(sessionPk, ep.getUserOpHash(op));
    }

    function _handle(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        ep.handleOps(ops, beneficiary);
    }

    function test_sponsoredPublishFromZeroBalanceAccount() public {
        assertEq(sessionKey.balance, 0);
        uint256 depositBefore = paymaster.getDeposit();
        _handle(_op(address(content), _publishCall(bytes("sponsored")), true));
        assertEq(content.count(), 1);
        (bytes32[] memory latestIds,,) = content.page(0, bytes32(0), type(uint256).max, 1);
        bytes32 id = latestIds[0];
        (address author,,,,) = content.posts(id);
        assertEq(author, alice);
        assertLt(paymaster.getDeposit(), depositBefore);
        assertEq(sessionKey.balance, 0);
    }

    function test_sponsoredSocialBatch() public {
        bytes32 postId = keccak256("p");
        Social.Action[] memory batch = new Social.Action[](1);
        batch[0] = _action(bobPk, 10, postId, 1);
        _handle(_op(address(social), abi.encodeCall(Social.submitBatch, (batch)), true));
        assertEq(social.likeCount(postId), 1);
    }

    function test_rejectsBadPow() public {
        PackedUserOperation memory op = _op(address(content), _publishCall(bytes("x")), false);
        vm.expectRevert();
        _handle(op);
    }

    function test_rejectsUnlistedTarget() public {
        bytes memory inner = abi.encodeWithSignature("transfer(address,uint256)", bob, 1);
        PackedUserOperation memory op = _op(address(content), inner, true);
        vm.expectRevert();
        _handle(op);
    }

    function test_rejectsValueTransfer() public {
        bytes memory callData = abi.encodeCall(BaseAccount.execute, (address(content), 1, _publishCall(bytes("v"))));
        assertFalse(paymaster.isSponsored(callData));
    }

    function test_rejectsOverMaxCost() public {
        paymaster.setMaxCost(1);
        PackedUserOperation memory op = _op(address(content), _publishCall(bytes("x")), true);
        vm.expectRevert();
        _handle(op);
    }

    function test_onlyOwnerConfigures() public {
        vm.prank(bob);
        vm.expectRevert();
        paymaster.setDifficulty(4);
    }

    function test_anyoneCanFund() public {
        vm.deal(bob, 1 ether);
        uint256 before = paymaster.getDeposit();
        vm.prank(bob);
        ep.depositTo{value: 1 ether}(address(paymaster));
        assertEq(paymaster.getDeposit(), before + 1 ether);
    }

    function test_perSenderDailyQuota() public {
        vm.warp(10 days + 1);
        paymaster.setQuota(0, 2);
        _handle(_op(address(content), _publishCall(bytes("q1")), true));
        vm.warp(block.timestamp + 1);
        _handle(_op(address(content), _publishCall(bytes("q2")), true));
        assertEq(paymaster.usageOf(sessionKey), 2);
        vm.warp(block.timestamp + 1);
        PackedUserOperation memory op = _op(address(content), _publishCall(bytes("q3")), true);
        vm.expectRevert();
        _handle(op);
        vm.warp(block.timestamp + 1 days);
        _handle(_op(address(content), _publishCall(bytes("q3")), true));
        assertEq(paymaster.usageOf(sessionKey), 1);
        assertEq(content.count(), 3);
    }

    function test_upgradeKeepsStateAndAddress() public {
        paymaster.setQuota(0, 7);
        _handle(_op(address(content), _publishCall(bytes("before")), true));
        uint256 depositBefore = paymaster.getDeposit();
        address proxy = address(paymaster);
        address next = address(new Paymaster(ep));
        vm.prank(bob);
        vm.expectRevert(Upgradeable.NotOwner.selector);
        paymaster.upgradeToAndCall(next, "");
        paymaster.upgradeToAndCall(next, "");
        assertEq(paymaster.implementation(), next);
        assertEq(address(paymaster), proxy);
        assertEq(paymaster.perSenderDaily(), 7);
        assertEq(paymaster.usageOf(sessionKey), 1);
        assertEq(paymaster.getDeposit(), depositBefore);
        assertTrue(paymaster.allowed(address(content), Content.publish.selector));
        _handle(_op(address(content), _publishCall(bytes("after")), true));
        assertEq(content.count(), 2);
    }

    function test_implementationCannotBeInitialized() public {
        Paymaster impl = new Paymaster(ep);
        vm.expectRevert();
        impl.initialize(address(this), 8, 1 ether, 0, 0, accountImpl, _defaultLimits());
    }

    function test_dailyBudget() public {
        vm.warp(10 days + 1);
        paymaster.setQuota(100 ether, 0);
        _handle(_op(address(content), _publishCall(bytes("b0")), true));
        assertEq(paymaster.currentDay(), 10);
        paymaster.setQuota(1, 0);
        vm.warp(block.timestamp + 1);
        PackedUserOperation memory op = _op(address(content), _publishCall(bytes("b1")), true);
        vm.expectRevert();
        _handle(op);
        paymaster.setQuota(100 ether, 0);
        _handle(_op(address(content), _publishCall(bytes("b1")), true));
        assertGt(paymaster.spentToday(), 0);
        assertLt(paymaster.remainingToday(), 100 ether);
    }

    function _resign(PackedUserOperation memory op) internal view returns (PackedUserOperation memory) {
        op.signature = _sign(sessionPk, ep.getUserOpHash(op));
        return op;
    }

    function test_rejectsInflatedFeesAndGas() public {
        PackedUserOperation memory op = _op(address(content), _publishCall(bytes("p")), true);
        op.gasFees = bytes32((uint256(10 gwei) << 128) | 10 gwei);
        assertFalse(paymaster.withinLimits(_resign(op)));

        op = _op(address(content), _publishCall(bytes("p")), true);
        op.preVerificationGas = 3_800_000;
        assertFalse(paymaster.withinLimits(_resign(op)));
        vm.expectRevert();
        _handle(op);

        op = _op(address(content), _publishCall(bytes("p")), true);
        op.accountGasLimits = bytes32((uint256(300_000) << 128) | 30_000_000);
        assertTrue(paymaster.withinLimits(_resign(op)));
        paymaster.setMaxCost(0.01 ether);
        vm.expectRevert();
        _handle(op);
    }

    function test_preVerificationGasScalesWithCalldata() public {
        PackedUserOperation memory op = _op(address(content), _publishCall(new bytes(8000)), true);
        op.preVerificationGas = 150_000 + 8000 * 40;
        assertTrue(paymaster.withinLimits(op));
    }

    function test_bundlerCannotDrainBudgetWithInflatedFees() public {
        paymaster.setMaxCost(0.05 ether);
        paymaster.setQuota(0.5 ether, 300);
        vm.warp(20 days);
        uint256 rejected;
        for (uint256 k; k < 10; ++k) {
            PackedUserOperation memory op = _op(address(content), _publishCall(abi.encodePacked("x", k)), true);
            op.preVerificationGas = 3_800_000;
            op.gasFees = bytes32((uint256(10 gwei) << 128) | 10 gwei);
            _resign(op);
            vm.txGasPrice(1);
            try this.handleExternal(op) {} catch { ++rejected; }
        }
        assertEq(rejected, 10);
        assertEq(beneficiary.balance, 0);
        assertEq(paymaster.remainingToday(), 0.5 ether);
    }

    function handleExternal(PackedUserOperation memory op) external {
        _handle(op);
    }

    function test_postOpToleratesFailedValidationDuringEstimation() public {
        vm.prank(ENTRYPOINT);
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, "", 1 ether, 0);
        assertEq(paymaster.spentToday(), 0);
    }

    function test_validationFitsTheAppGasFormulaForTheLargestImage() public {
        Media media = Media(_proxy(address(new Media()), abi.encodeCall(Media.initialize, (gov))));
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = Media.store.selector;
        paymaster.setTarget(address(media), sel, true);
        bytes memory data = new bytes(media.MAX_SIZE());
        PackedUserOperation memory op = _op(address(media), abi.encodeCall(Media.store, ("image/jpeg", data)), true);
        op.preVerificationGas = 150_000 + op.callData.length * 40;
        op.signature = _sign(sessionPk, ep.getUserOpHash(op));
        bytes memory call = abi.encodeCall(paymaster.validatePaymasterUserOp, (op, bytes32(0), 0.1 ether));
        vm.prank(ENTRYPOINT);
        uint256 words = (op.callData.length + 31) / 32;
        (bool ok, bytes memory ret) = address(paymaster).call{gas: 80_000 + words * 12 + words * words / 256}(call);
        assertTrue(ok);
        (, uint256 validation) = abi.decode(ret, (bytes, uint256));
        assertEq(validation, 0);
    }

    function test_rejectsMalformedExecuteCalldata() public view {
        bytes memory good = abi.encodeCall(BaseAccount.execute, (address(content), 0, abi.encodePacked(Content.publish.selector)));
        assertTrue(paymaster.isSponsored(good));
        bytes memory badOffset = abi.encodePacked(BaseAccount.execute.selector, bytes32(uint256(uint160(address(content)))), bytes32(0), bytes32(uint256(1 << 200)));
        assertFalse(paymaster.isSponsored(badOffset));
        bytes memory dirtyAddress = abi.encodePacked(BaseAccount.execute.selector, bytes32(uint256(uint160(address(content))) | (1 << 200)), bytes32(0), bytes32(uint256(96)), bytes32(uint256(4)), Content.publish.selector);
        assertFalse(paymaster.isSponsored(dirtyAddress));
        bytes memory shortData = abi.encodePacked(BaseAccount.execute.selector, bytes32(uint256(uint160(address(content)))), bytes32(0), bytes32(uint256(96)), bytes32(uint256(40)), Content.publish.selector);
        assertFalse(paymaster.isSponsored(shortData));
    }

    function test_rejectsNonStandardAccount() public {
        EvilAccount evil = new EvilAccount();
        bytes memory callData = abi.encodeCall(BaseAccount.execute, (address(content), 0, abi.encodePacked(Content.publish.selector)));
        uint256 nonce = ep.getNonce(address(evil), 0);
        uint256 pow;
        while (uint256(paymaster.powHash(address(evil), nonce, keccak256(callData), pow)) > type(uint256).max >> 8) ++pow;
        PackedUserOperation memory op = PackedUserOperation({
            sender: address(evil),
            nonce: nonce,
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32((uint256(100_000) << 128) | 1_000_000),
            preVerificationGas: 60_000,
            gasFees: bytes32((uint256(1 gwei) << 128) | 2 gwei),
            paymasterAndData: abi.encodePacked(address(paymaster), uint128(100_000), uint128(120_000), bytes32(pow)),
            signature: ""
        });
        assertFalse(paymaster.isStandardAccount(address(evil)));
        assertTrue(paymaster.isStandardAccount(sessionKey));
        vm.expectRevert();
        _handle(op);
        assertEq(evil.sink(), 0);
    }

    function test_rejectsOtherDelegate() public {
        uint256 otherPk = 0xD00D;
        vm.signAndAttachDelegation(address(new EvilAccount()), otherPk);
        assertFalse(paymaster.isStandardAccount(vm.addr(otherPk)));
        paymaster.setAccount(address(0));
        assertFalse(paymaster.isStandardAccount(sessionKey));
    }
}

contract EvilAccount {
    uint256 public sink;

    function validateUserOp(PackedUserOperation calldata, bytes32, uint256) external pure returns (uint256) {
        return 0;
    }

    function execute(address, uint256, bytes calldata) external {
        for (uint256 i; i < 2000; ++i) {
            sink = uint256(keccak256(abi.encode(sink, i)));
        }
    }
}
