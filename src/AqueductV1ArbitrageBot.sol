// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./libraries/FullMath.sol";
import "./libraries/TickBitmap.sol";
import "./libraries/TickMath.sol";
import "./libraries/SqrtPriceMath.sol";

import "./interfaces/IAqueductV1Pair.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/ISuperToken.sol";
import "./interfaces/IAqueductV1Router.sol";
import "./interfaces/IAqueductV1ArbitrageBot.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/ISwapRouter.sol";

contract AqueductV1ArbitrageBot is IAqueductV1ArbitrageBot {
    // main state
    address public owner;
    IAqueductV1Pair public aqueductPool;
    IAqueductV1Router public aqueductRouter;
    IUniswapV3Pool public externalPool;
    ISwapRouter public externalRouter;
    IUniswapV3Pool public flashPool;
    uint24 public constant aqueductFee = 997000;
    uint256 minProfitA;
    uint256 minProfitB;

    // while both v2 and v3 sort tokens by address, aqueduct uses supertokens which will have different addresses
    // if a1=a2 and b1=b2, then reverseAqueductTokens=false, otherwise true
    bool public reverseAqueductTokens;

    // misc
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    constructor(address _owner) {
        owner = _owner;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "revert: only owner");
        _;
    }

    /*
        State changes
    */

    function setOwner(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    function setAqueductPool(IAqueductV1Pair poolAddress) external onlyOwner {
        aqueductPool = poolAddress;

        // go ahead and approve max amount for both supertokens
        ISuperToken tokenA = aqueductPool.token0();
        IERC20(tokenA.getUnderlyingToken()).approve(address(tokenA), type(uint256).max);
        ISuperToken tokenB = aqueductPool.token1();
        IERC20(tokenB.getUnderlyingToken()).approve(address(tokenB), type(uint256).max);

        // approve max amount for the router also
        tokenA.approve(address(aqueductRouter), type(uint256).max);
        tokenB.approve(address(aqueductRouter), type(uint256).max);
    }

    function setAqueductRouter(IAqueductV1Router routerAddress) external onlyOwner {
        aqueductRouter = routerAddress;
    }

    function setExternalRouter(ISwapRouter routerAddress) external onlyOwner {
        externalRouter = routerAddress;
    }

    function setExternalPool(IUniswapV3Pool poolAddress) external onlyOwner {
        externalPool = poolAddress;

        // approve max amount for the router
        IERC20(externalPool.token0()).approve(address(externalRouter), type(uint256).max);
        IERC20(externalPool.token1()).approve(address(externalRouter), type(uint256).max);
    }

    function setFlashPool(IUniswapV3Pool poolAddress) external onlyOwner {
        flashPool = poolAddress;
    }

    function setReverseAqueductTokens(bool value) external onlyOwner {
        reverseAqueductTokens = value;
    }

    function setMinProfitA(uint256 minProfit) external onlyOwner {
        minProfitA = minProfit;
    }

    function setMinProfitB(uint256 minProfit) external onlyOwner {
        minProfitB = minProfit;
    }

    function retrieveTokens(IERC20 token, uint256 amount, address to) external onlyOwner {
        token.transfer(to, amount);
    }

    /*
        Arb math and swapping
    */

    struct PoolState {
        uint160 startingSqrtPrice;
        int24 tickSpacing;
        uint24 v3Fee;
        uint112 a;
        uint112 b;
        // aqueduct tokens
        ISuperToken tokenA;
        ISuperToken tokenB;
        // external pool tokens
        IERC20 token0;
        IERC20 token1;
    }

    struct SwapState {
        uint256 sqrtABFee1Fee2;
        uint256 numeratorStep1;
        uint256 numerator;
        uint256 denominatorStep1;
        uint256 denominator;
        uint256 swapAmount;
        int24 nextTick;
        uint160 sqrtPriceNextX96;
        uint256 amountNeeded;
        int128 liquidityNet;
    }

    event Arbitrage(bool zeroForOne, uint256 swapAmount, uint256 balanceChange0, uint256 balanceChange1);

    // gelato will execute this function as long as it doesn't revert, so we just need this
    function swap() external {
        // get v3 pool state
        PoolState memory poolState;
        (poolState.startingSqrtPrice, , , , , , ) = externalPool.slot0();
        poolState.tickSpacing = externalPool.tickSpacing();
        poolState.v3Fee = 1000000 - externalPool.fee();
        poolState.token0 = IERC20(externalPool.token0());
        poolState.token1 = IERC20(externalPool.token1());

        // get initial balances
        uint256 startingBalanceA = poolState.token0.balanceOf(address(this));
        uint256 startingBalanceB = poolState.token1.balanceOf(address(this));

        // get aqueduct state
        poolState.tokenA;
        poolState.tokenB;
        if (reverseAqueductTokens) {
            (poolState.b, poolState.a, ) = aqueductPool.getReserves();
            poolState.tokenB = aqueductPool.token0();
            poolState.tokenA = aqueductPool.token1();
        } else {
            (poolState.a, poolState.b, ) = aqueductPool.getReserves();
            poolState.tokenA = aqueductPool.token0();
            poolState.tokenB = aqueductPool.token1();
        }

        // convert aqueduct state to underlying amounts
        poolState.a = toUnderlyingAmount(poolState.tokenA, poolState.a);
        poolState.b = toUnderlyingAmount(poolState.tokenB, poolState.b);

        // figure out swap direction
        bool zeroForOne;
        {
            // 1) convert aqueduct price to sqrtPriceX96
            uint256 aqPriceX96 = sqrt(((poolState.b * Q96) / poolState.a) * Q96);
            // if aqPriceX96 < startingSqrtPrice, swap a->b on v3, else swap b->a
            zeroForOne = aqPriceX96 < poolState.startingSqrtPrice;
        }

        // find profit maximizing trade
        uint256 totalSwapAmount;
        if (zeroForOne) {
            while (true) {
                SwapState memory s;

                // get current v3 pool state
                uint128 l = externalPool.liquidity();
                (uint160 p, int24 currentTick, , , , , ) = externalPool.slot0();

                // get current v2 pool state
                if (reverseAqueductTokens) {
                    (poolState.b, poolState.a, ) = aqueductPool.getReserves();
                } else {
                    (poolState.a, poolState.b, ) = aqueductPool.getReserves();
                }

                // convert v2 state to underlying token amounts
                poolState.a = toUnderlyingAmount(poolState.tokenA, poolState.a);
                poolState.b = toUnderlyingAmount(poolState.tokenB, poolState.b);

                // (a->b->a) v3 a->b, v2 b->a
                // swapAmount = amount of a to swap on v3
                s.sqrtABFee1Fee2 = sqrt(
                    multiplyByFee(multiplyByFee(uint256(poolState.a) * poolState.b, aqueductFee), poolState.v3Fee)
                );
                s.numeratorStep1 = FullMath.mulDiv(s.sqrtABFee1Fee2, p, Q96);

                // if the numerator is negative, the trade will not be profitable
                if (s.numeratorStep1 < poolState.b) break;

                s.numerator = s.numeratorStep1 - poolState.b;
                s.denominatorStep1 = FullMath.mulDiv(l, multiplyByFee(p, aqueductFee), Q96) + poolState.b;
                s.denominator = FullMath.mulDiv(multiplyByFee(p, poolState.v3Fee), s.denominatorStep1, Q96);
                s.swapAmount = FullMath.mulDiv(s.numerator, l, s.denominator);

                // get next tick
                (s.nextTick, ) = TickBitmap.nextInitializedTickWithinOneWord(
                    externalPool,
                    currentTick,
                    poolState.tickSpacing,
                    true // zeroForOne
                );

                // get sqrtprice at next tick
                s.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(s.nextTick);

                // get amount needed to reach next tick
                s.amountNeeded = SqrtPriceMath.getAmount0Delta(s.sqrtPriceNextX96, p, l, true);

                // if swapAmount surpasses the next tick, swap exactly amountNeeded, and repeat
                // otherwise, swap profit maximizing amount and break
                bool finalSwap = s.amountNeeded >= s.swapAmount;

                // use a flash loan to perfrom the arbitrage
                // the rest of the execution will be done in self.uniswapV3FlashCallback()
                uint256 effectiveSwapAmount = finalSwap ? s.swapAmount : s.amountNeeded;
                flashPool.flash(address(this), effectiveSwapAmount, 0, abi.encode(effectiveSwapAmount, true));

                totalSwapAmount += effectiveSwapAmount;

                if (finalSwap) break;
            }
        } else {
            while (true) {
                SwapState memory s;

                // get current v3 pool state
                uint128 l = externalPool.liquidity();
                (uint160 p, int24 currentTick, , , , , ) = externalPool.slot0();

                // get current v2 pool state
                if (reverseAqueductTokens) {
                    (poolState.b, poolState.a, ) = aqueductPool.getReserves();
                } else {
                    (poolState.a, poolState.b, ) = aqueductPool.getReserves();
                }

                // convert v2 state to underlying token amounts
                poolState.a = toUnderlyingAmount(poolState.tokenA, poolState.a);
                poolState.b = toUnderlyingAmount(poolState.tokenB, poolState.b);

                // (b->a->b) v3 b->a, v2 a->b
                // swapAmount = amount of b to swap on v3
                s.sqrtABFee1Fee2 = sqrt(
                    multiplyByFee(multiplyByFee(uint256(poolState.a) * poolState.b, aqueductFee), poolState.v3Fee)
                );
                s.numeratorStep1 = FullMath.mulDiv(s.sqrtABFee1Fee2, Q96, p);

                // if the numerator is negative, the trade will not be profitable
                if (s.numeratorStep1 < poolState.a) break;

                s.numerator = FullMath.mulDiv(s.sqrtABFee1Fee2, Q96, p) - poolState.a;
                s.denominatorStep1 = FullMath.mulDiv(multiplyByFee(l, aqueductFee), Q96, p) + poolState.a;
                s.denominator = FullMath.mulDiv(Q96, multiplyByFee(s.denominatorStep1, poolState.v3Fee), p);
                s.swapAmount = FullMath.mulDiv(s.numerator, l, s.denominator);

                // get next tick
                (s.nextTick, ) = TickBitmap.nextInitializedTickWithinOneWord(
                    externalPool,
                    currentTick,
                    poolState.tickSpacing,
                    false // zeroForOne
                );

                // get sqrtprice at next tick
                s.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(s.nextTick);

                // get amount needed to reach next tick
                s.amountNeeded = SqrtPriceMath.getAmount1Delta(p, s.sqrtPriceNextX96, l, true);

                // if swapAmount surpasses the next tick, swap exactly amountNeeded, and repeat
                // otherwise, swap profit maximizing amount and break
                bool finalSwap = s.amountNeeded >= s.swapAmount;

                // use a flash loan to perfrom the arbitrage
                // the rest of the execution will be done in self.uniswapV3FlashCallback()
                uint256 effectiveSwapAmount = finalSwap ? s.swapAmount : s.amountNeeded;
                flashPool.flash(address(this), 0, effectiveSwapAmount, abi.encode(effectiveSwapAmount, false));

                totalSwapAmount += effectiveSwapAmount;

                if (finalSwap) break;
            }
        }

        // get current balances
        uint256 newBalanceA = poolState.token0.balanceOf(address(this));
        uint256 newBalanceB = poolState.token1.balanceOf(address(this));

        // final sanity check
        if (
            (newBalanceA <= (startingBalanceA + minProfitA) || newBalanceB < startingBalanceB) &&
            (newBalanceB <= (startingBalanceB + minProfitB) || newBalanceA < startingBalanceA)
        ) {
            revert ARBITRAGE_NOT_PROFITABLE();
        }

        emit Arbitrage(zeroForOne, totalSwapAmount, newBalanceA - startingBalanceA, newBalanceB - startingBalanceB);
    }

    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) public {
        // can only be called from the v3 pool
        if (msg.sender != address(flashPool)) revert FLASH_LOAN_FORBIDDEN();

        // decode data
        (uint256 swapAmount, bool zeroForOne) = abi.decode(data, (uint256, bool));

        // get aqueduct state
        ISuperToken tokenA;
        ISuperToken tokenB;
        if (reverseAqueductTokens) {
            tokenB = aqueductPool.token0();
            tokenA = aqueductPool.token1();
        } else {
            tokenA = aqueductPool.token0();
            tokenB = aqueductPool.token1();
        }

        // swap a->b on v3 and b->a on aqueduct
        if (zeroForOne) {
            // swap on v3
            uint256 v3AmountOut = externalRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: externalPool.token0(),
                    tokenOut: externalPool.token1(),
                    fee: externalPool.fee(),
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
            aqueductRouter.swapExactTokensForTokens(
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
            uint256 v3AmountOut = externalRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: externalPool.token1(),
                    tokenOut: externalPool.token0(),
                    fee: externalPool.fee(),
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
            aqueductRouter.swapExactTokensForTokens(
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

    function toUnderlyingAmount(ISuperToken token, uint112 amount) private view returns (uint112 underlyingAmount) {
        uint8 underlyingDecimals = IERC20(token.getUnderlyingToken()).decimals();
        uint112 factor;
        if (underlyingDecimals < 18) {
            factor = uint112(10 ** (18 - underlyingDecimals));
            underlyingAmount = amount / factor;
        } else if (underlyingDecimals > 18) {
            factor = uint112(10 ** (underlyingDecimals - 18));
            underlyingAmount = amount * factor;
        } else {
            underlyingAmount = amount;
        }
    }

    /*
        Pure math
    */

    // multiplies input * fee
    // fee should be formatted as 1,000,000 - 100*bps (e.g. 0.3% fee --> 1,000,000 - 100*30 = 997000)
    function multiplyByFee(uint256 input, uint24 fee) internal pure returns (uint256) {
        return (input * fee) / 1000000;
    }

    // babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method)
    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
