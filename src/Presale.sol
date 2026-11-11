// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IAggregator.sol";

contract Presale is Ownable2Step {
    using SafeERC20 for IERC20;

    address public usdtAddress;
    address public usdcAddress;
    address public fundsReceiverAddress;
    address public dataFeedAddress;
    address public saleTokenAddress;
    uint256 public maxSellingAmount;
    uint256[][3] public phases;
    uint256 public startingTime;
    uint256 public endingTime;

    uint256 public totalSold;
    uint256 public currentPhase;
    uint256 public totalClaimed;
    uint256 public immutable maxPriceAge;
    mapping(address => bool) public isBlacklisted;
    mapping(address => uint256) public userTokenBalance;

    event TokenPurchased(
        address indexed buyer, address indexed paymentToken, uint256 paymentAmount, uint256 tokenAmount, uint256 phase
    );
    event TokenClaimed(address indexed user, uint256 amount);

    error IncorrectTimes();
    error UserBlacklisted();
    error NotStarted();
    error SaleEnded();
    error NotEnded();
    error InvalidToken();
    error SoldOut();
    error TransferFailed();
    error InvalidPrice();
    error StalePrice();
    error PhaseCapExceeded();
    error InvalidPhaseShape();
    error InvalidPhasePrice();
    error InvalidPhaseCap();
    error InvalidPhaseTime();
    error ZeroAmount();
    error ZeroAddress();
    error AmountExceedsSurplus();
    error RenounceDisabled();
    error SlippageExceeded();

    constructor(
        address saleTokenAddress_,
        address usdtAddress_,
        address usdcAddress_,
        address fundsReceiverAddress_,
        address dataFeedAddress_,
        uint256 maxPriceAge_,
        uint256 maxSellingAmount_,
        uint256 startingTime_,
        uint256 endingTime_,
        uint256[][3] memory phases_
    ) Ownable(msg.sender) {
        if (fundsReceiverAddress_ == address(0)) revert ZeroAddress();
        if (maxPriceAge_ == 0) revert ZeroAmount();
        if (startingTime_ >= endingTime_) revert IncorrectTimes();

        uint256 previousCap_;
        uint256 previousEnd_ = startingTime_;
        for (uint256 i = 0; i < phases_.length; i++) {
            if (phases_[i].length != 3) revert InvalidPhaseShape();
            if (phases_[i][1] == 0) revert InvalidPhasePrice();
            if (phases_[i][0] <= previousCap_) revert InvalidPhaseCap();
            if (phases_[i][2] <= previousEnd_) revert InvalidPhaseTime();
            previousCap_ = phases_[i][0];
            previousEnd_ = phases_[i][2];
        }
        if (previousCap_ != maxSellingAmount_) revert InvalidPhaseCap();
        if (previousEnd_ > endingTime_) revert InvalidPhaseTime();

        saleTokenAddress = saleTokenAddress_;
        usdtAddress = usdtAddress_;
        usdcAddress = usdcAddress_;
        fundsReceiverAddress = fundsReceiverAddress_;
        dataFeedAddress = dataFeedAddress_;
        maxPriceAge = maxPriceAge_;
        maxSellingAmount = maxSellingAmount_;
        startingTime = startingTime_;
        endingTime = endingTime_;
        phases = phases_;

        IERC20(saleTokenAddress).safeTransferFrom(msg.sender, address(this), maxSellingAmount);
    }

    /**
     * Used to blacklist users
     * @param user_  blacklisted user's address
     */
    function blacklist(address user_) external onlyOwner {
        isBlacklisted[user_] = true;
    }

    function removeBlacklist(address user_) external onlyOwner {
        isBlacklisted[user_] = false;
    }

    /**
     * Function called to buy tokens with a table coin
     * @param tokenUsedToBuy_  token's address
     * @param amount_  amount of tokens for buying
     */
    function buyWithStable(address tokenUsedToBuy_, uint256 amount_, uint256 minTokensOut_) external {
        if (isBlacklisted[msg.sender]) revert UserBlacklisted();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < startingTime) revert NotStarted();
        // forge-lint: disable-next-line(block-timestamp)
        if (endingTime < block.timestamp) revert SaleEnded();
        if (tokenUsedToBuy_ != usdtAddress && tokenUsedToBuy_ != usdcAddress) revert InvalidToken();

        _advancePhase();
        uint256 pricedPhase_ = currentPhase;
        uint256 tokenAmountToReceive;
        if (ERC20(tokenUsedToBuy_).decimals() == 18) {
            tokenAmountToReceive = amount_ * 1e6 / phases[currentPhase][1];
        } else {
            tokenAmountToReceive =
                amount_ * 10 ** (18 - ERC20(tokenUsedToBuy_).decimals()) * 1e6 / phases[currentPhase][1];
        }
        if (tokenAmountToReceive < minTokensOut_) revert SlippageExceeded();

        totalSold += tokenAmountToReceive;
        if (totalSold > maxSellingAmount) revert SoldOut();
        if (totalSold > phases[currentPhase][0]) revert PhaseCapExceeded();
        _advancePhase();

        // Increment user's balance
        userTokenBalance[msg.sender] += tokenAmountToReceive;

        // Transfer selling tokens
        IERC20(tokenUsedToBuy_).safeTransferFrom(msg.sender, fundsReceiverAddress, amount_);

        emit TokenPurchased(msg.sender, tokenUsedToBuy_, amount_, tokenAmountToReceive, pricedPhase_);
    }

    function buyWithEther(uint256 minTokensOut_) external payable {
        if (isBlacklisted[msg.sender]) revert UserBlacklisted();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < startingTime) revert NotStarted();
        // forge-lint: disable-next-line(block-timestamp)
        if (endingTime < block.timestamp) revert SaleEnded();

        _advancePhase();
        uint256 pricedPhase_ = currentPhase;
        uint256 usdValue = msg.value * getEtherPrice() / 1e18;
        uint256 tokenAmountToReceive = usdValue * 1e6 / phases[currentPhase][1];
        if (tokenAmountToReceive < minTokensOut_) revert SlippageExceeded();

        totalSold += tokenAmountToReceive;
        if (totalSold > maxSellingAmount) revert SoldOut();
        if (totalSold > phases[currentPhase][0]) revert PhaseCapExceeded();
        _advancePhase();

        // Increment user's balance
        userTokenBalance[msg.sender] += tokenAmountToReceive;

        (bool success,) = fundsReceiverAddress.call{value: msg.value}("");
        require(success, TransferFailed());

        emit TokenPurchased(msg.sender, address(0), msg.value, tokenAmountToReceive, pricedPhase_);
    }

    function claim() external {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < endingTime) revert NotEnded();

        uint256 amount = userTokenBalance[msg.sender];
        delete userTokenBalance[msg.sender];
        totalClaimed += amount;

        IERC20(saleTokenAddress).safeTransfer(msg.sender, amount);

        emit TokenClaimed(msg.sender, amount);
    }

    function emergencyERC20Withdraw(address tokenAddress_, uint256 amount_) external onlyOwner {
        if (tokenAddress_ == saleTokenAddress) {
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp <= endingTime) revert NotEnded();

            uint256 owed_ = totalSold - totalClaimed;
            uint256 surplus_ = IERC20(tokenAddress_).balanceOf(address(this)) - owed_;
            if (amount_ > surplus_) revert AmountExceedsSurplus();
        }
        IERC20(tokenAddress_).safeTransfer(msg.sender, amount_);
    }

    function emergencyETHWithdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        (bool success,) = msg.sender.call{value: balance}("");
        require(success, TransferFailed());
    }

    function getEtherPrice() public view returns (uint256) {
        IAggregator feed_ = IAggregator(dataFeedAddress);
        (, int256 price,, uint256 updatedAt,) = IAggregator(dataFeedAddress).latestRoundData();
        if (price <= 0) revert InvalidPrice();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > updatedAt + maxPriceAge) revert StalePrice();
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint256(price) * 1e18) / 10 ** feed_.decimals();
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function _advancePhase() private {
        // forge-lint: disable-start(block-timestamp)
        while (
            currentPhase < 2 && (block.timestamp >= phases[currentPhase][2] || totalSold >= phases[currentPhase][0])
        ) {
            currentPhase++;
        }
        // forge-lint: disable-end(block-timestamp)
    }
}
