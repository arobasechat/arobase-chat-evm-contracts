// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Stake is ReentrancyGuard {
    struct Position {
        uint128 amount;
        uint128 pending;
        uint64 since;
        uint64 unlockAt;
    }

    uint64 public immutable cooldown;
    uint256 public totalStaked;
    mapping(address => Position) public positions;

    event Deposited(address indexed account, address indexed from, uint256 amount);
    event WithdrawRequested(address indexed account, uint256 amount, uint64 unlockAt);
    event Withdrawn(address indexed account, uint256 amount);

    error NothingToWithdraw();
    error StillLocked(uint64 unlockAt);
    error InsufficientStake();
    error TransferFailed();

    constructor(uint64 cooldown_) {
        cooldown = cooldown_;
    }

    function deposit() external payable {
        depositFor(msg.sender);
    }

    function depositFor(address account) public payable {
        if (msg.value == 0) revert InsufficientStake();
        Position storage p = positions[account];
        if (p.amount == 0) p.since = uint64(block.timestamp);
        p.amount += uint128(msg.value);
        totalStaked += msg.value;
        emit Deposited(account, msg.sender, msg.value);
    }

    function requestWithdraw(uint256 amount) external {
        Position storage p = positions[msg.sender];
        if (amount == 0 || amount > p.amount) revert InsufficientStake();
        p.amount -= uint128(amount);
        p.pending += uint128(amount);
        p.unlockAt = uint64(block.timestamp) + cooldown;
        totalStaked -= amount;
        if (p.amount == 0) p.since = 0;
        emit WithdrawRequested(msg.sender, amount, p.unlockAt);
    }

    function withdraw() external nonReentrant {
        Position storage p = positions[msg.sender];
        uint256 amount = p.pending;
        if (amount == 0) revert NothingToWithdraw();
        if (block.timestamp < p.unlockAt) revert StillLocked(p.unlockAt);
        p.pending = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(msg.sender, amount);
    }

    function stakeOf(address account) external view returns (uint256 amount, uint64 since) {
        Position storage p = positions[account];
        return (p.amount, p.since);
    }
}
