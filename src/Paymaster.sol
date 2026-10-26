// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPaymaster} from "account-abstraction/interfaces/IPaymaster.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";
import {UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {_packValidationData} from "account-abstraction/core/Helpers.sol";
import {Upgradeable} from "./base/Upgradeable.sol";

contract Paymaster is IPaymaster, Upgradeable {
    using UserOperationLib for PackedUserOperation;

    struct Limits {
        uint32 preVerificationGas;
        uint32 preVerificationGasPerByte;
        uint96 priorityFee;
    }

    uint256 internal constant SIG_VALIDATION_FAILED = 1;
    uint256 internal constant PAYMASTER_DATA_OFFSET = UserOperationLib.PAYMASTER_DATA_OFFSET;
    bytes2 internal constant EIP7702_MARKER = 0x7702;

    IEntryPoint public immutable entryPoint;

    mapping(address => mapping(bytes4 => bool)) public allowed;
    uint8 public difficulty;
    uint256 public maxCostPerOp;
    uint256 public dailyBudget;
    uint32 public perSenderDaily;
    uint32 public currentDay;
    uint256 public spentToday;
    mapping(address => uint64) private _usage;
    address public account;
    Limits public limits;

    event TargetSet(address indexed target, bytes4 indexed selector, bool allowed);
    event DifficultySet(uint8 difficulty);
    event MaxCostSet(uint256 maxCost);
    event QuotaSet(uint256 dailyBudget, uint32 perSenderDaily);
    event AccountSet(address account);
    event LimitsSet(Limits limits);

    error InvalidDifficulty();
    error NotEntryPoint();

    constructor(IEntryPoint entryPoint_) {
        entryPoint = entryPoint_;
    }

    function initialize(
        address owner_,
        uint8 difficulty_,
        uint256 maxCostPerOp_,
        uint256 dailyBudget_,
        uint32 perSenderDaily_,
        address account_,
        Limits calldata limits_
    ) external initializer {
        __Upgradeable_init(owner_);
        if (difficulty_ > 32) revert InvalidDifficulty();
        difficulty = difficulty_;
        maxCostPerOp = maxCostPerOp_;
        dailyBudget = dailyBudget_;
        perSenderDaily = perSenderDaily_;
        account = account_;
        limits = limits_;
    }

    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) revert NotEntryPoint();
        _;
    }

    function setTarget(address target, bytes4[] calldata selectors, bool isAllowed) external onlyOwner {
        for (uint256 i; i < selectors.length; ++i) {
            allowed[target][selectors[i]] = isAllowed;
            emit TargetSet(target, selectors[i], isAllowed);
        }
    }

    function setDifficulty(uint8 difficulty_) external onlyOwner {
        if (difficulty_ > 32) revert InvalidDifficulty();
        difficulty = difficulty_;
        emit DifficultySet(difficulty_);
    }

    function setMaxCost(uint256 maxCost_) external onlyOwner {
        maxCostPerOp = maxCost_;
        emit MaxCostSet(maxCost_);
    }

    function setQuota(uint256 dailyBudget_, uint32 perSenderDaily_) external onlyOwner {
        dailyBudget = dailyBudget_;
        perSenderDaily = perSenderDaily_;
        emit QuotaSet(dailyBudget_, perSenderDaily_);
    }

    function setAccount(address account_) external onlyOwner {
        account = account_;
        emit AccountSet(account_);
    }

    function setLimits(Limits calldata limits_) external onlyOwner {
        limits = limits_;
        emit LimitsSet(limits_);
    }

    function isStandardAccount(address sender) public view returns (bool) {
        bytes memory code = sender.code;
        if (code.length != 23 || code[0] != 0xef || code[1] != 0x01 || code[2] != 0x00) return false;
        address delegate;
        assembly {
            delegate := shr(96, mload(add(code, 35)))
        }
        return delegate == account;
    }

    function withinLimits(PackedUserOperation calldata userOp) public view returns (bool) {
        Limits memory l = limits;
        uint256 size = userOp.callData.length + userOp.paymasterAndData.length + userOp.signature.length
            + userOp.initCode.length;
        return userOp.preVerificationGas <= uint256(l.preVerificationGas) + size * l.preVerificationGasPerByte
            && userOp.unpackMaxPriorityFeePerGas() <= l.priorityFee;
    }

    function deposit() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    function withdrawTo(address payable to, uint256 amount) external onlyOwner {
        entryPoint.withdrawTo(to, amount);
    }

    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    function unlockStake() external onlyOwner {
        entryPoint.unlockStake();
    }

    function withdrawStake(address payable to) external onlyOwner {
        entryPoint.withdrawStake(to);
    }

    function getDeposit() external view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    function usageOf(address sender) public view returns (uint32 ops) {
        uint64 u = _usage[sender];
        return uint32(u >> 32) == currentDay ? uint32(u) : 0;
    }

    function remainingToday() external view returns (uint256) {
        if (dailyBudget == 0) return type(uint256).max;
        uint256 spent = uint32(block.timestamp / 1 days) == currentDay ? spentToday : 0;
        return spent >= dailyBudget ? 0 : dailyBudget - spent;
    }

    function powHash(address sender, uint256 nonce, bytes32 callDataHash, uint256 powNonce)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), sender, nonce, callDataHash, powNonce));
    }

    function isSponsored(bytes calldata callData) public view returns (bool) {
        uint256 size = callData.length;
        if (size < 4 + 32 * 3 || bytes4(callData[:4]) != BaseAccount.execute.selector) return false;
        uint256 word = uint256(bytes32(callData[4:36]));
        if (word >> 160 != 0 || uint256(bytes32(callData[36:68])) != 0) return false;
        uint256 offset = uint256(bytes32(callData[68:100]));
        if (offset > size || size - offset < 4 + 32 + 4) return false;
        uint256 start = 4 + offset;
        uint256 len = uint256(bytes32(callData[start:start + 32]));
        if (len < 4 || len > size - start - 32) return false;
        return allowed[address(uint160(word))][bytes4(callData[start + 32:start + 36])];
    }

    function validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32, uint256 maxCost)
        external
        view
        onlyEntryPoint
        returns (bytes memory context, uint256 validationData)
    {
        if (maxCost > maxCostPerOp) return ("", SIG_VALIDATION_FAILED);
        bytes calldata initCode = userOp.initCode;
        if (initCode.length != 0 && (initCode.length > 20 || bytes2(initCode[:2]) != EIP7702_MARKER)) {
            return ("", SIG_VALIDATION_FAILED);
        }
        if (!isSponsored(userOp.callData)) return ("", SIG_VALIDATION_FAILED);
        if (!isStandardAccount(userOp.sender) || !withinLimits(userOp)) return ("", SIG_VALIDATION_FAILED);
        bytes calldata data = userOp.paymasterAndData[PAYMASTER_DATA_OFFSET:];
        if (data.length != 32) return ("", SIG_VALIDATION_FAILED);
        uint256 h = uint256(powHash(userOp.sender, userOp.nonce, keccak256(userOp.callData), uint256(bytes32(data))));
        if (h > type(uint256).max >> difficulty) return ("", SIG_VALIDATION_FAILED);
        bool over = (dailyBudget != 0 && spentToday + maxCost > dailyBudget)
            || (perSenderDaily != 0 && usageOf(userOp.sender) >= perSenderDaily);
        uint48 validAfter = over ? uint48((uint256(currentDay) + 1) * 1 days) : 0;
        return (abi.encode(userOp.sender), _packValidationData(false, 0, validAfter));
    }

    function postOp(PostOpMode, bytes calldata context, uint256 actualGasCost, uint256) external onlyEntryPoint {
        if (context.length != 32) return;
        uint32 day = uint32(block.timestamp / 1 days);
        if (day != currentDay) {
            currentDay = day;
            spentToday = 0;
        }
        spentToday += actualGasCost;
        address sender = abi.decode(context, (address));
        _usage[sender] = (uint64(day) << 32) | (usageOf(sender) + 1);
    }
}
