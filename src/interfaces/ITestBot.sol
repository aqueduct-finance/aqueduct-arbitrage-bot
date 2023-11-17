// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface ITestBot {
    function swap(uint256 swapAmount, bool zeroForOne) external;
}