// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

import "forge-std/Test.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockAggregator.sol";
import "./mocks/RejectEther.sol";
import "../src/Presale.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract PresaleTest is Test {
    struct PresaleParams {
        address saleToken;
        address usdt;
        address usdc;
        address fundsReceiver;
        address dataFeed;
        uint256 maxPriceAge;
        uint256 maxSellingAmount;
        uint256 startingTime;
        uint256 endingTime;
        uint256[][3] phases;
    }

    MockERC20 usdc;
    MockERC20 usdt18;
    MockERC20 saleToken;
    MockAggregator aggregator;
    address user;
    address owner;
    address fundsReceiver;
    uint256 maxPriceAge;
    uint256 maxSellingAmount;
    uint256 startingTime;
    uint256 endingTime;
    Presale presale;

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
        user = makeAddr("user");
        fundsReceiver = makeAddr("fundsReceiver");

        aggregator = new MockAggregator(ETH_PRICE);
        saleToken = new MockERC20("Sale Token", "SALE", 18);
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        usdt18 = new MockERC20("Mock USDT 18 dec", "USDT18", 18);

        maxPriceAge = MAX_PRICE_AGE;
        maxSellingAmount = MAX_SELLING_AMOUNT;
        startingTime = block.timestamp + START_DELAY;
        endingTime = startingTime + 3 * PHASE_DURATION;
        saleToken.mint(owner, maxSellingAmount);

        vm.startPrank(owner);
        uint64 nonce_ = vm.getNonce(owner);
        address presaleAddress_ = vm.computeCreateAddress(owner, nonce_);
        saleToken.approve(presaleAddress_, maxSellingAmount);
        vm.stopPrank();

        // a pranked call may bump the sender's nonce:
        // pin it so the presale is deployed at the address that was approved
        vm.setNonceUnsafe(owner, nonce_);
        presale = _newPresale(startingTime, endingTime);
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

    function test_Constructor_RevertWhen_StartingTimeAfterEndingTime() public {
        uint256 endingTime_ = block.timestamp + 1 days;
        uint256 startingTime_ = endingTime_ + 1 days;

        vm.expectRevert(Presale.IncorrectTimes.selector);
        _newPresale(startingTime_, endingTime_);
    }

    function test_Constructor_RevertWhen_StartingTimeEqualsEndingTime() public {
        uint256 startingTime_ = block.timestamp + 1 days;
        uint256 endingTime_ = startingTime_;

        vm.expectRevert(Presale.IncorrectTimes.selector);
        _newPresale(startingTime_, endingTime_);
    }

    function test_Constructor_RevertWhen_NoAllowance() public {
        MockERC20 tokenNotApproved_ = new MockERC20("Token Not Approved", "TKNA", 6);
        tokenNotApproved_.mint(owner, MAX_SELLING_AMOUNT);
        PresaleParams memory presaleParams_ = _defaultParams();
        presaleParams_.saleToken = address(tokenNotApproved_);
        address presaleAddress_ = vm.computeCreateAddress(owner, vm.getNonce(owner));

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, presaleAddress_, 0, MAX_SELLING_AMOUNT
            )
        );
        _deployPresale(presaleParams_);
    }

    function test_Constructor_RevertWhen_PhaseHasTooFewValues() public {
        PresaleParams memory presaleParams_ = _defaultParams();
        presaleParams_.phases[1] = new uint256[](2);

        vm.expectRevert(Presale.InvalidPhaseShape.selector);
        _deployPresale(presaleParams_);
    }

    function test_Constructor_RevertWhen_PhaseHasTooManyValues() public {
        PresaleParams memory presaleParams_ = _defaultParams();
        presaleParams_.phases[1] = new uint256[](4);

        vm.expectRevert(Presale.InvalidPhaseShape.selector);
        _deployPresale(presaleParams_);
    }

    function test_Constructor_RevertWhen_PhasePriceIsZero() public {
        PresaleParams memory presaleParams_ = _defaultParams();
        presaleParams_.phases[1][1] = 0;

        vm.expectRevert(Presale.InvalidPhasePrice.selector);
        _deployPresale(presaleParams_);
    }

    function test_Constructor_RevertWhen_PhaseCapsAreNotIncreasing() public {
        PresaleParams memory presaleParams_ = _defaultParams();
        presaleParams_.phases[2][0] = presaleParams_.phases[0][0];

        vm.expectRevert(Presale.InvalidPhaseCap.selector);
        _deployPresale(presaleParams_);
    }

    function test_Constructor_RevertWhen_LastPhaseCapIsNotMaxSellingAmount() public {
        PresaleParams memory presaleParams_ = _defaultParams();
        presaleParams_.phases[2][0] = MAX_SELLING_AMOUNT - 1;

        vm.expectRevert(Presale.InvalidPhaseCap.selector);
        _deployPresale(presaleParams_);
    }

    function test_Constructor_RevertWhen_FirstPhaseEndsBeforeStart() public {
        PresaleParams memory presaleParams_ = _defaultParams();
        presaleParams_.phases[0][2] = presaleParams_.startingTime;

        vm.expectRevert(Presale.InvalidPhaseTime.selector);
        _deployPresale(presaleParams_);
    }

    function test_Constructor_RevertWhen_PhaseTimesAreNotIncreasing() public {
        PresaleParams memory presaleParams_ = _defaultParams();
        presaleParams_.phases[1][2] = presaleParams_.phases[0][2];

        vm.expectRevert(Presale.InvalidPhaseTime.selector);
        _deployPresale(presaleParams_);
    }

    function test_Constructor_RevertWhen_LastPhaseEndsAfterEndingTime() public {
        PresaleParams memory presaleParams_ = _defaultParams();
        presaleParams_.phases[2][2] = presaleParams_.endingTime + 1;

        vm.expectRevert(Presale.InvalidPhaseTime.selector);
        _deployPresale(presaleParams_);
    }

    function test_Constructor_RevertWhen_MaxPriceAgeIsZero() public {
        PresaleParams memory presaleParams_ = _defaultParams();
        presaleParams_.maxPriceAge = 0;

        vm.expectRevert(Presale.ZeroAmount.selector);
        _deployPresale(presaleParams_);
    }

    function test_Constructor_RevertWhen_FundsReceiverIsZeroAddress() public {
        PresaleParams memory presaleParams_ = _defaultParams();
        presaleParams_.fundsReceiver = address(0);

        vm.expectRevert(Presale.ZeroAddress.selector);
        _deployPresale(presaleParams_);
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
        uint256 userTokenBalanceBefore_ = presale.userTokenBalance(user);
        uint256 balanceFundsReceiverBefore_ = usdc.balanceOf(fundsReceiver);

        _buyWithStable(usdc, user, amount_);

        uint256 userTokenBalanceAfter_ = presale.userTokenBalance(user);
        uint256 balanceFundsReceiverAfter_ = usdc.balanceOf(fundsReceiver);
        assertEq(userTokenBalanceAfter_ - userTokenBalanceBefore_, 50e18);
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

    function test_BuyWithStable_UsesNewPhasePriceWhenPhaseTimeExpired() public {
        vm.warp(presale.phases(0, 2));

        uint256 amount_ = 1_000e6;
        _buyWithStable(usdc, user, amount_);

        uint256 userTokenBalance_ = presale.userTokenBalance(user);
        assertEq(userTokenBalance_, 100_000e18);
    }

    function test_BuyWithStable_SkipsMultipleExpiredPhases() public {
        vm.warp(presale.phases(1, 2));

        uint256 amount_ = 1_000e6;
        _buyWithStable(usdc, user, amount_);

        uint256 userTokenBalance_ = presale.userTokenBalance(user);
        assertEq(userTokenBalance_, 50_000e18);
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

        vm.expectRevert(Presale.SaleEnded.selector);
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

    function test_BuyWithStable_RevertWhen_PurchaseCrossesPhaseCap() public {
        _warpTo(startingTime + 1 days);

        uint256 amount_ = 5_000e6 + 1;
        usdc.mint(user, amount_);

        vm.startPrank(user);
        usdc.approve(address(presale), amount_);
        vm.expectRevert(Presale.PhaseCapExceeded.selector);
        presale.buyWithStable(address(usdc), amount_);
        vm.stopPrank();
    }

    function test_BuyWithStable_RevertWhen_PurchaseCrossesPhaseOneCap() public {
        vm.warp(startingTime + 1 days);
        _buyWithStable(usdc, user, 5_000e6);

        uint256 amount_ = 10_000e6 + 1;
        usdc.mint(user, amount_);

        vm.startPrank(user);
        usdc.approve(address(presale), amount_);
        vm.expectRevert(Presale.PhaseCapExceeded.selector);
        presale.buyWithStable(address(usdc), amount_);
        vm.stopPrank();
    }

    // buyWithEther

    function test_BuyWithEther_ReturnsExpectedTokens() public {
        aggregator.setAnswer(2_000e8);
        uint256 amount_ = 0.75 ether;
        vm.deal(user, amount_);
        _warpTo(startingTime + 1 days);
        uint256 userTokenBalanceBefore_ = presale.userTokenBalance(user);

        vm.prank(user);
        presale.buyWithEther{value: amount_}();

        uint256 userTokenBalanceAfter_ = presale.userTokenBalance(user);
        assertEq(userTokenBalanceAfter_ - userTokenBalanceBefore_, 300_000e18);
    }

    function test_BuyWithEther_UpdatesAccounting() public {
        uint256 amount_ = 1 ether;
        vm.deal(user, amount_);
        _warpTo(startingTime);
        uint256 totalSoldBefore_ = presale.totalSold();
        uint256 userTokenBalanceBefore_ = presale.userTokenBalance(user);
        uint256 balanceFundsReceiverBefore_ = fundsReceiver.balance;

        vm.prank(user);
        presale.buyWithEther{value: amount_}();

        uint256 totalSoldAfter_ = presale.totalSold();
        uint256 userTokenBalanceAfter_ = presale.userTokenBalance(user);
        uint256 balanceFundsReceiverAfter_ = fundsReceiver.balance;

        assertEq(totalSoldAfter_ - totalSoldBefore_, 600_000e18);
        assertEq(userTokenBalanceAfter_ - userTokenBalanceBefore_, 600_000e18);
        assertEq(balanceFundsReceiverAfter_ - balanceFundsReceiverBefore_, amount_);
    }

    function test_BuyWithEther_AllowsAtStart() public {
        uint256 amount_ = 1 ether;
        vm.deal(user, amount_);
        _warpTo(startingTime);
        uint256 userTokenBalanceBefore_ = presale.userTokenBalance(user);

        vm.prank(user);
        presale.buyWithEther{value: amount_}();

        uint256 userTokenBalanceAfter_ = presale.userTokenBalance(user);
        assertEq(userTokenBalanceAfter_ - userTokenBalanceBefore_, 600_000e18);
    }

    function test_BuyWithEther_AllowsAtEnd() public {
        uint256 amount_ = 1 ether;
        vm.deal(user, amount_);
        _warpTo(endingTime);
        uint256 balanceFundsReceiverBefore_ = fundsReceiver.balance;
        uint256 userTokenBalanceBefore_ = presale.userTokenBalance(user);

        vm.prank(user);
        presale.buyWithEther{value: amount_}();

        uint256 userTokenBalance_ = presale.userTokenBalance(user);
        uint256 userTokenBalanceAfter_ = presale.userTokenBalance(user);
        uint256 balanceFundsReceiverAfter_ = fundsReceiver.balance;

        assertEq(userTokenBalanceAfter_ - userTokenBalanceBefore_, 150_000e18);
        assertEq(balanceFundsReceiverAfter_ - balanceFundsReceiverBefore_, amount_);
        assertEq(presale.totalSold(), userTokenBalance_);
        assertEq(user.balance, 0);
        assertEq(address(presale).balance, 0);
    }

    function test_BuyWithEther_ZeroValueChangesNothing() public {
        uint256 amount_ = 0;
        _warpTo(startingTime + 1 days);
        uint256 userTokenBalanceBefore_ = presale.userTokenBalance(user);
        uint256 totalSoldBefore_ = presale.totalSold();

        vm.prank(user);
        presale.buyWithEther{value: amount_}();

        uint256 userTokenBalanceAfter_ = presale.userTokenBalance(user);
        uint256 totalSoldAfter_ = presale.totalSold();
        assertEq(userTokenBalanceAfter_ - userTokenBalanceBefore_, 0);
        assertEq(totalSoldAfter_ - totalSoldBefore_, 0);
    }

    function test_BuyWithEther_AllowsPriceAtMaxAge() public {
        uint256 amount_ = 1 ether;
        uint256 updatedAt_ = startingTime;
        vm.deal(user, amount_);
        aggregator.setUpdatedAt(updatedAt_);
        vm.warp(updatedAt_ + MAX_PRICE_AGE);
        uint256 userTokenBalanceBefore_ = presale.userTokenBalance(user);

        vm.prank(user);
        presale.buyWithEther{value: amount_}();

        uint256 userTokenBalanceAfter_ = presale.userTokenBalance(user);
        assertEq(userTokenBalanceAfter_ - userTokenBalanceBefore_, 600_000e18);
    }

    function test_BuyWithEther_EmitsTokenBuy() public {
        uint256 amount_ = 1 ether;
        vm.deal(user, amount_);
        _warpTo(startingTime + 1 days);

        vm.expectEmit(false, false, false, true, address(presale));
        emit Presale.TokenBuy(user, 600_000e18);
        vm.prank(user);
        presale.buyWithEther{value: amount_}();
    }

    function test_BuyWithEther_RevertWhen_BuyingBeforeStartingTime() public {
        uint256 amount_ = 1e18;
        vm.deal(user, amount_);
        _warpTo(startingTime - 1);

        vm.expectRevert(Presale.NotStarted.selector);
        vm.prank(user);
        presale.buyWithEther{value: amount_}();
    }

    function test_BuyWithEther_RevertWhen_BuyingAfterEndingTime() public {
        uint256 amount_ = 1e18;
        vm.deal(user, amount_);
        _warpTo(endingTime + 1);

        vm.expectRevert(Presale.SaleEnded.selector);
        vm.prank(user);
        presale.buyWithEther{value: amount_}();
    }

    function test_BuyWithEther_RevertWhen_UserBlacklisted() public {
        uint256 amount_ = 1e18;
        vm.deal(user, amount_);
        _warpTo(startingTime + 1);

        vm.prank(owner);
        presale.blacklist(user);

        vm.expectRevert(Presale.UserBlacklisted.selector);
        vm.prank(user);
        presale.buyWithEther{value: amount_}();
    }

    function test_BuyWithEther_RevertWhen_SoldOut() public {
        uint256 amount_ = 5 ether + 1;
        vm.deal(user, amount_);
        _warpTo(startingTime + 1);

        vm.expectRevert(Presale.SoldOut.selector);
        vm.prank(user);
        presale.buyWithEther{value: amount_}();
    }

    function test_BuyWithEther_RevertWhen_ReceiverRejectsEther() public {
        RejectEther rejecter_ = new RejectEther();
        uint256 amount_ = 1 ether;
        vm.deal(user, amount_);
        _warpTo(startingTime + 1 days);

        PresaleParams memory presaleParams_ = _defaultParams();
        presaleParams_.fundsReceiver = address(rejecter_);
        saleToken.mint(owner, MAX_SELLING_AMOUNT);
        uint64 nonce_ = vm.getNonce(owner);
        address presaleAddress_ = vm.computeCreateAddress(owner, nonce_);

        vm.prank(owner);
        saleToken.approve(presaleAddress_, MAX_SELLING_AMOUNT);
        vm.setNonceUnsafe(owner, nonce_);
        Presale presaleRejecting_ = _deployPresale(presaleParams_);

        vm.expectRevert(Presale.TransferFailed.selector);
        vm.prank(user);
        presaleRejecting_.buyWithEther{value: amount_}();
    }

    function test_BuyWithEther_RevertWhen_PriceIsZero() public {
        int256 answer_ = 0;
        uint256 amount_ = 1 ether;
        aggregator.setAnswer(answer_);

        _warpTo(startingTime);
        vm.deal(user, amount_);

        vm.expectRevert(Presale.InvalidPrice.selector);
        vm.prank(user);
        presale.buyWithEther{value: amount_}();
    }

    function test_BuyWithEther_RevertWhen_PriceIsNegative() public {
        int256 answer_ = -1;
        uint256 amount_ = 1 ether;
        aggregator.setAnswer(answer_);

        _warpTo(startingTime);
        vm.deal(user, amount_);

        vm.expectRevert(Presale.InvalidPrice.selector);
        vm.prank(user);
        presale.buyWithEther{value: amount_}();
    }

    function test_BuyWithEther_RevertWhen_PriceIsStale() public {
        uint256 amount_ = 1 ether;
        uint256 updatedAt_ = startingTime;
        vm.deal(user, amount_);
        aggregator.setUpdatedAt(updatedAt_);
        vm.warp(updatedAt_ + MAX_PRICE_AGE + 1);

        vm.expectRevert(Presale.StalePrice.selector);
        vm.prank(user);
        presale.buyWithEther{value: amount_}();
    }

    function test_BuyWithEther_RevertWhen_PurchaseCrossesPhaseCap() public {
        aggregator.setAnswer(2_500e8);
        uint256 amount_ = 2 ether + 1;
        vm.deal(user, amount_);
        _warpTo(startingTime + 1 days);

        vm.expectRevert(Presale.PhaseCapExceeded.selector);
        vm.prank(user);
        presale.buyWithEther{value: amount_}();
    }

    // claim

    function test_Claim_TransfersBalanceAfterEnd() public {
        uint256 amount_ = 1 ether;
        vm.deal(user, amount_);
        _warpTo(startingTime + 1 days);

        vm.prank(user);
        presale.buyWithEther{value: amount_}();
        uint256 userSaleTokenBalanceBefore_ = saleToken.balanceOf(user);
        uint256 presaleSaleTokenBalanceBefore_ = saleToken.balanceOf(address(presale));

        _warpTo(endingTime);
        vm.prank(user);
        presale.claim();

        uint256 userTokenBalance_ = presale.userTokenBalance(user);
        uint256 userSaleTokenBalanceAfter_ = saleToken.balanceOf(user);
        uint256 presaleSaleTokenBalanceAfter_ = saleToken.balanceOf(address(presale));
        assertEq(userTokenBalance_, 0);
        assertEq(userSaleTokenBalanceBefore_, 0);
        assertEq(userSaleTokenBalanceAfter_, 600_000e18);
        assertEq(presaleSaleTokenBalanceBefore_ - presaleSaleTokenBalanceAfter_, 600_000e18);
    }

    function test_Claim_SecondClaimTransfersNothing() public {
        uint256 amount_ = 1 ether;
        vm.deal(user, amount_);
        _warpTo(startingTime + 1 days);

        vm.prank(user);
        presale.buyWithEther{value: amount_}();
        _warpTo(endingTime);

        vm.prank(user);
        presale.claim();

        uint256 userTokenBalance_ = presale.userTokenBalance(user);
        uint256 userSaleTokenBalance_ = saleToken.balanceOf(user);
        assertEq(userTokenBalance_, 0);
        assertEq(userSaleTokenBalance_, 600_000e18);

        vm.prank(user);
        presale.claim();

        uint256 userSaleTokenBalance2_ = saleToken.balanceOf(user);
        assertEq(userSaleTokenBalance_, userSaleTokenBalance2_);
    }

    function test_Claim_ZeroBalanceDoesNotRevert() public {
        _warpTo(endingTime + 1 days);

        vm.prank(user);
        presale.claim();

        uint256 userTokenBalance_ = presale.userTokenBalance(user);
        uint256 userSaleTokenBalance_ = saleToken.balanceOf(user);
        assertEq(userTokenBalance_, 0);
        assertEq(userSaleTokenBalance_, 0);
    }

    function test_Claim_BlacklistedUserCanClaim() public {
        uint256 amount_ = 1 ether;
        vm.deal(user, amount_);
        _warpTo(startingTime + 1 days);

        vm.prank(user);
        presale.buyWithEther{value: amount_}();

        vm.prank(owner);
        presale.blacklist(user);
        _warpTo(endingTime);

        vm.prank(user);
        presale.claim();

        uint256 userTokenBalance_ = presale.userTokenBalance(user);
        uint256 userSaleTokenBalance_ = saleToken.balanceOf(user);
        assertEq(userTokenBalance_, 0);
        assertEq(userSaleTokenBalance_, 600_000e18);
    }

    function test_Claim_RevertWhen_BeforeEnding() public {
        _warpTo(endingTime - 1);

        vm.expectRevert(Presale.NotEnded.selector);
        vm.prank(user);
        presale.claim();
    }

    // Utils

    function test_Blacklist_SetsFlag() public {
        vm.prank(owner);
        presale.blacklist(user);

        assertTrue(presale.isBlacklisted(user));
    }

    function test_RemoveBlacklist_ClearsFlag() public {
        vm.prank(owner);
        presale.blacklist(user);
        assertTrue(presale.isBlacklisted(user));

        vm.prank(owner);
        presale.removeBlacklist(user);
        assertFalse(presale.isBlacklisted(user));
    }

    function test_EmergencyERC20Withdraw_TransfersToOwner() public {
        uint256 amount_ = 1_000e6;
        usdc.mint(address(presale), amount_);
        uint256 ownerUsdcBalanceBefore_ = usdc.balanceOf(owner);

        vm.prank(owner);
        presale.emergencyERC20Withdraw(address(usdc), amount_);

        uint256 ownerUsdcBalanceAfter_ = usdc.balanceOf(owner);
        uint256 presaleUsdcBalance_ = usdc.balanceOf(address(presale));
        assertEq(ownerUsdcBalanceAfter_ - ownerUsdcBalanceBefore_, amount_);
        assertEq(presaleUsdcBalance_, 0);
    }

    function test_EmergencyERC20Withdraw_TransfersSaleTokenSurplusAfterEnd() public {
        uint256 amount_ = 1 ether;
        _warpTo(startingTime + 1 days);
        vm.deal(user, amount_);

        vm.prank(user);
        presale.buyWithEther{value: amount_}();
        vm.warp(endingTime + 1);

        vm.prank(owner);
        presale.emergencyERC20Withdraw(address(saleToken), 2_400_000e18);

        uint256 ownerSaleTokenBalance_ = saleToken.balanceOf(owner);
        uint256 presaleSaleTokenBalance_ = saleToken.balanceOf(address(presale));
        assertEq(ownerSaleTokenBalance_, 2_400_000e18);
        assertEq(presaleSaleTokenBalance_, 600_000e18);
    }

    function test_EmergencyERC20Withdraw_TransfersSaleTokenSurplusAfterClaim() public {
        uint256 amount_ = 1 ether;
        _warpTo(startingTime + 1 days);
        vm.deal(user, amount_);

        vm.startPrank(user);
        presale.buyWithEther{value: amount_}();
        vm.warp(endingTime + 1);
        presale.claim();
        vm.stopPrank();

        vm.prank(owner);
        presale.emergencyERC20Withdraw(address(saleToken), 2_400_000e18);

        uint256 ownerSaleTokenBalance_ = saleToken.balanceOf(owner);
        uint256 presaleSaleTokenBalance_ = saleToken.balanceOf(address(presale));
        uint256 userSaleTokenBalance_ = saleToken.balanceOf(user);
        assertEq(ownerSaleTokenBalance_, 2_400_000e18);
        assertEq(presaleSaleTokenBalance_, 0);
        assertEq(userSaleTokenBalance_, 600_000e18);
    }

    function test_EmergencyETHWithdraw_TransfersToOwner() public {
        uint256 amount_ = 1_000e6;
        vm.deal(address(presale), amount_);
        uint256 ownerBalanceBefore_ = owner.balance;

        vm.prank(owner);
        presale.emergencyETHWithdraw();

        uint256 ownerBalanceAfter_ = owner.balance;
        uint256 presaleBalance_ = address(presale).balance;
        assertEq(ownerBalanceAfter_ - ownerBalanceBefore_, amount_);
        assertEq(presaleBalance_, 0);
    }

    function test_GetEtherPrice_ScalesTo18Decimals() public view {
        uint256 price_ = presale.getEtherPrice();
        assertEq(price_, 3_000e18);
    }

    function test_GetEtherPrice_ScalesFeedWith18Decimals() public {
        uint8 decimals_ = 18;
        int256 answer_ = 3_000e18;
        aggregator.setDecimals(decimals_);
        aggregator.setAnswer(answer_);

        uint256 price_ = presale.getEtherPrice();
        assertEq(price_, 3_000e18);
    }

    function test_GetEtherPrice_ScalesFeedWith6Decimals() public {
        uint8 decimals_ = 6;
        int256 answer_ = 3_000e6;
        aggregator.setDecimals(decimals_);
        aggregator.setAnswer(answer_);

        uint256 price_ = presale.getEtherPrice();
        assertEq(price_, 3_000e18);
    }

    function test_TransferOwnership_KeepsOwnerUntilAccepted() public {
        address newOwner_ = makeAddr("newOwner");

        vm.prank(owner);
        presale.transferOwnership(newOwner_);

        assertEq(presale.owner(), owner);
        assertEq(presale.pendingOwner(), newOwner_);
    }

    function test_AcceptOwnership_TransfersOwnership() public {
        address newOwner_ = makeAddr("newOwner");

        vm.prank(owner);
        presale.transferOwnership(newOwner_);

        vm.prank(newOwner_);
        presale.acceptOwnership();

        assertEq(presale.owner(), newOwner_);
        assertEq(presale.pendingOwner(), address(0));
    }

    function test_Blacklist_RevertWhen_NotOwner() public {
        address randomUser_ = makeAddr("randomUser");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        presale.blacklist(randomUser_);
    }

    function test_RemoveBlacklist_RevertWhen_NotOwner() public {
        address randomUser_ = makeAddr("randomUser");
        vm.prank(owner);
        presale.blacklist(randomUser_);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        presale.removeBlacklist(randomUser_);
    }

    function test_EmergencyERC20Withdraw_RevertWhen_NotOwner() public {
        uint256 amount_ = 1_000e6;
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        presale.emergencyERC20Withdraw(address(usdc), amount_);
    }

    function test_EmergencyERC20Withdraw_RevertWhen_SaleTokenAmountExceedsSurplus() public {
        uint256 amount_ = 1 ether;
        _warpTo(startingTime + 1 days);
        vm.deal(user, amount_);

        vm.prank(user);
        presale.buyWithEther{value: amount_}();
        vm.warp(endingTime + 1);

        vm.expectRevert(Presale.AmountExceedsSurplus.selector);
        vm.prank(owner);
        presale.emergencyERC20Withdraw(address(saleToken), 2_400_000e18 + 1);
    }

    function test_EmergencyERC20Withdraw_RevertWhen_SaleTokenBeforeEnd() public {
        uint256 amount_ = 1 ether;
        _warpTo(startingTime + 1 days);
        vm.deal(user, amount_);

        vm.prank(user);
        presale.buyWithEther{value: amount_}();
        vm.warp(endingTime);

        vm.expectRevert(Presale.NotEnded.selector);
        vm.prank(owner);
        presale.emergencyERC20Withdraw(address(saleToken), 1);
    }

    function test_EmergencyETHWithdraw_RevertWhen_NotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        presale.emergencyETHWithdraw();
    }

    function test_RenounceOwnership_RevertWhen_Called() public {
        vm.expectRevert(Presale.RenounceDisabled.selector);
        vm.prank(owner);
        presale.renounceOwnership();
    }

    // helpers

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
        PresaleParams memory presaleParams_ = _defaultParams();
        presaleParams_.startingTime = start_;
        presaleParams_.endingTime = end_;
        presale_ = _deployPresale(presaleParams_);
    }

    function _buyWithStable(MockERC20 stable_, address buyer_, uint256 amount_) internal {
        stable_.mint(buyer_, amount_);
        vm.startPrank(buyer_);
        stable_.approve(address(presale), amount_);
        presale.buyWithStable(address(stable_), amount_);
        vm.stopPrank();
    }

    function _warpTo(uint256 timestamp_) internal {
        vm.warp(timestamp_);
        aggregator.setUpdatedAt(timestamp_);
    }

    function _defaultParams() internal view returns (PresaleParams memory p_) {
        p_.saleToken = address(saleToken);
        p_.usdt = address(usdt18);
        p_.usdc = address(usdc);
        p_.fundsReceiver = fundsReceiver;
        p_.dataFeed = address(aggregator);
        p_.maxPriceAge = maxPriceAge;
        p_.maxSellingAmount = maxSellingAmount;
        p_.startingTime = startingTime;
        p_.endingTime = endingTime;
        p_.phases = _phases();
    }

    function _deployPresale(PresaleParams memory p_) internal returns (Presale presale_) {
        vm.prank(owner);
        presale_ = new Presale(
            p_.saleToken,
            p_.usdt,
            p_.usdc,
            p_.fundsReceiver,
            p_.dataFeed,
            p_.maxPriceAge,
            p_.maxSellingAmount,
            p_.startingTime,
            p_.endingTime,
            p_.phases
        );
    }
}
