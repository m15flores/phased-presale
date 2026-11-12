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

        vm.startPrank(actor_);
        usdc.approve(address(presale), amount_);
        presale.buyWithStable(address(usdc), amount_, 0);
        vm.stopPrank();
    }

    function claim(uint256 actorSeed_) public {
        actorSeed_ = bound(actorSeed_, 0, actors.length - 1);
        address actor_ = actors[actorSeed_];
        if(block.timestamp < endingTime) vm.warp(endingTime);

        uint256 owed_ = presale.userTokenBalance(actor_);

        vm.prank(actor_);
        presale.claim();

        ghostTotalClaimed += owed_;
    }
}
