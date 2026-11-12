// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

import "forge-std/Test.sol";
import "../../src/Presale.sol";
import "../mocks/MockERC20.sol";

contract PresaleHandler is Test {
    Presale public immutable presale;
    MockERC20 public immutable usdc;
    uint256 public immutable startingTime;
    uint256 public immutable endingTime;
    address[] public actors;

    uint256 public ghostTotalClaimed;
    uint256 public ghostTotalBought;
    uint256 public maxPhaseSeen;
    bool public phaseDecreased;

    constructor(Presale presale_, MockERC20 usdc_, uint256 startingTime_, uint256 endingTime_) {
        presale = presale_;
        usdc = usdc_;
        startingTime = startingTime_;
        endingTime = endingTime_;

        for (uint8 i = 0; i < 5; i++) {
            actors.push(address(uint160(1_000 + i)));
        }
    }

    function buyWithStable(uint256 actorSeed_, uint256 amount_) public {
        actorSeed_ = bound(actorSeed_, 0, actors.length - 1);
        amount_ = bound(amount_, 1, 10_000e6);
        address actor_ = actors[actorSeed_];
        usdc.mint(actor_, amount_);
        if (block.timestamp < startingTime) vm.warp(startingTime);
        uint256 userTokenBalanceBefore_ = presale.userTokenBalance(actor_);

        vm.startPrank(actor_);
        usdc.approve(address(presale), amount_);
        presale.buyWithStable(address(usdc), amount_, 0);
        vm.stopPrank();

        uint256 userTokenBalanceAfter_ = presale.userTokenBalance(actor_);
        ghostTotalBought += userTokenBalanceAfter_ - userTokenBalanceBefore_;
        _trackPhase();
    }

    function claim(uint256 actorSeed_) public {
        actorSeed_ = bound(actorSeed_, 0, actors.length - 1);
        address actor_ = actors[actorSeed_];
        if (block.timestamp < endingTime) vm.warp(endingTime);

        uint256 owed_ = presale.userTokenBalance(actor_);

        vm.prank(actor_);
        presale.claim();

        ghostTotalClaimed += owed_;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function warp(uint256 seconds_) public {
        seconds_ = bound(seconds_, 1, 5 days);
        vm.warp(block.timestamp + seconds_);
    }

    function _trackPhase() internal {
        uint256 phase_ = presale.currentPhase();
        if (phase_ < maxPhaseSeen) phaseDecreased = true;
        else maxPhaseSeen = phase_;
    }
}
