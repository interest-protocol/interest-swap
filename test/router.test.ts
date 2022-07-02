import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { expect } from "chai";

import { ethers, network } from "hardhat";

import {
  Factory,
  Router,
  ERC20,
  Pair,
  BrokenBNBReceiver,
  WNT,
} from "../typechain";

import {
  deploy,
  min,
  multiDeploy,
  quoteLiquidity,
  sqrt,
  getPairDomainSeparator,
  getECSign,
  getPairDigest,
  PRIVATE_KEYS,
} from "./utils";

const { parseEther } = ethers.utils;

const MINIMUM_LIQUIDITY = ethers.BigNumber.from(1000);

describe("Router", () => {
  let factory: Factory;
  let router: Router;
  let wnt: WNT;
  let volatilePair: Pair;

  let tokenA: ERC20;
  let tokenB: ERC20;
  let tokenC: ERC20;

  let owner: SignerWithAddress;
  let alice: SignerWithAddress;

  beforeEach(async () => {
    [[owner, alice], [factory, tokenA, tokenB, tokenC, wnt]] =
      await Promise.all([
        ethers.getSigners(),
        multiDeploy(
          ["Factory", "ERC20", "ERC20", "ERC20", "WNT"],
          [[], ["TokenA", "TA"], ["TokenB", "TB"], ["TokenC", "TC"], []]
        ),
      ]);

    await factory.createPair(tokenA.address, tokenB.address, false);

    const pairAddress = await factory.getPair(
      tokenA.address,
      tokenB.address,
      false
    );

    volatilePair = (await ethers.getContractFactory("Pair")).attach(
      pairAddress
    );

    router = await deploy("Router", [factory.address, wnt.address]);

    await Promise.all([
      tokenA.mint(alice.address, parseEther("100000")),
      tokenB.mint(alice.address, parseEther("50000")),
      tokenC.mint(alice.address, parseEther("50000")),
      tokenA
        .connect(alice)
        .approve(router.address, ethers.constants.MaxUint256),
      tokenB
        .connect(alice)
        .approve(router.address, ethers.constants.MaxUint256),
      tokenC
        .connect(alice)
        .approve(router.address, ethers.constants.MaxUint256),
      volatilePair
        .connect(alice)
        .approve(router.address, ethers.constants.MaxUint256),
    ]);
  });

  const getTokenAWNTContract = async () => {
    const pairAddress = await router.pairFor(
      tokenA.address,
      wnt.address,
      false
    );

    await Promise.all([
      factory.createPair(tokenA.address, wnt.address, false),
      wnt.connect(alice).deposit({ value: parseEther("20") }),
    ]);

    const contract = (await ethers.getContractFactory("Pair")).attach(
      pairAddress
    );

    await contract
      .connect(alice)
      .approve(router.address, ethers.constants.MaxUint256);

    return contract;
  };

  it("sets the wnt to the correct address", async () => {
    expect(await router.WNT()).to.be.equal(wnt.address);
  });

  describe("function: sortTokens", () => {
    it("reverts if the tokens are invalid", async () => {
      await Promise.all([
        expect(
          router.sortTokens(tokenA.address, tokenA.address)
        ).to.revertedWith("Router__SameAddress()"),
        expect(
          router.sortTokens(tokenA.address, ethers.constants.AddressZero)
        ).to.revertedWith("Router__ZeroAddress()"),
        expect(
          router.sortTokens(ethers.constants.AddressZero, tokenB.address)
        ).to.revertedWith("Router__ZeroAddress()"),
      ]);
    });
    it("sorts tokens", async () => {
      const [token0, token1] = await router.sortTokens(
        tokenA.address,
        tokenB.address
      );

      const pairToken0 = await volatilePair.token0();
      const pairToken1 = await volatilePair.token1();

      expect(token0).to.be.equal(pairToken0);
      expect(token1).to.be.equal(pairToken1);
    });
  });

  it("returns the address for a pair even if it has not been deployed", async () => {
    const [vPair, sPair] = await Promise.all([
      router.pairFor(tokenA.address, tokenB.address, false),
      router.pairFor(tokenA.address, tokenB.address, true),
    ]);
    expect(vPair).to.be.equal(volatilePair.address);
    expect(sPair).to.not.be.equal(ethers.constants.AddressZero);
  });

  it("returns the volatile and stable addresses for a pair of tokens", async () => {
    await factory.createPair(tokenA.address, tokenB.address, true);
    const [addresses, stablePairAddress] = await Promise.all([
      router.getPairs(tokenA.address, tokenB.address),
      factory.getPair(tokenA.address, tokenB.address, true),
    ]);

    expect(addresses[0]).to.be.equal(volatilePair.address);
    expect(addresses[1]).to.be.equal(stablePairAddress);
  });

  it("returns and sorts a pair reserves", async () => {
    await Promise.all([
      tokenA.connect(alice).transfer(volatilePair.address, parseEther("1000")),
      tokenB.connect(alice).transfer(volatilePair.address, parseEther("500")),
    ]);

    await volatilePair.mint(alice.address);

    const [data, data2] = await Promise.all([
      router.getReserves(tokenA.address, tokenB.address, false),
      router.getReserves(tokenB.address, tokenA.address, false),
    ]);

    expect(data[0]).to.be.equal(parseEther("1000"));
    expect(data[1]).to.be.equal(parseEther("500"));

    expect(data2[0]).to.be.equal(parseEther("500"));
    expect(data2[1]).to.be.equal(parseEther("1000"));
  });

  describe("function: getAmountOut", () => {
    it("returns an 0 Amount if both pairs do not exist", async () => {
      const amount = await router.getAmountOut(
        1,
        tokenA.address,
        owner.address
      );

      expect(amount.stable).to.be.equal(false);
      expect(amount.amount).to.be.equal(0);
    });

    it("works properly if one of the pairs do not exist", async () => {
      await factory.createPair(tokenA.address, tokenC.address, true);

      const stablePairAddress = await factory.getPair(
        tokenA.address,
        tokenC.address,
        true
      );

      const stablePair = (await ethers.getContractFactory("Pair")).attach(
        stablePairAddress
      );

      await tokenC.mint(alice.address, parseEther("20000"));

      await Promise.all([
        tokenA
          .connect(alice)
          .transfer(volatilePair.address, parseEther("1000")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("500")),
        tokenA.connect(alice).transfer(stablePairAddress, parseEther("1000")),
        tokenC.connect(alice).transfer(stablePairAddress, parseEther("1000")),
      ]);

      await Promise.all([
        volatilePair.mint(alice.address),
        stablePair.mint(alice.address),
      ]);

      const [routerAmount, pairAmount, routerAmount2, pairAmount2] =
        await Promise.all([
          router.getAmountOut(parseEther("2"), tokenA.address, tokenB.address),
          volatilePair.getAmountOut(tokenA.address, parseEther("2")),
          router.getAmountOut(parseEther("2"), tokenC.address, tokenA.address),
          stablePair.getAmountOut(tokenC.address, parseEther("2")),
        ]);

      expect(routerAmount.amount).to.be.equal(pairAmount);
      expect(routerAmount.stable).to.be.equal(false);
      expect(routerAmount2.amount).to.be.equal(pairAmount2);
      expect(routerAmount2.stable).to.be.equal(true);
    });

    it("returns the amount that will incur less slippage", async () => {
      await factory.createPair(tokenA.address, tokenB.address, true);
      const stablePairAddress = await factory.getPair(
        tokenA.address,
        tokenB.address,
        true
      );
      await Promise.all([
        tokenA
          .connect(alice)
          .transfer(volatilePair.address, parseEther("1000")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("500")),
        tokenA.connect(alice).transfer(stablePairAddress, parseEther("1000")),
        tokenB.connect(alice).transfer(stablePairAddress, parseEther("1000")),
      ]);

      const stablePair = (await ethers.getContractFactory("Pair")).attach(
        stablePairAddress
      );

      await Promise.all([
        volatilePair.mint(alice.address),
        stablePair.mint(alice.address),
      ]);

      const [amount0, amount1, vAmount, sAmount] = await Promise.all([
        router.getAmountOut(parseEther("10"), tokenB.address, tokenA.address),
        router.getAmountOut(parseEther("10"), tokenA.address, tokenB.address),
        volatilePair.getAmountOut(tokenB.address, parseEther("10")),
        stablePair.getAmountOut(tokenA.address, parseEther("10")),
      ]);

      expect(amount0.amount).to.be.equal(vAmount);
      expect(amount0.stable).to.be.equal(false);
      expect(amount1.amount).to.be.equal(sAmount);
      expect(amount1.stable).to.be.equal(true);
    });
  });

  describe("function: getAmountsOut", () => {
    it("reverts if route is invalid", async () => {
      await Promise.all([
        expect(router.getAmountsOut(0, [])).to.revertedWith(
          "Router__InvalidPath()"
        ),
        expect(
          router.getAmountsOut(0, [
            { from: tokenA.address, to: tokenB.address },
          ])
        ).to.revertedWith("Router__ZeroAmount()"),
      ]);
    });

    it("returns first amount if the pair does not exist", async () => {
      const amounts = await router.getAmountsOut(parseEther("10"), [
        { from: alice.address, to: tokenA.address },
      ]);

      expect(amounts.length).to.be.equal(2);
      expect(amounts[0].amount).to.be.equal(parseEther("10"));
      expect(amounts[0].stable).to.be.equal(false);
      expect(amounts[1].amount).to.be.equal(0);
      expect(amounts[1].stable).to.be.equal(false);
    });

    it("returns the best price on a specific route", async () => {
      await Promise.all([
        factory.createPair(tokenB.address, tokenC.address, false),
        factory.createPair(tokenA.address, tokenC.address, false),
        factory.createPair(tokenA.address, tokenC.address, true),
      ]);

      const [vPairBCAddress, vPairACAddress, sPairACAddress] =
        await Promise.all([
          factory.getPair(tokenB.address, tokenC.address, false),
          factory.getPair(tokenA.address, tokenC.address, false),
          factory.getPair(tokenA.address, tokenC.address, true),
        ]);

      const pairContractFactory = await ethers.getContractFactory("Pair");

      const [vPairBC, vPairAC, sPairAC] = [
        pairContractFactory.attach(vPairBCAddress),
        pairContractFactory.attach(vPairACAddress),
        pairContractFactory.attach(sPairACAddress),
      ];

      await Promise.all([
        tokenA
          .connect(alice)
          .transfer(volatilePair.address, parseEther("1000")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("500")),
        tokenB.connect(alice).transfer(vPairBC.address, parseEther("300")),
        tokenC.connect(alice).transfer(vPairBC.address, parseEther("500")),
        tokenC.connect(alice).transfer(vPairAC.address, parseEther("1000")),
        tokenA.connect(alice).transfer(vPairAC.address, parseEther("300")),
        tokenC.connect(alice).transfer(sPairAC.address, parseEther("400")),
        tokenA.connect(alice).transfer(sPairAC.address, parseEther("400")),
      ]);

      await Promise.all([
        volatilePair.mint(alice.address),
        vPairBC.mint(alice.address),
        vPairAC.mint(alice.address),
        sPairAC.mint(alice.address),
      ]);

      const firstTradeOutput = await volatilePair.getAmountOut(
        tokenA.address,
        parseEther("10")
      );

      const secondTradeOutput = await vPairBC.getAmountOut(
        tokenB.address,
        firstTradeOutput
      );

      const thirdTradeOutput = await sPairAC.getAmountOut(
        tokenC.address,
        secondTradeOutput
      );

      const route = [
        { from: tokenA.address, to: tokenB.address },
        { from: tokenB.address, to: tokenC.address },
        { from: tokenC.address, to: tokenA.address },
      ];

      const [amountIn, firstTrade, secondTrade, thirdTrade] =
        await router.getAmountsOut(parseEther("10"), route);

      expect(amountIn.amount).to.be.equal(parseEther("10"));
      expect(amountIn.stable).to.be.equal(false);

      expect(firstTrade.amount).to.be.equal(firstTradeOutput);
      expect(firstTrade.stable).to.be.equal(false);

      expect(secondTrade.amount).to.be.equal(secondTradeOutput);
      expect(secondTrade.stable).to.be.equal(false);

      expect(thirdTrade.amount).to.be.equal(thirdTradeOutput);
      expect(thirdTrade.stable).to.be.equal(true);
    });
  });

  it("checks if it is a pair", async () => {
    expect(await router.isPair(volatilePair.address)).to.be.equal(true);
    expect(await router.isPair(alice.address)).to.be.equal(false);
  });

  describe("function: quoteAddLiquidity", () => {
    it("handles the case when there is no pair", async () => {
      const [
        [vAmountA, vAmountB, vLiquidity],
        [sAmountA, sAmountB, sLiquidity],
      ] = await Promise.all([
        router.quoteAddLiquidity(
          tokenA.address,
          tokenC.address,
          false,
          parseEther("300"),
          parseEther("500")
        ),
        router.quoteAddLiquidity(
          tokenA.address,
          tokenC.address,
          true,
          parseEther("300"),
          parseEther("500")
        ),
      ]);

      expect(vAmountA).to.be.equal(parseEther("300"));
      expect(vAmountB).to.be.equal(parseEther("500"));
      expect(vLiquidity).to.be.equal(
        sqrt(parseEther("300").mul(parseEther("500"))).sub(MINIMUM_LIQUIDITY)
      );

      expect(sAmountA).to.be.equal(parseEther("300"));
      expect(sAmountB).to.be.equal(parseEther("300"));
      expect(sLiquidity).to.be.equal(
        sqrt(parseEther("300").mul(parseEther("300"))).sub(MINIMUM_LIQUIDITY)
      );
    });

    it("reverts if the reserves are not balanced", async () => {
      await tokenA
        .connect(alice)
        .transfer(volatilePair.address, parseEther("1000"));

      await volatilePair.sync();

      await expect(
        router.quoteAddLiquidity(
          tokenA.address,
          tokenB.address,
          false,
          parseEther("1"),
          0
        )
      ).to.revertedWith("Router__NoLiquidity");
    });

    it("handles the case in which there is a pair already", async () => {
      await Promise.all([
        tokenA
          .connect(alice)
          .transfer(volatilePair.address, parseEther("1000")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("500")),
      ]);

      await volatilePair.mint(alice.address);

      const amountADesired = parseEther("22");

      const amountBOptimal = quoteLiquidity(
        amountADesired,
        parseEther("1000"),
        parseEther("500")
      );

      const [dataOne, dataTwo, totalSupply] = await Promise.all([
        router.quoteAddLiquidity(
          tokenA.address,
          tokenB.address,
          false,
          amountADesired,
          amountBOptimal.add(parseEther("1"))
        ),
        router.quoteAddLiquidity(
          tokenA.address,
          tokenB.address,
          false,
          amountADesired,
          amountBOptimal.sub(parseEther("1"))
        ),
        volatilePair.totalSupply(),
      ]);

      await expect(
        router.quoteAddLiquidity(
          tokenA.address,
          tokenB.address,
          false,
          0,
          amountBOptimal.sub(parseEther("1"))
        )
      ).to.revertedWith("Router__ZeroAmount()");

      expect(dataOne[0]).to.be.equal(amountADesired);
      expect(dataOne[1]).to.be.equal(amountBOptimal);
      expect(dataOne[2]).to.be.equal(
        min(
          amountADesired.mul(totalSupply).div(parseEther("1000")),
          amountBOptimal.mul(totalSupply).div(parseEther("500"))
        )
      );

      expect(dataTwo[0]).to.be.equal(
        quoteLiquidity(
          amountBOptimal.sub(parseEther("1")),
          parseEther("500"),
          parseEther("1000")
        )
      );
      expect(dataTwo[1]).to.be.equal(amountBOptimal.sub(parseEther("1")));
      expect(dataTwo[2]).to.be.equal(
        min(
          quoteLiquidity(
            amountBOptimal.sub(parseEther("1")),
            parseEther("500"),
            parseEther("1000")
          )
            .mul(totalSupply)
            .div(parseEther("1000")),
          amountBOptimal
            .sub(parseEther("1"))
            .mul(totalSupply)
            .div(parseEther("500"))
        )
      );
    });
  });

  describe("function: quoteRemoveLiquidity", () => {
    it("handles the case where the pair does not exist", async () => {
      const [amountA, amountB] = await router.quoteRemoveLiquidity(
        tokenA.address,
        tokenB.address,
        true,
        parseEther("100")
      );

      expect(amountA).to.be.equal(0);
      expect(amountB).to.be.equal(0);
    });

    it("calculates the correct amount of liquidity to receive", async () => {
      await Promise.all([
        tokenA.connect(alice).transfer(volatilePair.address, parseEther("890")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("450")),
      ]);

      await volatilePair.mint(alice.address);

      const totalSupply = await volatilePair.totalSupply();

      const [dataOne, dataTwo, dataThree] = await Promise.all([
        router.quoteRemoveLiquidity(
          tokenA.address,
          tokenB.address,
          false,
          totalSupply.div(9)
        ),
        router.quoteRemoveLiquidity(
          tokenA.address,
          tokenB.address,
          false,
          totalSupply.div(4)
        ),
        router.quoteRemoveLiquidity(
          tokenA.address,
          tokenB.address,
          false,
          totalSupply.div(3)
        ),
      ]);

      expect(dataOne[0]).to.be.equal(
        totalSupply.div(9).mul(parseEther("890")).div(totalSupply)
      );
      expect(dataOne[1]).to.be.equal(
        totalSupply.div(9).mul(parseEther("450")).div(totalSupply)
      );

      expect(dataTwo[0]).to.be.equal(
        totalSupply.div(4).mul(parseEther("890")).div(totalSupply)
      );
      expect(dataTwo[1]).to.be.equal(
        totalSupply.div(4).mul(parseEther("450")).div(totalSupply)
      );

      expect(dataThree[0]).to.be.equal(
        totalSupply.div(3).mul(parseEther("890")).div(totalSupply)
      );
      expect(dataThree[1]).to.be.equal(
        totalSupply.div(3).mul(parseEther("450")).div(totalSupply)
      );
    });
  });

  describe("function: addLiquidity", () => {
    it("will revert if the deadline has passed", async () => {
      const blockTimestamp = (
        await ethers.provider.getBlock(await ethers.provider.getBlockNumber())
      ).timestamp;

      await expect(
        router.addLiquidity(
          tokenA.address,
          tokenB.address,
          false,
          0,
          0,
          0,
          0,
          alice.address,
          blockTimestamp - 1
        )
      ).to.revertedWith("Router__Expired()");
    });

    it("reverts if the parameters are wrong", async () => {
      await Promise.all([
        expect(
          router.addLiquidity(
            tokenA.address,
            tokenB.address,
            false,
            0,
            0,
            1,
            1,
            alice.address,
            ethers.constants.MaxUint256
          )
        ).to.revertedWith("Router__InvalidAmountA()"),
        expect(
          router.addLiquidity(
            tokenA.address,
            tokenB.address,
            false,
            1,
            0,
            1,
            1,
            alice.address,
            ethers.constants.MaxUint256
          )
        ).to.revertedWith("Router__InvalidAmountB()"),
      ]);
    });

    it("creates a new pair if it does not exist", async () => {
      const pair1Address = await router.pairFor(
        tokenA.address,
        tokenB.address,
        true
      );

      const pair2Address = await router.pairFor(
        tokenA.address,
        tokenC.address,
        false
      );

      const p = expect(
        router
          .connect(alice)
          .addLiquidity(
            tokenA.address,
            tokenB.address,
            true,
            parseEther("500"),
            parseEther("501"),
            1,
            1,
            alice.address,
            ethers.constants.MaxUint256
          )
      )
        .to.emit(tokenA, "Transfer")
        .withArgs(alice.address, pair1Address, parseEther("500"))
        .to.emit(tokenB, "Transfer")
        .withArgs(alice.address, pair1Address, parseEther("500"));

      const p2 = expect(
        router
          .connect(alice)
          .addLiquidity(
            tokenA.address,
            tokenC.address,
            false,
            parseEther("500"),
            parseEther("600"),
            1,
            1,
            alice.address,
            ethers.constants.MaxUint256
          )
      )
        .to.emit(tokenA, "Transfer")
        .withArgs(alice.address, pair2Address, parseEther("500"))
        .to.emit(tokenC, "Transfer")
        .withArgs(alice.address, pair2Address, parseEther("600"));

      await Promise.all([p, p2]);
    });

    it("adds liquidity", async () => {
      await Promise.all([
        tokenA
          .connect(alice)
          .transfer(volatilePair.address, parseEther("1000")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("500")),
      ]);

      await volatilePair.mint(alice.address);

      const amountADesired = parseEther("22");

      const amountBOptimal = quoteLiquidity(
        amountADesired,
        parseEther("1000"),
        parseEther("500")
      );

      const fail1 = expect(
        router.addLiquidity(
          tokenA.address,
          tokenB.address,
          false,
          amountADesired,
          amountBOptimal.add(parseEther("2")),
          0,
          amountBOptimal.add(parseEther("1.1")),
          alice.address,
          ethers.constants.MaxUint256
        )
      ).to.be.revertedWith("Router__InsufficientAmountB()");

      const fail2 = expect(
        router.addLiquidity(
          tokenA.address,
          tokenB.address,
          false,
          quoteLiquidity(
            amountBOptimal.sub(parseEther("1")),
            parseEther("500"),
            parseEther("1000")
          ).add(parseEther("2")),
          amountBOptimal.sub(parseEther("1")),
          quoteLiquidity(
            amountBOptimal.sub(parseEther("1")),
            parseEther("500"),
            parseEther("1000")
          ).add(parseEther("1")),
          0,
          alice.address,
          ethers.constants.MaxUint256
        )
      ).to.be.revertedWith("Router__InsufficientAmountA()");

      await Promise.all([fail1, fail2]);

      const aliceBalance = await volatilePair.balanceOf(alice.address);

      await expect(
        router
          .connect(alice)
          .addLiquidity(
            tokenA.address,
            tokenB.address,
            false,
            amountADesired,
            amountBOptimal.add(parseEther("2")),
            0,
            0,
            alice.address,
            ethers.constants.MaxUint256
          )
      )
        .to.emit(tokenA, "Transfer")
        .withArgs(alice.address, volatilePair.address, amountADesired)
        .to.emit(tokenB, "Transfer")
        .withArgs(alice.address, volatilePair.address, amountBOptimal);

      const aliceBalance2 = await volatilePair.balanceOf(alice.address);

      expect(aliceBalance2.gt(aliceBalance)).to.be.equal(true);

      const amountAOptimal = quoteLiquidity(
        amountBOptimal.sub(parseEther("2")),
        parseEther("500"),
        parseEther("1000")
      );

      await expect(
        router
          .connect(alice)
          .addLiquidity(
            tokenA.address,
            tokenB.address,
            false,
            amountADesired,
            amountBOptimal.sub(parseEther("2")),
            0,
            0,
            alice.address,
            ethers.constants.MaxUint256
          )
      )
        .to.emit(tokenA, "Transfer")
        .withArgs(alice.address, volatilePair.address, amountAOptimal)
        .to.emit(tokenB, "Transfer")
        .withArgs(
          alice.address,
          volatilePair.address,
          amountBOptimal.sub(parseEther("2"))
        );

      expect(
        (await volatilePair.balanceOf(alice.address)).gt(aliceBalance2)
      ).to.be.equal(true);
    });
  });

  describe("function: addLiquidityNativeToken", () => {
    it("revert if the deadline has passed", async () => {
      await expect(
        router
          .connect(alice)
          .addLiquidityNativeToken(
            tokenA.address,
            false,
            parseEther("100"),
            0,
            0,
            alice.address,
            0
          )
      ).to.be.revertedWith("Router__Expired()");
    });

    it("reverts if the transferFrom fails", async () => {
      await expect(
        router.addLiquidityNativeToken(
          tokenA.address,
          false,
          ethers.constants.MaxUint256,
          0,
          0,
          alice.address,
          ethers.constants.MaxUint256,
          { value: parseEther("10") }
        )
      ).to.be.revertedWith("Router__TransferFromFailed()");
    });

    it("reverts if the recipient cannot receive WNT", async () => {
      const brokenBNBReceiver: BrokenBNBReceiver = await deploy(
        "BrokenBNBReceiver",
        []
      );

      const pair = await getTokenAWNTContract();

      await Promise.all([
        wnt.connect(alice).transfer(pair.address, parseEther("10")),
        tokenA.connect(alice).transfer(pair.address, parseEther("25")),
        tokenA
          .connect(alice)
          .transfer(brokenBNBReceiver.address, parseEther("3")),
      ]);

      await pair.mint(alice.address);

      const amountWNTOptimal = quoteLiquidity(
        parseEther("2"),
        parseEther("25"),
        parseEther("10")
      );

      await expect(
        brokenBNBReceiver
          .connect(alice)
          .addLiquidityBNB(
            router.address,
            tokenA.address,
            false,
            parseEther("2"),
            0,
            0,
            brokenBNBReceiver.address,
            ethers.constants.MaxUint256,
            { value: amountWNTOptimal.add(parseEther("1")) }
          )
      ).to.revertedWith("Router__NativeTokenTransferFailed()");
    });

    it("adds Native Token liquidity", async () => {
      const pair = await getTokenAWNTContract();

      expect(await pair.balanceOf(alice.address)).to.be.equal(0);

      await expect(
        router
          .connect(alice)
          .addLiquidityNativeToken(
            tokenA.address,
            false,
            parseEther("10"),
            0,
            0,
            alice.address,
            ethers.constants.MaxUint256,
            { value: parseEther("12") }
          )
      )
        .to.emit(wnt, "Transfer")
        .withArgs(router.address, pair.address, parseEther("12"))
        .to.emit(tokenA, "Transfer")
        .withArgs(alice.address, pair.address, parseEther("10"));

      expect((await pair.balanceOf(alice.address)).gt(0)).to.be.equal(true);
    });
  });

  describe("function: removeLiquidity", () => {
    it("revert if you it is past the deadline", async () => {
      const blockTimestamp = (
        await ethers.provider.getBlock(await ethers.provider.getBlockNumber())
      ).timestamp;

      await expect(
        router.removeLiquidity(
          tokenA.address,
          tokenB.address,
          false,
          0,
          0,
          0,
          alice.address,
          blockTimestamp - 1
        )
      ).to.revertedWith("Router__Expired()");
    });

    it("removes liquidity", async () => {
      await Promise.all([
        tokenA.connect(alice).transfer(volatilePair.address, parseEther("890")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("450")),
      ]);

      await volatilePair.mint(alice.address);

      const totalSupply = await volatilePair.totalSupply();
      const aliceBalance = totalSupply.sub(MINIMUM_LIQUIDITY);

      const amountA = aliceBalance
        .div(3)
        .mul(parseEther("890"))
        .div(totalSupply);

      const amountB = aliceBalance
        .div(3)
        .mul(parseEther("450"))
        .div(totalSupply);

      await Promise.all([
        expect(
          router
            .connect(alice)
            .removeLiquidity(
              tokenA.address,
              tokenB.address,
              false,
              aliceBalance.div(3),
              amountA.add(parseEther("1")),
              0,
              alice.address,
              ethers.constants.MaxUint256
            )
        ).to.revertedWith("Router__InsufficientAmountA()"),
        expect(
          router
            .connect(alice)
            .removeLiquidity(
              tokenA.address,
              tokenB.address,
              false,
              aliceBalance.div(3),
              0,
              amountB.add(parseEther("1")),
              alice.address,
              ethers.constants.MaxUint256
            )
        ).to.revertedWith("Router__InsufficientAmountB()"),
        expect(
          router
            .connect(alice)
            .removeLiquidity(
              tokenA.address,
              tokenB.address,
              false,
              aliceBalance.div(3),
              0,
              0,
              alice.address,
              ethers.constants.MaxUint256
            )
        )
          .to.emit(tokenA, "Transfer")
          .withArgs(volatilePair.address, alice.address, amountA)
          .to.emit(tokenB, "Transfer")
          .withArgs(volatilePair.address, alice.address, amountB),
      ]);
    });
  });

  describe("function: removeLiquidityNativeToken", () => {
    it("reverts if it is past the deadline", async () => {
      await expect(
        router.removeLiquidityNativeToken(
          tokenA.address,
          false,
          0,
          0,
          0,
          alice.address,
          0
        )
      ).to.revertedWith("Router__Expired()");
    });

    it("removes Native Token liquidity", async () => {
      const pair = await getTokenAWNTContract();

      await Promise.all([
        wnt.connect(alice).transfer(pair.address, parseEther("9")),
        tokenA.connect(alice).transfer(pair.address, parseEther("145")),
      ]);

      await pair.mint(alice.address);

      const totalSupply = await pair.totalSupply();
      const aliceBalance = totalSupply.sub(MINIMUM_LIQUIDITY);
      const aliceBNBBalance = await alice.getBalance();

      const amountA = aliceBalance
        .div(3)
        .mul(parseEther("145"))
        .div(totalSupply);

      const amountB = aliceBalance.div(3).mul(parseEther("9")).div(totalSupply);

      await expect(
        router
          .connect(alice)
          .removeLiquidityNativeToken(
            tokenA.address,
            false,
            aliceBalance.div(3),
            0,
            0,
            ethers.constants.AddressZero,
            ethers.constants.MaxUint256
          )
      ).to.revertedWith("Router__TransferFailed()");

      await expect(
        router
          .connect(alice)
          .removeLiquidityNativeToken(
            tokenA.address,
            false,
            aliceBalance.div(3),
            0,
            0,
            alice.address,
            ethers.constants.MaxUint256
          )
      )
        .to.emit(tokenA, "Transfer")
        .withArgs(router.address, alice.address, amountA);

      expect(await alice.getBalance()).to.be.closeTo(
        aliceBNBBalance.add(amountB),
        parseEther("0.1") // gas
      );
    });
  });

  describe("function: removeLiquidityWithPermit", () => {
    it("removes liquidity with  permit without max allowance", async () => {
      // make sure we have no allowance
      await volatilePair.connect(alice).approve(router.address, 0);

      const chainId = network.config.chainId || 0;
      const name = await volatilePair.name();
      const domainSeparator = getPairDomainSeparator(
        volatilePair.address,
        name,
        chainId
      );
      const blockTimestamp = (
        await ethers.provider.getBlock(await ethers.provider.getBlockNumber())
      ).timestamp;

      await Promise.all([
        tokenA.connect(alice).transfer(volatilePair.address, parseEther("890")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("450")),
      ]);

      await volatilePair.mint(alice.address);

      const totalSupply = await volatilePair.totalSupply();
      const aliceBalance = totalSupply.sub(MINIMUM_LIQUIDITY);

      const amountA = aliceBalance
        .div(3)
        .mul(parseEther("890"))
        .div(totalSupply);

      const amountB = aliceBalance
        .div(3)
        .mul(parseEther("450"))
        .div(totalSupply);

      const digest = getPairDigest(
        domainSeparator,
        alice.address,
        router.address,
        aliceBalance.div(3),
        0,
        blockTimestamp * 2
      );

      const { v, r, s } = getECSign(PRIVATE_KEYS[1], digest);

      await expect(
        router
          .connect(alice)
          .removeLiquidityWithPermit(
            tokenA.address,
            tokenB.address,
            false,
            aliceBalance.div(3),
            0,
            0,
            alice.address,
            blockTimestamp * 2,
            false,
            v,
            r,
            s
          )
      )
        .to.emit(tokenA, "Transfer")
        .withArgs(volatilePair.address, alice.address, amountA)
        .to.emit(tokenB, "Transfer")
        .withArgs(volatilePair.address, alice.address, amountB);

      expect(
        await volatilePair.allowance(alice.address, router.address)
      ).to.be.equal(0);
    });

    it("removes liquidity with  permit with max allowance", async () => {
      // make sure we have no allowance
      await volatilePair.connect(alice).approve(router.address, 0);

      const chainId = network.config.chainId || 0;
      const name = await volatilePair.name();
      const domainSeparator = getPairDomainSeparator(
        volatilePair.address,
        name,
        chainId
      );
      const blockTimestamp = (
        await ethers.provider.getBlock(await ethers.provider.getBlockNumber())
      ).timestamp;

      await Promise.all([
        tokenA.connect(alice).transfer(volatilePair.address, parseEther("890")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("450")),
      ]);

      await volatilePair.mint(alice.address);

      const totalSupply = await volatilePair.totalSupply();
      const aliceBalance = totalSupply.sub(MINIMUM_LIQUIDITY);

      const amountA = aliceBalance
        .div(3)
        .mul(parseEther("890"))
        .div(totalSupply);

      const amountB = aliceBalance
        .div(3)
        .mul(parseEther("450"))
        .div(totalSupply);

      const digest = getPairDigest(
        domainSeparator,
        alice.address,
        router.address,
        ethers.constants.MaxUint256,
        0,
        blockTimestamp * 2
      );

      const { v, r, s } = getECSign(PRIVATE_KEYS[1], digest);

      await expect(
        router
          .connect(alice)
          .removeLiquidityWithPermit(
            tokenA.address,
            tokenB.address,
            false,
            aliceBalance.div(3),
            0,
            0,
            alice.address,
            blockTimestamp * 2,
            true,
            v,
            r,
            s
          )
      )
        .to.emit(tokenA, "Transfer")
        .withArgs(volatilePair.address, alice.address, amountA)
        .to.emit(tokenB, "Transfer")
        .withArgs(volatilePair.address, alice.address, amountB);

      expect(
        await volatilePair.allowance(alice.address, router.address)
      ).to.be.equal(ethers.constants.MaxUint256);
    });
  });

  describe("function: removeLiquidityNativeTokenWithPermit", () => {
    it("removes liquidity with  permit without max allowance", async () => {
      const pair = await getTokenAWNTContract();

      // make sure we have no allowance
      await pair.connect(alice).approve(router.address, 0);

      const chainId = network.config.chainId || 0;
      const name = await pair.name();
      const domainSeparator = getPairDomainSeparator(
        pair.address,
        name,
        chainId
      );

      const blockTimestamp = (
        await ethers.provider.getBlock(await ethers.provider.getBlockNumber())
      ).timestamp;

      await Promise.all([
        tokenA.connect(alice).transfer(pair.address, parseEther("145")),
        wnt.connect(alice).transfer(pair.address, parseEther("12")),
      ]);

      await pair.mint(alice.address);

      const totalSupply = await pair.totalSupply();
      const aliceBalance = totalSupply.sub(MINIMUM_LIQUIDITY);

      const amountA = aliceBalance
        .div(3)
        .mul(parseEther("145"))
        .div(totalSupply);

      const amountB = aliceBalance
        .div(3)
        .mul(parseEther("12"))
        .div(totalSupply);

      const digest = getPairDigest(
        domainSeparator,
        alice.address,
        router.address,
        aliceBalance.div(3),
        0,
        blockTimestamp * 2
      );

      const { v, r, s } = getECSign(PRIVATE_KEYS[1], digest);

      const aliceBNBBalance = await alice.getBalance();

      await expect(
        router
          .connect(alice)
          .removeLiquidityNativeTokenWithPermit(
            tokenA.address,
            false,
            aliceBalance.div(3),
            0,
            0,
            alice.address,
            blockTimestamp * 2,
            false,
            v,
            r,
            s
          )
      )
        .to.emit(tokenA, "Transfer")
        .withArgs(router.address, alice.address, amountA);

      const [allowance2, aliceBNBBalance2] = await Promise.all([
        pair.allowance(alice.address, router.address),
        alice.getBalance(),
      ]);

      expect(allowance2).to.be.equal(0);
      expect(aliceBNBBalance2).to.be.closeTo(
        aliceBNBBalance.add(amountB),
        parseEther("0.1")
      );
    });

    it("removes liquidity with  permit with max allowance", async () => {
      const pair = await getTokenAWNTContract();

      // make sure we have no allowance
      await pair.connect(alice).approve(router.address, 0);

      const chainId = network.config.chainId || 0;
      const name = await pair.name();
      const domainSeparator = getPairDomainSeparator(
        pair.address,
        name,
        chainId
      );

      const blockTimestamp = (
        await ethers.provider.getBlock(await ethers.provider.getBlockNumber())
      ).timestamp;

      await Promise.all([
        tokenA.connect(alice).transfer(pair.address, parseEther("145")),
        wnt.connect(alice).transfer(pair.address, parseEther("12")),
      ]);

      await pair.mint(alice.address);

      const totalSupply = await pair.totalSupply();
      const aliceBalance = totalSupply.sub(MINIMUM_LIQUIDITY);

      const amountA = aliceBalance
        .div(3)
        .mul(parseEther("145"))
        .div(totalSupply);

      const amountB = aliceBalance
        .div(3)
        .mul(parseEther("12"))
        .div(totalSupply);

      const digest = getPairDigest(
        domainSeparator,
        alice.address,
        router.address,
        ethers.constants.MaxUint256,
        0,
        blockTimestamp * 2
      );

      const { v, r, s } = getECSign(PRIVATE_KEYS[1], digest);

      const aliceBNBBalance = await alice.getBalance();

      await expect(
        router
          .connect(alice)
          .removeLiquidityNativeTokenWithPermit(
            tokenA.address,
            false,
            aliceBalance.div(3),
            0,
            0,
            alice.address,
            blockTimestamp * 2,
            true,
            v,
            r,
            s
          )
      )
        .to.emit(tokenA, "Transfer")
        .withArgs(router.address, alice.address, amountA);

      const [allowance2, aliceBNBBalance2] = await Promise.all([
        pair.allowance(alice.address, router.address),
        alice.getBalance(),
      ]);

      expect(allowance2).to.be.equal(ethers.constants.MaxUint256);
      expect(aliceBNBBalance2).to.be.closeTo(
        aliceBNBBalance.add(amountB),
        parseEther("0.1")
      );
    });
  });

  describe("function: swapExactTokensForTokens", () => {
    it("reverts it is past the deadline", async () => {
      await expect(
        router.swapExactTokensForTokens(0, 0, [], alice.address, 0)
      ).to.revertedWith("Router__Expired()");
    });

    it("reverts if the min out is higher than possible amount", async () => {
      await Promise.all([
        tokenA.connect(alice).transfer(volatilePair.address, parseEther("890")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("450")),
      ]);

      await volatilePair.mint(alice.address);

      const firstSwapOutput = await volatilePair.getAmountOut(
        tokenA.address,
        parseEther("3")
      );

      await expect(
        router.swapExactTokensForTokens(
          parseEther("3"),
          firstSwapOutput.add(parseEther("0.1")),
          [{ from: tokenA.address, to: tokenB.address }],
          alice.address,
          ethers.constants.MaxUint256
        )
      ).to.revertedWith("Router__InsufficientOutput()");
    });

    it("swaps between the best possible price", async () => {
      const [pairFactory] = await Promise.all([
        ethers.getContractFactory("Pair"),
        factory.createPair(wnt.address, tokenA.address, false),
        factory.createPair(wnt.address, tokenB.address, false),
        factory.createPair(wnt.address, tokenB.address, true),
        wnt.connect(alice).deposit({ value: parseEther("30") }),
      ]);

      const [vwntTokenAAddress, vwntTokenBAddress, swntTokenBAddress] =
        await Promise.all([
          factory.getPair(wnt.address, tokenA.address, false),
          factory.getPair(wnt.address, tokenB.address, false),
          factory.getPair(wnt.address, tokenB.address, true),
        ]);

      const [vwntTokenA, vwntTokenB, swntTokenB] = [
        pairFactory.attach(vwntTokenAAddress),
        pairFactory.attach(vwntTokenBAddress),
        pairFactory.attach(swntTokenBAddress),
      ];

      await Promise.all([
        wnt.connect(alice).transfer(vwntTokenAAddress, parseEther("10")),
        tokenA.connect(alice).transfer(vwntTokenAAddress, parseEther("25")),
        wnt.connect(alice).transfer(vwntTokenBAddress, parseEther("10")),
        tokenB.connect(alice).transfer(vwntTokenBAddress, parseEther("6")),
        wnt.connect(alice).transfer(swntTokenBAddress, parseEther("10")),
        tokenB.connect(alice).transfer(swntTokenBAddress, parseEther("10")),
      ]);

      await Promise.all([
        vwntTokenA.mint(alice.address),
        vwntTokenB.mint(alice.address),
        swntTokenB.mint(alice.address),
      ]);

      const firstSwapOutput = await vwntTokenA.getAmountOut(
        tokenA.address,
        parseEther("2")
      );

      const secondSwapOutput = await swntTokenB.getAmountOut(
        wnt.address,
        firstSwapOutput
      );

      await expect(
        router.connect(alice).swapExactTokensForTokens(
          parseEther("2"),
          secondSwapOutput.sub(parseEther("0.1")),
          [
            { from: tokenA.address, to: wnt.address },
            { from: wnt.address, to: tokenB.address },
          ],
          alice.address,
          ethers.constants.MaxUint256
        )
      )
        .to.emit(tokenB, "Transfer")
        .withArgs(swntTokenB.address, alice.address, secondSwapOutput);
    });
  });

  describe("function: swapExactNativeTokenForTokens", () => {
    it("reverts if  the deadline has passed", async () => {
      await expect(
        router.swapExactNativeTokenForTokens(0, [], alice.address, 0)
      ).to.revertedWith("Router__Expired()");
    });

    it("reverts if first from is not wnt", async () => {
      await expect(
        router.swapExactNativeTokenForTokens(
          0,
          [{ from: tokenA.address, to: wnt.address }],
          alice.address,
          ethers.constants.MaxUint256
        )
      ).to.revertedWith("Router__InvalidRoute()");
    });

    it("finds best price", async () => {
      const [pairFactory] = await Promise.all([
        ethers.getContractFactory("Pair"),
        factory.createPair(wnt.address, tokenA.address, false),
        factory.createPair(wnt.address, tokenA.address, true),
        wnt.connect(alice).deposit({ value: parseEther("50") }),
      ]);

      const [vwntTokenAAddress, swntTokenAAddress] = await Promise.all([
        factory.getPair(wnt.address, tokenA.address, false),
        factory.getPair(wnt.address, tokenA.address, true),
      ]);

      const [vwntTokenA, swntTokenA] = [
        pairFactory.attach(vwntTokenAAddress),
        pairFactory.attach(swntTokenAAddress),
      ];

      await Promise.all([
        wnt.connect(alice).transfer(vwntTokenAAddress, parseEther("20")),
        tokenA.connect(alice).transfer(vwntTokenAAddress, parseEther("50")),
        wnt.connect(alice).transfer(swntTokenAAddress, parseEther("25")),
        tokenA.connect(alice).transfer(swntTokenAAddress, parseEther("25")),
        tokenA.connect(alice).transfer(volatilePair.address, parseEther("25")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("50")),
      ]);

      await Promise.all([
        vwntTokenA.mint(alice.address),
        volatilePair.mint(alice.address),
        swntTokenA.mint(alice.address),
      ]);

      const firstSwapOutput = await vwntTokenA.getAmountOut(
        wnt.address,
        parseEther("2")
      );

      const secondSwapOutput = await volatilePair.getAmountOut(
        tokenA.address,
        firstSwapOutput
      );

      await expect(
        router.connect(alice).swapExactNativeTokenForTokens(
          secondSwapOutput,
          [
            { from: wnt.address, to: tokenA.address },
            { from: tokenA.address, to: tokenB.address },
          ],
          alice.address,
          ethers.constants.MaxUint256,
          { value: parseEther("2") }
        )
      )
        .to.emit(tokenB, "Transfer")
        .withArgs(volatilePair.address, alice.address, secondSwapOutput);
    });

    it("reverts if the trade incurs too much slippage", async () => {
      const [pairFactory] = await Promise.all([
        ethers.getContractFactory("Pair"),
        factory.createPair(wnt.address, tokenA.address, false),
        wnt.connect(alice).deposit({ value: parseEther("30") }),
      ]);

      const vwntTokenAAddress = await factory.getPair(
        wnt.address,
        tokenA.address,
        false
      );

      const vwntTokenA = pairFactory.attach(vwntTokenAAddress);

      await Promise.all([
        wnt.connect(alice).transfer(vwntTokenAAddress, parseEther("10")),
        tokenA.connect(alice).transfer(vwntTokenAAddress, parseEther("25")),
        tokenA.connect(alice).transfer(volatilePair.address, parseEther("25")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("50")),
      ]);

      await Promise.all([
        vwntTokenA.mint(alice.address),
        volatilePair.mint(alice.address),
      ]);

      const firstSwapOutput = await vwntTokenA.getAmountOut(
        wnt.address,
        parseEther("2")
      );

      const secondSwapOutput = await volatilePair.getAmountOut(
        tokenA.address,
        firstSwapOutput
      );

      await expect(
        router.connect(alice).swapExactNativeTokenForTokens(
          secondSwapOutput.add(parseEther("0.1")),
          [
            { from: wnt.address, to: tokenA.address },
            { from: tokenA.address, to: tokenB.address },
          ],
          alice.address,
          ethers.constants.MaxUint256,
          { value: parseEther("2") }
        )
      ).to.revertedWith("Router__InsufficientOutput()");
    });
  });

  describe("function: swapExactTokensForNativeToken", () => {
    it("reverts if  the deadline has passed", async () => {
      await expect(
        router.swapExactTokensForNativeToken(0, 0, [], alice.address, 0)
      ).to.revertedWith("Router__Expired()");
    });

    it("reverts if the route does not end in wnt", async () => {
      await expect(
        router.swapExactTokensForNativeToken(
          0,
          0,
          [{ from: wnt.address, to: tokenA.address }],
          alice.address,
          ethers.constants.MaxUint256
        )
      ).to.revertedWith("Router__InvalidRoute()");
    });

    it("reverts if it incurs too much slippage", async () => {
      const [pairFactory] = await Promise.all([
        ethers.getContractFactory("Pair"),
        factory.createPair(wnt.address, tokenA.address, false),
        wnt.connect(alice).deposit({ value: parseEther("30") }),
      ]);

      const vwntTokenAAddress = await factory.getPair(
        wnt.address,
        tokenA.address,
        false
      );

      const vwntTokenA = pairFactory.attach(vwntTokenAAddress);

      await Promise.all([
        wnt.connect(alice).transfer(vwntTokenAAddress, parseEther("10")),
        tokenA.connect(alice).transfer(vwntTokenAAddress, parseEther("25")),
        tokenA.connect(alice).transfer(volatilePair.address, parseEther("25")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("50")),
      ]);

      await Promise.all([
        vwntTokenA.mint(alice.address),
        volatilePair.mint(alice.address),
      ]);

      const firstSwapOutput = await volatilePair.getAmountOut(
        tokenB.address,
        parseEther("2")
      );

      const secondSwapOutput = await vwntTokenA.getAmountOut(
        tokenA.address,
        firstSwapOutput
      );

      await expect(
        router.connect(alice).swapExactTokensForNativeToken(
          parseEther("2"),
          secondSwapOutput.add(parseEther("0.1")),
          [
            { from: tokenB.address, to: tokenA.address },
            { from: tokenA.address, to: wnt.address },
          ],
          alice.address,
          ethers.constants.MaxUint256
        )
      ).to.revertedWith("Router__InsufficientOutput()");
    });

    it("finds best price", async () => {
      const [pairFactory] = await Promise.all([
        ethers.getContractFactory("Pair"),
        factory.createPair(wnt.address, tokenA.address, false),
        factory.createPair(wnt.address, tokenA.address, true),
        wnt.connect(alice).deposit({ value: parseEther("50") }),
      ]);

      const [vwntTokenAAddress, swntTokenAAddress] = await Promise.all([
        factory.getPair(wnt.address, tokenA.address, false),
        factory.getPair(wnt.address, tokenA.address, true),
      ]);

      const [vwntTokenA, swntTokenA] = [
        pairFactory.attach(vwntTokenAAddress),
        pairFactory.attach(swntTokenAAddress),
      ];

      await Promise.all([
        wnt.connect(alice).transfer(vwntTokenAAddress, parseEther("20")),
        tokenA.connect(alice).transfer(vwntTokenAAddress, parseEther("50")),
        wnt.connect(alice).transfer(swntTokenAAddress, parseEther("25")),
        tokenA.connect(alice).transfer(swntTokenAAddress, parseEther("25")),
        tokenA.connect(alice).transfer(volatilePair.address, parseEther("25")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("50")),
      ]);

      await Promise.all([
        vwntTokenA.mint(alice.address),
        volatilePair.mint(alice.address),
        swntTokenA.mint(alice.address),
      ]);

      const firstSwapOutput = await volatilePair.getAmountOut(
        tokenB.address,
        parseEther("2")
      );

      const secondSwapOutput = await swntTokenA.getAmountOut(
        tokenA.address,
        firstSwapOutput
      );

      const aliceBalance = await alice.getBalance();

      await expect(
        router.connect(alice).swapExactTokensForNativeToken(
          parseEther("2"),
          secondSwapOutput,
          [
            { from: tokenB.address, to: tokenA.address },
            { from: tokenA.address, to: wnt.address },
          ],
          alice.address,
          ethers.constants.MaxUint256
        )
      ).to.not.reverted;

      expect(await alice.getBalance()).to.be.closeTo(
        aliceBalance.add(secondSwapOutput),
        parseEther("0.1") // fees
      );
    });
  });
});
