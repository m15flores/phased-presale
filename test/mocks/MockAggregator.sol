// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

import "../../src/interfaces/IAggregator.sol";

contract MockAggregator is IAggregator {
    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;
    uint8 public decimals;

    constructor(int256 answer_) {
        answer = answer_;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        decimals = 8;
    }

    function setAnswer(int256 answer_) external {
        answer = answer_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        updatedAt = updatedAt_;
    }

    function setStartedAt(uint256 startedAt_) external {
        startedAt = startedAt_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
    {
        roundId_ = roundId;
        answer_ = answer;
        startedAt_ = startedAt;
        updatedAt_ = updatedAt;
        answeredInRound_ = answeredInRound;
    }

    function setDecimals(uint8 decimals_) external {
        decimals = decimals_;
    }
}
