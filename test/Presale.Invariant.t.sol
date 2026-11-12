// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

import "forge-std/Test.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockAggregator.sol";
import "./handlers/PresaleHandler.sol";
import "../src/Presale.sol";

contract PresaleInvariantTest is Test {
    Presale presale;
    PresaleHandler handler;
    MockERC20 saleToken;
    MockERC20 usdc;
    MockERC20 usdt;
    MockAggregator aggregator;
    address owner;
    address fundsReceiver;
    uint256 startingTime;
    uint256 endingTime;

    int256 internal constant ETH_PRICE = 3_000e8;
    uint256 internal constant MAX_PRICE_AGE = 25 hours;
    uint256 internal constant MAX_SELLING_AMOUNT = 3_000_000e18;
    uint256 internal constant START_DELAY = 1 days;
    uint256 internal constant PHASE_DURATION = 10 days;
    uint256 internal constant PHASE_0_CAP = 1_000_000e18;
    uint256 internal constant PHASE_1_CAP = 2_000_000e18;
    uint256 internal constant PHASE_2_CAP = MAX_SELLING_AMOUNT;
    uint256 internal constant PHASE_0_PRICE = 5_000;
    uint256 internal constant PHASE_1_PRICE = 10_000;
    uint256 internal constant PHASE_2_PRICE = 20_000;

    function setUp() public {
        owner = makeAddr("owner");
        fundsReceiver = makeAddr("fundsReceiver");

        aggregator = new MockAggregator(ETH_PRICE);
        saleToken = new MockERC20("Sale Token", "SALE", 18);
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        usdt = new MockERC20("Mock USDT 18 dec", "USDT18", 18);

        startingTime = block.timestamp + START_DELAY;
        endingTime = startingTime + 3 * PHASE_DURATION;
        saleToken.mint(owner, MAX_SELLING_AMOUNT);

        uint64 nonce_ = vm.getNonce(owner);
        address presaleAddress_ = vm.computeCreateAddress(owner, nonce_);
        vm.prank(owner);
        saleToken.approve(presaleAddress_, MAX_SELLING_AMOUNT);
        vm.setNonceUnsafe(owner, nonce_);
        vm.prank(owner);
        presale = Presale(
            deployCode(
                "src/Presale.sol:Presale",
                abi.encode(
                    address(saleToken),
                    address(usdt),
                    address(usdc),
                    fundsReceiver,
                    address(aggregator),
                    MAX_PRICE_AGE,
                    MAX_SELLING_AMOUNT,
                    startingTime,
                    endingTime,
                    _phases()
                )
            )
        );

        handler = new PresaleHandler(presale, usdc, aggregator, startingTime, endingTime);
        targetContract(address(handler));
    }

    function invariant_TotalSoldNeverExceedsMax() public view {
        assertLe(presale.totalSold(), presale.maxSellingAmount());
    }

    function invariant_SaleTokenBalanceCoversOwedTokens() public view {
        uint256 owed_ = presale.totalSold() - presale.totalClaimed();
        uint256 presaleSaleTokenBalance_ = saleToken.balanceOf(address(presale));
        assertGe(presaleSaleTokenBalance_, owed_);
    }

    function invariant_TotalClaimedMatchesClaimedTokens() public view {
        assertEq(presale.totalClaimed(), handler.ghostTotalClaimed());
    }

    function invariant_UserBalancesSumMatchesOwed() public view {
        uint256 sum_;
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            sum_ += presale.userTokenBalance(handler.actors(i));
        }

        assertEq(sum_, presale.totalSold() - presale.totalClaimed());
    }

    function invariant_TotalSoldMatchesBoughtTokens() public view {
        assertEq(presale.totalSold(), handler.ghostTotalBought());
    }

    function invariant_PhaseNeverDecreases() public view {
        assertFalse(handler.phaseDecreased());
    }

    function invariant_PresaleHoldsNoEth() public view {
        assertEq(address(presale).balance, 0);
    }

    function invariant_FundsReceiverGetsAllEth() public view {
        assertEq(address(fundsReceiver).balance, handler.ghostEthPaid());
    }

    function _phases() internal view returns (uint256[][3] memory phases_) {
        phases_[0] = new uint256[](3);
        phases_[0][0] = PHASE_0_CAP;
        phases_[0][1] = PHASE_0_PRICE;
        phases_[0][2] = startingTime + PHASE_DURATION;
        phases_[1] = new uint256[](3);
        phases_[1][0] = PHASE_1_CAP;
        phases_[1][1] = PHASE_1_PRICE;
        phases_[1][2] = startingTime + 2 * PHASE_DURATION;
        phases_[2] = new uint256[](3);
        phases_[2][0] = PHASE_2_CAP;
        phases_[2][1] = PHASE_2_PRICE;
        phases_[2][2] = startingTime + 3 * PHASE_DURATION;
    }
}
