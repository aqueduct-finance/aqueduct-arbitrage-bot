import { expect } from "chai";
import { BigNumber, constants as ethconst, Contract } from "ethers";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { IAqueductV1Router } from "../../typechain-types";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

const uniV3UsdcWethPoolFlashing = "0x04537F43f6adD7b1b60CAb199c7a910024eE0594"; // 0.01% fee
const uniV3UsdcWethPoolFlashing2 = "0x0e44cEb592AcFC5D3F09D996302eB4C499ff8c10"; // 0.3% fee
const uniV3UsdcWethPool = "0x45dDa9cb7c25131DF268515131f647d726f50608"; // 0.05% fee
const aqueductFactory = "0x69c9415FbD24b4E33b7EBF1D5eA74bDf8cf8c242";
const aqueductRouter = "0x851d9a260c0614cd72681b8003dc39A920F25319";
const externalRouter = "0xE592427A0AEce92De3Edee1F18E0157C05861564";
const usdcAddress = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174";
const usdcxAddress = "0xcaa7349cea390f89641fe306d93591f87595dc1f";
const wethAddress = "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619";
const wethxAddress = "0x27e1e4e6bc79d93032abef01025811b7e4727e85";

const whaleAddress = "0x5a58505a96D1dbf8dF91cB21B54419FC36e93fdE";

describe("AqueductV1ArbitrageBot", () => {
    async function fixture() {
        const [wallet] = await ethers.getSigners();

        // these libraries have to be compiled separately because they require a solidity version <0.8.0
        const FullMath = await ethers.getContractFactory("FullMathWrapper");
        const fullMath = await FullMath.deploy();
        const TickMath = await ethers.getContractFactory("TickMathWrapper");
        const tickMath = await TickMath.deploy();

        // link with FullMath library and deploy bot
        const Bot = await ethers.getContractFactory("AqueductV1ArbitrageBot", {
            libraries: {
                FullMath: fullMath.address,
                TickMath: tickMath.address,
            },
        });
        const bot = await Bot.deploy(whaleAddress);

        // deploy testing bot
        const TestBot = await ethers.getContractFactory("TestBot");
        const testBot = await TestBot.deploy(bot.address);

        // impersonate address
        await hre.network.provider.request({
            method: "hardhat_impersonateAccount",
            params: [whaleAddress],
        });
        const whaleSigner = await ethers.getSigner(whaleAddress);

        // get v3 pool
        const v3Pool = await ethers.getContractAt("IUniswapV3Pool", uniV3UsdcWethPool);

        // get aqueduct factory and router
        const aqFactory = await ethers.getContractAt("IAqueductV1Factory", aqueductFactory);
        const aqRouter = await ethers.getContractAt("IAqueductV1Router", aqueductRouter);

        // get tokens
        const usdcx = await ethers.getContractAt("ISuperToken", usdcxAddress);
        const wethx = await ethers.getContractAt("ISuperToken", wethxAddress);
        const usdc = await ethers.getContractAt("IERC20", usdcAddress);
        const weth = await ethers.getContractAt("IERC20", wethAddress);

        // deploy usdc/weth pool on aqueduct
        await aqFactory.connect(whaleSigner).createPair(usdcxAddress, wethxAddress);

        return { wallet, bot, testBot, v3Pool, whaleSigner, aqFactory, aqRouter, usdcx, wethx, usdc, weth };
    }

    async function supplyLiquidity(
        usdcAmount: BigNumber,
        wethAmount: BigNumber,
        aqRouter: IAqueductV1Router,
        whaleSigner: SignerWithAddress
    ) {
        // get tokens
        const usdcx = await ethers.getContractAt("ISuperToken", usdcxAddress);
        const wethx = await ethers.getContractAt("ISuperToken", wethxAddress);
        const usdc = await ethers.getContractAt("IERC20", usdcAddress);
        const weth = await ethers.getContractAt("IERC20", wethAddress);

        // supply liquidity
        await usdc.connect(whaleSigner).approve(usdcxAddress, ethers.constants.MaxUint256);
        await weth.connect(whaleSigner).approve(wethxAddress, ethers.constants.MaxUint256);
        await usdcx.connect(whaleSigner).upgrade(usdcAmount);
        await wethx.connect(whaleSigner).upgrade(wethAmount);
        await usdcx.connect(whaleSigner).approve(aqRouter.address, ethers.constants.MaxUint256);
        await wethx.connect(whaleSigner).approve(aqRouter.address, ethers.constants.MaxUint256);
        await aqRouter
            .connect(whaleSigner)
            .addLiquidity(
                usdcxAddress,
                wethxAddress,
                usdcAmount,
                wethAmount,
                0,
                0,
                whaleAddress,
                ethers.constants.MaxUint256
            );
    }

    // each test has three parts:
    // - assume we calculate some value swapAmount, which is the profit maximizing trade
    // 1) swap exactly the optimal amount to test that the test contract is working properly (check that same profit is made)
    // 2) swap some amount x less than swapAmount, and check that they profit is less than that when swapAmount is traded
    // 3) swap x greater than swapAmount, and check that they profit is less than that when swapAmount is traded
    //    both a and b should hold true

    it("optimal_swap_zeroForOne_sametick", async () => {
        const { bot, testBot, whaleSigner, aqFactory, usdc, usdcx, wethx, aqRouter } = await loadFixture(fixture);

        // supply liquidity
        const usdcAmount = BigNumber.from(10).pow(18).mul(2000);
        const wethAmount = BigNumber.from(10).pow(18);
        await supplyLiquidity(usdcAmount, wethAmount, aqRouter, whaleSigner);

        // config bot
        const v2UsdcWethPool = await aqFactory.getPair(usdcx.address, wethx.address);
        await bot.connect(whaleSigner).setAqueductRouter(aqueductRouter);
        await bot.connect(whaleSigner).setExternalRouter(externalRouter);
        await bot.connect(whaleSigner).setAqueductPool(v2UsdcWethPool);
        await bot.connect(whaleSigner).setExternalPool(uniV3UsdcWethPool);
        await bot.connect(whaleSigner).setFlashPool(uniV3UsdcWethPoolFlashing);
        await bot.connect(whaleSigner).setReverseAqueductTokens(true); // supertoken addresses cause tokens to be in reverse order
        // if we don't set them, min profit values will be 0 by default

        // take a snapshot, so that we can revert back to it
        const snapshot = await hre.network.provider.request({ method: "evm_snapshot" });

        // start by doing optimal swap
        const swapTx = await bot.swap();
        const swapReceipt = await swapTx.wait();
        let optimalParams = swapReceipt.events?.find((event) => event.event === "Arbitrage")?.args;
        expect(optimalParams).to.be.not.undefined; // make sure the 'Arbitrage' event was emitted
        optimalParams = optimalParams!;

        // test retrieving tokens
        const whaleStartingBalance = await usdc.balanceOf(whaleAddress);
        await bot.connect(whaleSigner).retrieveTokens(usdc.address, optimalParams.balanceChange0, whaleAddress);
        const whaleBalance = await usdc.balanceOf(whaleAddress);
        expect(whaleBalance.sub(whaleStartingBalance)).to.eq(optimalParams.balanceChange0);
        const botBalance = await usdc.balanceOf(bot.address);
        expect(botBalance).to.eq(BigNumber.from(0));

        // revert to snapshot and take a new one
        await hre.network.provider.request({ method: "evm_revert", params: [snapshot] });
        const snapshot2 = await hre.network.provider.request({ method: "evm_snapshot" });

        // test swapping the same amount to make sure the snapshot worked correctly and the test bot works
        const swapTx2 = await testBot.swap(optimalParams.swapAmount, optimalParams.zeroForOne);
        const swapReceipt2 = await swapTx2.wait();
        let swap2Params = swapReceipt2.events?.find((event) => event.event === "Swap")?.args;
        expect(swap2Params).to.be.not.undefined;
        swap2Params = swap2Params!;
        expect(swap2Params.balanceChange0).to.be.eq(optimalParams.balanceChange0);
        expect(swap2Params.balanceChange1).to.be.eq(optimalParams.balanceChange1);

        // revert to snapshot and take a new one
        await hre.network.provider.request({ method: "evm_revert", params: [snapshot2] });
        const snapshot3 = await hre.network.provider.request({ method: "evm_snapshot" });

        // test swapping slightly less
        const swapTx3 = await testBot.swap(parseInt(optimalParams.swapAmount) - 210000, optimalParams.zeroForOne);
        const swapReceipt3 = await swapTx3.wait();
        let swap3Params = swapReceipt3.events?.find((event) => event.event === "Swap")?.args;
        expect(swap3Params).to.be.not.undefined;
        swap3Params = swap3Params!;
        expect(swap3Params.balanceChange0).to.be.lt(optimalParams.balanceChange0);
        expect(swap3Params.balanceChange1).to.be.eq(optimalParams.balanceChange1);

        // revert to snapshot
        await hre.network.provider.request({ method: "evm_revert", params: [snapshot3] });

        // test swapping slightly more
        const swapTx4 = await testBot.swap(parseInt(optimalParams.swapAmount) + 1000, optimalParams.zeroForOne);
        const swapReceipt4 = await swapTx4.wait();
        let swap4Params = swapReceipt4.events?.find((event) => event.event === "Swap")?.args;
        expect(swap4Params).to.be.not.undefined;
        swap4Params = swap4Params!;
        expect(swap4Params.balanceChange0).to.be.lt(optimalParams.balanceChange0);
        expect(swap4Params.balanceChange1).to.be.eq(optimalParams.balanceChange1);
    });

    it("optimal_swap_oneForZero_sametick", async () => {
        const { bot, testBot, whaleSigner, aqFactory, weth, usdcx, wethx, aqRouter } = await loadFixture(fixture);

        // supply liquidity
        const usdcAmount = BigNumber.from(10).pow(18).mul(1950);
        const wethAmount = BigNumber.from(10).pow(18);
        await supplyLiquidity(usdcAmount, wethAmount, aqRouter, whaleSigner);

        // config bot
        const v2UsdcWethPool = await aqFactory.getPair(usdcx.address, wethx.address);
        await bot.connect(whaleSigner).setAqueductRouter(aqueductRouter);
        await bot.connect(whaleSigner).setExternalRouter(externalRouter);
        await bot.connect(whaleSigner).setAqueductPool(v2UsdcWethPool);
        await bot.connect(whaleSigner).setExternalPool(uniV3UsdcWethPool);
        await bot.connect(whaleSigner).setFlashPool(uniV3UsdcWethPoolFlashing);
        await bot.connect(whaleSigner).setReverseAqueductTokens(true); // supertoken addresses cause tokens to be in reverse order
        // if we don't set them, min profit values will be 0 by default

        // take a snapshot, so that we can revert back to it
        const snapshot = await hre.network.provider.request({ method: "evm_snapshot" });

        // start by doing optimal swap
        const swapTx = await bot.swap();
        const swapReceipt = await swapTx.wait();
        let optimalParams = swapReceipt.events?.find((event) => event.event === "Arbitrage")?.args;
        expect(optimalParams).to.be.not.undefined; // make sure the 'Arbitrage' event was emitted
        optimalParams = optimalParams!;

        // test retrieving tokens
        const whaleStartingBalance = await weth.balanceOf(whaleAddress);
        await bot.connect(whaleSigner).retrieveTokens(weth.address, optimalParams.balanceChange1, whaleAddress);
        const whaleBalance = await weth.balanceOf(whaleAddress);
        expect(whaleBalance.sub(whaleStartingBalance)).to.eq(optimalParams.balanceChange1);
        const botBalance = await weth.balanceOf(bot.address);
        expect(botBalance).to.eq(BigNumber.from(0));

        // revert to snapshot and take a new one
        await hre.network.provider.request({ method: "evm_revert", params: [snapshot] });
        const snapshot2 = await hre.network.provider.request({ method: "evm_snapshot" });

        // test swapping the same amount to make sure the snapshot worked correctly and the test bot works
        const swapTx2 = await testBot.swap(optimalParams.swapAmount, optimalParams.zeroForOne);
        const swapReceipt2 = await swapTx2.wait();
        let swap2Params = swapReceipt2.events?.find((event) => event.event === "Swap")?.args;
        expect(swap2Params).to.be.not.undefined;
        swap2Params = swap2Params!;
        expect(swap2Params.balanceChange0).to.be.eq(optimalParams.balanceChange0);
        expect(swap2Params.balanceChange1).to.be.eq(optimalParams.balanceChange1);

        // revert to snapshot and take a new one
        await hre.network.provider.request({ method: "evm_revert", params: [snapshot2] });
        const snapshot3 = await hre.network.provider.request({ method: "evm_snapshot" });

        // test swapping slightly less
        const swapTx3 = await testBot.swap(parseInt(optimalParams.swapAmount) - 100000000000, optimalParams.zeroForOne);
        const swapReceipt3 = await swapTx3.wait();
        let swap3Params = swapReceipt3.events?.find((event) => event.event === "Swap")?.args;
        expect(swap3Params).to.be.not.undefined;
        swap3Params = swap3Params!;
        expect(swap3Params.balanceChange0).to.be.eq(optimalParams.balanceChange0);
        expect(swap3Params.balanceChange1).to.be.lt(optimalParams.balanceChange1);

        // revert to snapshot
        await hre.network.provider.request({ method: "evm_revert", params: [snapshot3] });

        // test swapping slightly more
        const swapTx4 = await testBot.swap(parseInt(optimalParams.swapAmount) + 210000, optimalParams.zeroForOne);
        const swapReceipt4 = await swapTx4.wait();
        let swap4Params = swapReceipt4.events?.find((event) => event.event === "Swap")?.args;
        expect(swap4Params).to.be.not.undefined;
        swap4Params = swap4Params!;
        expect(swap4Params.balanceChange0).to.be.eq(optimalParams.balanceChange0);
        expect(swap4Params.balanceChange1).to.be.lt(optimalParams.balanceChange1);
    });
});
