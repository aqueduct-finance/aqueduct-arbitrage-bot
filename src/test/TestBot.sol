// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "../libraries/TickMath.sol";

import "../interfaces/ISuperToken.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/ISwapRouter.sol";
import "../interfaces/IAqueductV1ArbitrageBot.sol";
import "../interfaces/ITestBot.sol";

contract TestBot is ITestBot {
    // main state
    IAqueductV1ArbitrageBot bot;

    constructor(IAqueductV1ArbitrageBot _bot) {
        bot = _bot;
    }

    event Swap(uint256 balanceChange0, uint256 balanceChange1);

    function swap(uint256 swapAmount, bool zeroForOne) external {
        IERC20 token0 = IERC20(bot.externalPool().token0());
        IERC20 token1 = IERC20(bot.externalPool().token1());

        // approve max amount for v3 router
        token0.approve(address(bot.externalRouter()), type(uint256).max);
        token1.approve(address(bot.externalRouter()), type(uint256).max);

        // get initial balances
        uint256 startingBalanceA = token0.balanceOf(address(this));
        uint256 startingBalanceB = token1.balanceOf(address(this));

        // find profit maximizing trade
        if (zeroForOne) {
            bot.flashPool().flash(address(this), swapAmount, 0, abi.encode(swapAmount, true));
        } else {
            bot.flashPool().flash(address(this), 0, swapAmount, abi.encode(swapAmount, false));
        }

        // get current balances
        uint256 newBalanceA = token0.balanceOf(address(this));
        uint256 newBalanceB = token1.balanceOf(address(this));

        emit Swap(newBalanceA - startingBalanceA, newBalanceB - startingBalanceB);
    }

    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) public {
        // decode data
        (uint256 swapAmount, bool zeroForOne) = abi.decode(data, (uint256, bool));

        // get aqueduct state
        ISuperToken tokenA;
        ISuperToken tokenB;
        if (bot.reverseAqueductTokens()) {
            tokenB = bot.aqueductPool().token0();
            tokenA = bot.aqueductPool().token1();
        } else {
            tokenA = bot.aqueductPool().token0();
            tokenB = bot.aqueductPool().token1();
        }

        // approve max amount for supertokens, and aqueduct router
        IERC20(tokenA.getUnderlyingToken()).approve(address(tokenA), type(uint256).max);
        IERC20(tokenB.getUnderlyingToken()).approve(address(tokenB), type(uint256).max);
        tokenA.approve(address(bot.aqueductRouter()), type(uint256).max);
        tokenB.approve(address(bot.aqueductRouter()), type(uint256).max);

        // swap a->b on v3 and b->a on aqueduct
        if (zeroForOne) {
            // swap on v3
            uint256 v3AmountOut = bot.externalRouter().exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: bot.externalPool().token0(),
                    tokenOut: bot.externalPool().token1(),
                    fee: bot.externalPool().fee(),
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: swapAmount,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
                })
            );

            // wrap b into supertokens
            tokenB.upgrade(toSupertokenAmount(tokenB, v3AmountOut));

            // swap on aqueduct
            address[] memory path = new address[](2);
            path[0] = address(tokenB);
            path[1] = address(tokenA);
            bot.aqueductRouter().swapExactTokensForTokens(
                tokenB.balanceOf(address(this)),
                0, // min amount out
                path,
                address(this),
                type(uint256).max // deadline
            );

            // unwrap a into underlying tokens (just unwrap whole balance)
            tokenA.downgrade(tokenA.balanceOf(address(this)));

            // return loan amount
            IERC20(tokenA.getUnderlyingToken()).transfer(msg.sender, swapAmount + fee0);
        }
        // swap b->a on v3 and a->b on aqueduct
        else {
            // swap on v3
            uint256 v3AmountOut = bot.externalRouter().exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: bot.externalPool().token1(),
                    tokenOut: bot.externalPool().token0(),
                    fee: bot.externalPool().fee(),
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: swapAmount,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
                })
            );

            // wrap a into supertokens
            tokenA.upgrade(toSupertokenAmount(tokenA, v3AmountOut));

            // swap on aqueduct
            address[] memory path = new address[](2);
            path[0] = address(tokenA);
            path[1] = address(tokenB);
            bot.aqueductRouter().swapExactTokensForTokens(
                tokenA.balanceOf(address(this)),
                0, // min amount out
                path,
                address(this),
                type(uint256).max // deadline
            );

            // unwrap b into underlying tokens (just unwrap whole balance)
            tokenB.downgrade(tokenB.balanceOf(address(this)));

            // return loan amount
            IERC20(tokenB.getUnderlyingToken()).transfer(msg.sender, swapAmount + fee1);
        }
    }

    function toSupertokenAmount(ISuperToken token, uint256 amount) private view returns (uint256 supertokenAmount) {
        uint8 underlyingDecimals = IERC20(token.getUnderlyingToken()).decimals();
        uint256 factor;
        if (underlyingDecimals < 18) {
            factor = 10 ** (18 - underlyingDecimals);
            supertokenAmount = amount * factor;
        } else if (underlyingDecimals > 18) {
            factor = 10 ** (underlyingDecimals - 18);
            supertokenAmount = amount / factor;
        } else {
            supertokenAmount = amount;
        }
    }
}
