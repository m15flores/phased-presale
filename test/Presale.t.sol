// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

import "forge-std/Test.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockAggregator.sol";
import "../src/Presale.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract PresaleTest is Test {
    MockERC20 usdc;
    MockERC20 usdt18;
    MockERC20 saleToken;
    MockAggregator aggregator;
    address user;
    address owner;
    address fundsReceiver;
    uint256 maxSellingAmount;
    uint256 startingTime;
    uint256 endingTime;
    Presale presale;

    int256 internal constant ETH_PRICE = 3_000e8;
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
        user = makeAddr("user");
        fundsReceiver = makeAddr("fundsReceiver");

        aggregator = new MockAggregator(ETH_PRICE);
        saleToken = new MockERC20("Sale Token", "SALE", 18);
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        usdt18 = new MockERC20("Mock USDT 18 dec", "USDT18", 18);

        maxSellingAmount = MAX_SELLING_AMOUNT;
        startingTime = block.timestamp + START_DELAY;
        endingTime = startingTime + 3 * PHASE_DURATION;
        saleToken.mint(owner, maxSellingAmount);

        vm.startPrank(owner);

        address presaleAddress_ = vm.computeCreateAddress(owner, vm.getNonce(owner));
        saleToken.approve(presaleAddress_, maxSellingAmount);
        presale = new Presale(
            address(saleToken),
            address(usdt18),
            address(usdc),
            fundsReceiver,
            address(aggregator),
            maxSellingAmount,
            startingTime,
            endingTime,
            _phases()
        );

        vm.stopPrank();
    }

    // Constructor

    function test_Constructor_SetsParametersAndInitialState() public view {
        assertEq(presale.saleTokenAddress(), address(saleToken));
        assertEq(presale.usdtAddress(), address(usdt18));
        assertEq(presale.usdcAddress(), address(usdc));
        assertEq(presale.fundsReceiverAddress(), address(fundsReceiver));
        assertEq(presale.dataFeedAddress(), address(aggregator));
        assertEq(presale.maxSellingAmount(), MAX_SELLING_AMOUNT);
        assertEq(presale.startingTime(), startingTime);
        assertEq(presale.endingTime(), endingTime);

        assertEq(presale.phases(0, 0), PHASE_0_CAP);
        assertEq(presale.phases(0, 1), PHASE_0_PRICE);
        assertEq(presale.phases(0, 2), startingTime + PHASE_DURATION);
        assertEq(presale.phases(1, 0), PHASE_1_CAP);
        assertEq(presale.phases(1, 1), PHASE_1_PRICE);
        assertEq(presale.phases(1, 2), startingTime + 2 * PHASE_DURATION);
        assertEq(presale.phases(2, 0), PHASE_2_CAP);
        assertEq(presale.phases(2, 1), PHASE_2_PRICE);
        assertEq(presale.phases(2, 2), startingTime + 3 * PHASE_DURATION);

        assertEq(presale.owner(), owner);
        assertEq(presale.totalSold(), 0);
        assertEq(presale.currentPhase(), 0);
        assertEq(presale.userTokenBalance(user), 0);
        assertEq(presale.isBlacklisted(user), false);

        assertEq(saleToken.balanceOf(address(presale)), MAX_SELLING_AMOUNT);
        assertEq(saleToken.balanceOf(owner), 0);
    }

    function test_Constructor_RevertsWhen_StartingTimeAfterEndingTime() public {
        uint256 endingTime_ = block.timestamp + 1 days;
        uint256 startingTime_ = endingTime_ + 1 days;

        vm.expectRevert(Presale.IncorrectTimes.selector);
        _newPresale(startingTime_, endingTime_);
    }

    function test_Constructor_RevertsWhen_StartingTimeEqualsEndingTime() public {
        uint256 startingTime_ = block.timestamp + 1 days;
        uint256 endingTime_ = startingTime_;

        vm.expectRevert(Presale.IncorrectTimes.selector);
        _newPresale(startingTime_, endingTime_);
    }

    function test_Constructor_RevertsWhen_NoAllowance() public {
        MockERC20 tokenNotApproved_ = new MockERC20("Token Not Approved", "TKNA", 6);
        tokenNotApproved_.mint(owner, MAX_SELLING_AMOUNT);

        vm.prank(owner);
        address presaleAddress_ = vm.computeCreateAddress(owner, vm.getNonce(owner));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, presaleAddress_, 0, MAX_SELLING_AMOUNT
            )
        );
        new Presale(
            address(tokenNotApproved_),
            address(usdt18),
            address(usdc),
            fundsReceiver,
            address(aggregator),
            maxSellingAmount,
            startingTime,
            endingTime,
            _phases()
        );
    }

    // BuyWithStable

    function test_BuyWithStable_Stable18DecimalsReturnsExpectedTokens() public {
        vm.warp(startingTime + 1 days);
        uint256 amount_ = 3.75e18;
        uint256 userTokenBalanceBefore_ = presale.userTokenBalance(user);

        _buyWithStable(usdt18, user, amount_);

        uint256 userTokenBalanceAfter_ = presale.userTokenBalance(user);
        assertEq(userTokenBalanceAfter_ - userTokenBalanceBefore_, 750e18);
    }

    function test_BuyWithStable_Usdc6DecimalsReturnsExpectedTokens() public {
        vm.warp(startingTime + 1 days);
        uint256 amount_ = 2.5e6;
        uint256 userTokenBalanceBefore_ = presale.userTokenBalance(user);

        _buyWithStable(usdc, user, amount_);

        uint256 userTokenBalanceAfter_ = presale.userTokenBalance(user);

        assertEq(userTokenBalanceAfter_ - userTokenBalanceBefore_, 500e18);
    }

    function test_BuyWithStable_UpdatesAccounting() public {
        vm.warp(startingTime + 1 days);
        uint256 amount_ = 1_000e6;
        uint256 totalSoldBefore_ = presale.totalSold();
        uint256 userTokenBalanceBefore_ = presale.userTokenBalance(user);
        uint256 balanceFundsReceiverBefore_ = usdc.balanceOf(fundsReceiver);
        usdc.mint(user, amount_);
        uint256 userUsdcBefore_ = usdc.balanceOf(user);

        vm.startPrank(user);
        usdc.approve(address(presale), amount_);
        presale.buyWithStable(address(usdc), amount_);
        vm.stopPrank();

        uint256 totalSoldAfter_ = presale.totalSold();
        uint256 userTokenBalanceAfter_ = presale.userTokenBalance(user);
        uint256 balanceFundsReceiverAfter_ = usdc.balanceOf(fundsReceiver);
        uint256 userUsdcAfter_ = usdc.balanceOf(user);

        assertEq(totalSoldAfter_ - totalSoldBefore_, 200_000e18); // 1.000 USDC on 0.005 USD
        assertEq(userTokenBalanceAfter_ - userTokenBalanceBefore_, 200_000e18);
        assertEq(balanceFundsReceiverAfter_ - balanceFundsReceiverBefore_, amount_);
        assertEq(userUsdcBefore_ - userUsdcAfter_, amount_);
    }

    function test_BuyWithStable_AllowsAtStart() public {
        vm.warp(startingTime);
        uint256 amount_ = 1e6;
        uint256 userTokenBalanceBefore_ = presale.userTokenBalance(user);

        _buyWithStable(usdc, user, amount_);

        uint256 userTokenBalanceAfter_ = presale.userTokenBalance(user);
        assertEq(userTokenBalanceAfter_ - userTokenBalanceBefore_, 200e18);
    }

    function test_BuyWithStable_AllowsAtEnd() public {
        vm.warp(endingTime);
        uint256 amount_ = 1e6;
        uint256 balanceFundsReceiverBefore_ = usdc.balanceOf(fundsReceiver);

        _buyWithStable(usdc, user, amount_);

        uint256 userTokenBalance_ = presale.userTokenBalance(user);
        uint256 balanceFundsReceiverAfter_ = usdc.balanceOf(fundsReceiver);
        assertGt(userTokenBalance_, 0);
        assertEq(balanceFundsReceiverAfter_ - balanceFundsReceiverBefore_, amount_);
    }

    function test_BuyWithStable_UsesPhaseOnePriceAfterCapReached() public {
        vm.warp(startingTime + 1 days);
        uint256 amount_ = 5_000e6;

        _buyWithStable(usdc, user, amount_);

        assertEq(presale.currentPhase(), 1);

        uint256 userTokenBalanceBefore_ = presale.userTokenBalance(user);
        uint256 amount2_ = 1e6;

        _buyWithStable(usdc, user, amount2_);

        uint256 userTokenBalanceAfter_ = presale.userTokenBalance(user);
        assertEq(userTokenBalanceAfter_ - userTokenBalanceBefore_, 100e18);
    }

    function test_BuyWithStable_ZeroAmountChangesNothing() public {
        vm.warp(startingTime + 1 days);
        uint256 amount_ = 0;
        uint256 totalSoldBefore_ = presale.totalSold();
        uint256 userTokenBalanceBefore_ = presale.userTokenBalance(user);
        uint256 balanceFundsReceiverBefore_ = usdc.balanceOf(fundsReceiver);

        _buyWithStable(usdc, user, amount_);

        uint256 totalSoldAfter_ = presale.totalSold();
        uint256 userTokenBalanceAfter_ = presale.userTokenBalance(user);
        uint256 balanceFundsReceiverAfter_ = usdc.balanceOf(fundsReceiver);

        assertEq(totalSoldAfter_ - totalSoldBefore_, 0);
        assertEq(userTokenBalanceAfter_ - userTokenBalanceBefore_, 0);
        assertEq(balanceFundsReceiverAfter_ - balanceFundsReceiverBefore_, 0);
    }

    function test_BuyWithStable_EmitsTokenBuy() public {
        vm.warp(startingTime + 1 days);
        uint256 amount_ = 1_000e6;

        usdc.mint(user, amount_);

        vm.startPrank(user);
        usdc.approve(address(presale), amount_);

        vm.expectEmit(false, false, false, true, address(presale));
        emit Presale.TokenBuy(user, 200_000e18);
        presale.buyWithStable(address(usdc), amount_);

        vm.stopPrank();
    }

    function test_BuyWithStable_RevertWhen_UserBlacklisted() public {
        vm.prank(owner);
        presale.blacklist(user);

        vm.warp(startingTime + 1 days);
        uint256 amount_ = 1_000e6;

        vm.expectRevert(Presale.UserBlacklisted.selector);
        vm.prank(user);
        presale.buyWithStable(address(usdc), amount_);
    }

    function test_BuyWithStable_RevertWhen_BuyingBeforeStartingTime() public {
        vm.warp(startingTime - 1);
        uint256 amount_ = 1_000e6;

        vm.expectRevert(Presale.NotStarted.selector);
        vm.prank(user);
        presale.buyWithStable(address(usdc), amount_);
    }

    function test_BuyWithStable_RevertWhen_BuyingAfterEndingTime() public {
        vm.warp(endingTime + 1);
        uint256 amount_ = 1_000e6;

        vm.expectRevert(Presale.NotStarted.selector);
        vm.prank(user);
        presale.buyWithStable(address(usdc), amount_);
    }

    function test_BuyWithStable_RevertWhen_InvalidToken() public {
        MockERC20 invalidToken_ = new MockERC20("Invalid Token", "ITK", 6);

        vm.warp(startingTime + 1 days);
        uint256 amount_ = 1_000e6;

        vm.expectRevert(Presale.InvalidToken.selector);
        vm.prank(user);
        presale.buyWithStable(address(invalidToken_), amount_);
    }

    function test_BuyWithStable_RevertWhen_SoldOut() public {
        vm.warp(startingTime + 1 days);
        uint256 amount_ = 15_000e6 + 1;
        usdc.mint(user, amount_);

        vm.expectRevert(Presale.SoldOut.selector);
        vm.prank(user);
        presale.buyWithStable(address(usdc), amount_);
    }

    function test_BuyWithStable_RevertWhen_NoAllowance() public {
        address buyer_ = makeAddr("buyer");
        uint256 amount_ = 1_000e6;
        usdc.mint(buyer_, amount_);

        vm.warp(startingTime + 1 days);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(presale), 0, amount_)
        );
        vm.prank(buyer_);
        presale.buyWithStable(address(usdc), amount_);
    }

    function test_BuyWithStable_RevertWhen_NoBalance() public {
        address buyer_ = makeAddr("buyer");
        vm.prank(buyer_);
        usdc.approve(address(presale), type(uint256).max);

        vm.warp(startingTime + 1 days);
        uint256 amount_ = 1_000e6;

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, buyer_, 0, amount_));
        vm.prank(buyer_);
        presale.buyWithStable(address(usdc), amount_);
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

    function _newPresale(uint256 start_, uint256 end_) internal returns (Presale presale_) {
        vm.prank(owner);
        presale_ = new Presale(
            address(saleToken),
            address(usdt18),
            address(usdc),
            fundsReceiver,
            address(aggregator),
            maxSellingAmount,
            start_,
            end_,
            _phases()
        );
    }

    function _buyWithStable(MockERC20 stable_, address buyer_, uint256 amount_) internal {
        stable_.mint(buyer_, amount_);
        vm.startPrank(buyer_);
        stable_.approve(address(presale), amount_);
        presale.buyWithStable(address(stable_), amount_);
        vm.stopPrank();
    }
}
