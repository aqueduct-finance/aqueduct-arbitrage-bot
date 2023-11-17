// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

//solhint-disable func-name-mixedcase

import "./ISuperToken.sol";

interface IAqueductV1Pair {
    function MINIMUM_LIQUIDITY() external pure returns (uint256);

    function factory() external view returns (address);

    function token0() external view returns (ISuperToken);

    function token1() external view returns (ISuperToken);

    function getRealTimeIncomingFlowRates() external view returns (uint96 totalFlow0, uint96 totalFlow1, uint32 time);

    function getStaticReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function getReservesAtTime(uint32 time) external view returns (uint112 reserve0, uint112 reserve1);

    function twap0CumulativeLast() external view returns (uint256);

    function twap1CumulativeLast() external view returns (uint256);

    function kLast() external view returns (uint256);

    function getRealTimeUserBalances(
        address user
    ) external view returns (uint256 balance0, uint256 balance1, uint256 time);

    function getUserBalancesAtTime(
        address user,
        uint32 time
    ) external view returns (uint256 balance0, uint256 balance1);

    function mint(address to) external returns (uint256 liquidity);

    function burn(address to) external returns (uint256 amount0, uint256 amount1);

    function swap(uint256 amount0Out, uint256 amount1Out, address to) external;

    function retrieveFunds(ISuperToken superToken) external returns (uint256 returnedBalance);

    function sync() external;
}
