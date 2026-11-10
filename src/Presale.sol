// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IAggregator.sol";

contract Presale is Ownable {
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
    uint256 public immutable maxPriceAge;
    mapping(address => bool) public isBlacklisted;
    mapping(address => uint256) public userTokenBalance;

    event TokenBuy(address user, uint256 amount);

    error IncorrectTimes();
    error UserBlacklisted();
    error NotStarted();
    error NotEnded();
    error InvalidToken();
    error SoldOut();
    error TransferFailed();
    error InvalidPrice();
    error StalePrice();

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

        if (startingTime >= endingTime) revert IncorrectTimes();
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
    function buyWithStable(address tokenUsedToBuy_, uint256 amount_) external {
        if (isBlacklisted[msg.sender]) revert UserBlacklisted();
        if (block.timestamp < startingTime || endingTime < block.timestamp) revert NotStarted();
        if (tokenUsedToBuy_ != usdtAddress && tokenUsedToBuy_ != usdcAddress) revert InvalidToken();

        uint256 tokenAmountToReceive;
        if (ERC20(tokenUsedToBuy_).decimals() == 18) {
            tokenAmountToReceive = amount_ * 1e6 / phases[currentPhase][1];
        } else {
            tokenAmountToReceive =
                amount_ * 10 ** (18 - ERC20(tokenUsedToBuy_).decimals()) * 1e6 / phases[currentPhase][1];
        }
        checkCurrentPhase(tokenAmountToReceive);

        totalSold += tokenAmountToReceive;
        if (totalSold > maxSellingAmount) revert SoldOut();

        // Increment user's balance
        userTokenBalance[msg.sender] += tokenAmountToReceive;

        // Transfer selling tokens
        IERC20(tokenUsedToBuy_).safeTransferFrom(msg.sender, fundsReceiverAddress, amount_);

        emit TokenBuy(msg.sender, tokenAmountToReceive);
    }

    function buyWithEther() external payable {
        if (isBlacklisted[msg.sender]) revert UserBlacklisted();
        if (block.timestamp < startingTime || endingTime < block.timestamp) revert NotStarted();

        uint256 usdValue = msg.value * getEtherPrice() / 1e18;
        uint256 tokenAmountToReceive = usdValue * 1e6 / phases[currentPhase][1];

        checkCurrentPhase(tokenAmountToReceive);

        totalSold += tokenAmountToReceive;
        if (totalSold > maxSellingAmount) revert SoldOut();

        // Increment user's balance
        userTokenBalance[msg.sender] += tokenAmountToReceive;

        (bool success,) = fundsReceiverAddress.call{value: msg.value}("");
        require(success, TransferFailed());

        emit TokenBuy(msg.sender, tokenAmountToReceive);
    }

    function claim() external {
        if (block.timestamp < endingTime) revert NotEnded();

        uint256 amount = userTokenBalance[msg.sender];
        delete userTokenBalance[msg.sender];

        IERC20(saleTokenAddress).safeTransfer(msg.sender, amount);
    }

    function emergencyERC20Withdraw(address tokenAddress_, uint256 amount_) external onlyOwner {
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

    function checkCurrentPhase(uint256 amount_) private returns (uint256 phase) {
        if (
            (totalSold + amount_ >= phases[currentPhase][0] || block.timestamp >= phases[currentPhase][2])
                && currentPhase < 2
        ) {
            currentPhase++;
        }
        phase = currentPhase;
    }
}
