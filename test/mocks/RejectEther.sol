// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

contract RejectEther {
    receive() external payable {
        revert();
    }
}
