// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract Multicall3 {
    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    struct Result {
        bool success;
        bytes returnData;
    }

    function aggregate3(Call3[] calldata calls) external payable returns (Result[] memory results) {
        uint256 length = calls.length;
        results = new Result[](length);
        for (uint256 i; i < length; ++i) {
            Call3 calldata c = calls[i];
            (bool ok, bytes memory data) = c.target.call(c.callData);
            if (!ok && !c.allowFailure) {
                assembly {
                    revert(add(data, 0x20), mload(data))
                }
            }
            results[i] = Result(ok, data);
        }
    }

    function getBlockNumber() external view returns (uint256) {
        return block.number;
    }

    function getCurrentBlockTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function getEthBalance(address account) external view returns (uint256) {
        return account.balance;
    }

    function getChainId() external view returns (uint256) {
        return block.chainid;
    }
}
