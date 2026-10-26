// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {Stake} from "../src/Stake.sol";

contract StakeTest is Base {
    function test_depositWithdrawCycle() public {
        vm.deal(bob, 1 ether);
        vm.startPrank(bob);
        stake.deposit{value: 1 ether}();
        (uint256 amount,) = stake.stakeOf(bob);
        assertEq(amount, 1 ether);
        stake.requestWithdraw(0.4 ether);
        vm.expectRevert();
        stake.withdraw();
        vm.warp(block.timestamp + 7 days);
        stake.withdraw();
        vm.stopPrank();
        assertEq(bob.balance, 0.4 ether);
        (amount,) = stake.stakeOf(bob);
        assertEq(amount, 0.6 ether);
        assertEq(stake.totalStaked(), 0.6 ether);
    }

    function test_depositFor() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        stake.depositFor{value: 0.5 ether}(carol);
        (uint256 amount,) = stake.stakeOf(carol);
        assertEq(amount, 0.5 ether);
    }

    function test_zeroDepositReverts() public {
        vm.expectRevert(Stake.InsufficientStake.selector);
        stake.deposit();
    }
}
