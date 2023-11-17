// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./IAqueductV1Pair.sol";
import "./IAqueductV1Router.sol";
import "./IUniswapV3Pool.sol";
import "./ISwapRouter.sol";
import "./IERC20.sol";

interface IAqueductV1ArbitrageBot {
    error ARBITRAGE_NOT_PROFITABLE();

    error FLASH_LOAN_FORBIDDEN();

    function externalPool() external returns (IUniswapV3Pool);

    function externalRouter() external returns (ISwapRouter);

    function flashPool() external returns (IUniswapV3Pool);

    function reverseAqueductTokens() external returns (bool);

    function aqueductPool() external returns (IAqueductV1Pair);

    function aqueductRouter() external returns (IAqueductV1Router);

    function setOwner(address newOwner) external;

    function setAqueductPool(IAqueductV1Pair poolAddress) external;

    function setAqueductRouter(IAqueductV1Router routerAddress) external;

    function setExternalRouter(ISwapRouter routerAddress) external;

    function setExternalPool(IUniswapV3Pool poolAddress) external;

    function setReverseAqueductTokens(bool value) external;

    function setMinProfitA(uint256 minProfit) external;

    function setMinProfitB(uint256 minProfit) external;

    function swap() external;

    function retrieveTokens(IERC20 token, uint256 amount, address to) external;
}
