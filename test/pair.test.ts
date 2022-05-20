import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { expect } from "chai";
import { ethers, network } from "hardhat";

import { Pair, ERC20, Factory, ERC20Small, ERC20RMint } from "../typechain";

import {
  multiDeploy,
  sortTokens,
  getECSign,
  getPairDigest,
  getPairDomainSeparator,
  PRIVATE_KEYS,
  advanceBlockAndTime,
  deploy,
  sqrt,
  min,
} from "./utils";

const { parseEther } = ethers.utils;

const PERIOD_SIZE = 86400 / 12;

const MINIMUM_LIQUIDITY = ethers.BigNumber.from(1000);

describe("Pair", () => {
  let volatilePair: Pair;
  let factory: Factory;
  let tokenA: ERC20;
  let tokenB: ERC20;
  let tokenC: ERC20Small;

  let owner: SignerWithAddress;
  let alice: SignerWithAddress;
  let bob: SignerWithAddress;
  let treasury: SignerWithAddress;

  beforeEach(async () => {
    [[owner, alice, bob, treasury], [factory, tokenA, tokenB, tokenC]] =
      await Promise.all([
        ethers.getSigners(),
        multiDeploy(
          ["Factory", "ERC20", "ERC20", "ERC20Small"],
          [[], ["TokenA", "TA"], ["TokenB", "TB"], ["Small Token", "ST"]]
        ),
      ]);

    await factory.createPair(tokenA.address, tokenB.address, false);
    const volatilePairAddress = await factory.getPair(
      tokenA.address,
      tokenB.address,
      false
    );

    volatilePair = (await ethers.getContractFactory("Pair")).attach(
      volatilePairAddress
    );

    await Promise.all([
      tokenA.mint(alice.address, parseEther("1000")),
      tokenA.mint(bob.address, parseEther("1000")),
      tokenB.mint(alice.address, parseEther("500")),
      tokenB.mint(bob.address, parseEther("500")),
    ]);
  });

  it("sets the initial data correctly", async () => {
    await factory.createPair(tokenA.address, tokenC.address, true);
    const stablePairAddress = await factory.getPair(
      tokenA.address,
      tokenC.address,
      true
    );

    const stablePair = (await ethers.getContractFactory("Pair")).attach(
      stablePairAddress
    );

    const [token0Address] = sortTokens(tokenA.address, tokenC.address);

    const token0 = token0Address === tokenA.address ? tokenA : tokenC;
    const token1 = token0Address === tokenA.address ? tokenC : tokenA;

    const [
      sMetadata,
      vMetadata,
      observationLength,
      token0Decimals,
      token1Decimals,
      vFeesContract,
      sFeesContract,
    ] = await Promise.all([
      stablePair.metadata(),
      volatilePair.metadata(),
      stablePair.observationLength(),
      token0.decimals(),
      token1.decimals(),
      volatilePair.feesContract(),
      stablePair.feesContract(),
    ]);

    expect(observationLength).to.be.equal(12);
    expect(sMetadata[0]).to.be.equal(token0.address);
    expect(sMetadata[1]).to.be.equal(token1.address);
    expect(sMetadata[2]).to.be.equal(true);
    expect(vMetadata[2]).to.be.equal(false);
    expect(sMetadata[3]).to.be.equal(parseEther("0.0005"));
    expect(vMetadata[3]).to.be.equal(parseEther("0.003"));
    expect(sMetadata[6]).to.be.equal(
      ethers.BigNumber.from(10).pow(token0Decimals)
    );
    expect(sMetadata[7]).to.be.equal(
      ethers.BigNumber.from(10).pow(token1Decimals)
    );
    expect(vFeesContract > ethers.constants.AddressZero).to.be.equal(true);
    expect(sFeesContract > ethers.constants.AddressZero).to.be.equal(true);
  });

  describe("ERC20 functionality", () => {
    it("has all ERC20 metadata", async () => {
      await factory.createPair(tokenA.address, tokenB.address, true);
      const stablePairAddress = await factory.getPair(
        tokenA.address,
        tokenB.address,
        true
      );

      const stablePair = (await ethers.getContractFactory("Pair")).attach(
        stablePairAddress
      );

      const [token0Address] = sortTokens(tokenA.address, tokenB.address);

      const token0 = token0Address === tokenA.address ? tokenA : tokenB;
      const token1 = token0Address === tokenA.address ? tokenB : tokenA;

      const [
        decimals,
        vSymbol,
        vName,
        sName,
        sSymbol,
        token0Symbol,
        token1Symbol,
      ] = await Promise.all([
        volatilePair.decimals(),
        volatilePair.symbol(),
        volatilePair.name(),
        stablePair.name(),
        stablePair.symbol(),
        token0.symbol(),
        token1.symbol(),
      ]);

      expect(decimals).to.be.equal(18);
      expect(vSymbol).to.be.equal(`vILP-${token0Symbol}/${token1Symbol}`);
      expect(vName).to.be.equal(
        `Int Volatile LP - ${token0Symbol}/${token1Symbol}`
      );
      expect(sSymbol).to.be.equal(`sILP-${token0Symbol}/${token1Symbol}`);
      expect(sName).to.be.equal(
        `Int Stable LP - ${token0Symbol}/${token1Symbol}`
      );
    });

    it("allows users to give allowance to others", async () => {
      expect(
        await volatilePair.allowance(alice.address, bob.address)
      ).to.be.equal(0);

      await expect(volatilePair.connect(alice).approve(bob.address, 1000))
        .to.emit(volatilePair, "Approval")
        .withArgs(alice.address, bob.address, 1000);

      expect(
        await volatilePair.allowance(alice.address, bob.address)
      ).to.be.equal(1000);
    });

    it("allows users to transfer tokens", async () => {
      await Promise.all([
        tokenA.connect(alice).transfer(volatilePair.address, parseEther("100")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("50")),
      ]);

      await volatilePair.mint(alice.address);

      const [aliceBalance, bobBalance, totalSupply] = await Promise.all([
        volatilePair.balanceOf(alice.address),
        volatilePair.balanceOf(bob.address),
        volatilePair.totalSupply(),
      ]);

      expect(bobBalance).to.be.equal(0);
      // minimum balance
      expect(totalSupply).to.be.equal(aliceBalance.add(1000));

      await expect(
        volatilePair.connect(alice).transfer(bob.address, parseEther("10"))
      )
        .to.emit(volatilePair, "Transfer")
        .withArgs(alice.address, bob.address, parseEther("10"));

      const [aliceBalance2, bobBalance2] = await Promise.all([
        volatilePair.balanceOf(alice.address),
        volatilePair.balanceOf(bob.address),
      ]);

      expect(bobBalance2).to.be.equal(parseEther("10"));
      expect(aliceBalance2).to.be.equal(aliceBalance.sub(bobBalance2));

      await expect(
        volatilePair.connect(bob).transfer(alice.address, parseEther("10.01"))
      ).to.be.reverted;
    });

    it("allows a user to spend his/her allowance", async () => {
      await Promise.all([
        tokenA.connect(alice).transfer(volatilePair.address, parseEther("100")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("50")),
      ]);

      await volatilePair.mint(alice.address);

      await volatilePair.connect(alice).approve(bob.address, parseEther("10"));

      // overspend his allowance
      await expect(
        volatilePair
          .connect(bob)
          .transferFrom(alice.address, owner.address, parseEther("10.1"))
      ).to.be.reverted;

      const [aliceBalance, ownerBalance, bobAllowance] = await Promise.all([
        volatilePair.balanceOf(alice.address),
        volatilePair.balanceOf(owner.address),
        volatilePair.allowance(alice.address, bob.address),
      ]);

      expect(bobAllowance).to.be.equal(parseEther("10"));
      expect(ownerBalance).to.be.equal(0);

      await expect(
        volatilePair
          .connect(bob)
          .transferFrom(alice.address, owner.address, parseEther("10"))
      )
        .to.emit(volatilePair, "Transfer")
        .withArgs(alice.address, owner.address, parseEther("10"))
        .to.emit(volatilePair, "Approval")
        .withArgs(alice.address, bob.address, 0);

      const [aliceBalance2, ownerBalance2, bobAllowance2] = await Promise.all([
        volatilePair.balanceOf(alice.address),
        volatilePair.balanceOf(owner.address),
        volatilePair.allowance(alice.address, bob.address),
      ]);

      expect(bobAllowance2).to.be.equal(0);
      expect(ownerBalance2).to.be.equal(parseEther("10"));
      expect(aliceBalance2).to.be.equal(aliceBalance.sub(parseEther("10")));

      await volatilePair
        .connect(alice)
        .approve(bob.address, ethers.constants.MaxUint256);

      await expect(
        volatilePair
          .connect(bob)
          .transferFrom(alice.address, owner.address, parseEther("10"))
      ).to.not.emit(volatilePair, "Approval");

      const [aliceBalance3, ownerBalance3, bobAllowance3] = await Promise.all([
        volatilePair.balanceOf(alice.address),
        volatilePair.balanceOf(owner.address),
        volatilePair.allowance(alice.address, bob.address),
      ]);

      expect(bobAllowance3).to.be.equal(ethers.constants.MaxUint256);
      expect(ownerBalance3).to.be.equal(parseEther("10").add(ownerBalance2));
      expect(aliceBalance3).to.be.equal(aliceBalance2.sub(parseEther("10")));

      await expect(
        volatilePair
          .connect(alice)
          .transferFrom(alice.address, owner.address, parseEther("10"))
      ).to.not.emit(volatilePair, "Approval");

      const [aliceBalance4, ownerBalance4] = await Promise.all([
        volatilePair.balanceOf(alice.address),
        volatilePair.balanceOf(owner.address),
      ]);

      expect(ownerBalance4).to.be.equal(parseEther("10").add(ownerBalance3));
      expect(aliceBalance4).to.be.equal(aliceBalance3.sub(parseEther("10")));
    });

    it("reverts if the permit has expired", async () => {
      const blockTimestamp = await (
        await ethers.provider.getBlock(await ethers.provider.getBlockNumber())
      ).timestamp;

      await expect(
        volatilePair.permit(
          alice.address,
          bob.address,
          0,
          blockTimestamp - 1,
          0,
          ethers.constants.HashZero,
          ethers.constants.HashZero
        )
      ).to.revertedWith("Pair: Expired");
    });

    it("reverts if the recovered address is wrong", async () => {
      const chainId = network.config.chainId || 0;
      const name = await volatilePair.name();
      const domainSeparator = getPairDomainSeparator(
        volatilePair.address,
        name,
        chainId
      );

      const digest = getPairDigest(
        domainSeparator,
        alice.address,
        bob.address,
        parseEther("100"),
        0,
        1700587613
      );

      const { v, r, s } = getECSign(PRIVATE_KEYS[1], digest);

      const bobAllowance = await volatilePair.allowance(
        alice.address,
        bob.address
      );

      expect(bobAllowance).to.be.equal(0);

      await Promise.all([
        expect(
          volatilePair
            .connect(bob)
            .permit(
              owner.address,
              bob.address,
              parseEther("100"),
              1700587613,
              v,
              r,
              s
            )
        ).to.revertedWith("Pair: invalid signature"),
        expect(
          volatilePair
            .connect(bob)
            .permit(
              owner.address,
              bob.address,
              parseEther("100"),
              1700587613,
              0,
              ethers.constants.HashZero,
              ethers.constants.HashZero
            )
        ).to.revertedWith("Pair: invalid signature"),
      ]);
    });

    it("allows for permit call to give allowance", async () => {
      const chainId = network.config.chainId || 0;
      const name = await volatilePair.name();
      const domainSeparator = getPairDomainSeparator(
        volatilePair.address,
        name,
        chainId
      );

      const digest = getPairDigest(
        domainSeparator,
        alice.address,
        bob.address,
        parseEther("100"),
        0,
        1700587613
      );

      const { v, r, s } = getECSign(PRIVATE_KEYS[1], digest);

      const bobAllowance = await volatilePair.allowance(
        alice.address,
        bob.address
      );
      expect(bobAllowance).to.be.equal(0);

      await expect(
        volatilePair
          .connect(bob)
          .permit(
            alice.address,
            bob.address,
            parseEther("100"),
            1700587613,
            v,
            r,
            s
          )
      )
        .to.emit(volatilePair, "Approval")
        .withArgs(alice.address, bob.address, parseEther("100"));

      const bobAllowance2 = await volatilePair.allowance(
        alice.address,
        bob.address
      );
      expect(bobAllowance2).to.be.equal(parseEther("100"));
    });
  });

  it("returns the tokens sorted", async () => {
    const [token0Address] = sortTokens(tokenA.address, tokenB.address);

    const token0 = token0Address === tokenA.address ? tokenA : tokenB;
    const token1 = token0Address === tokenA.address ? tokenB : tokenA;

    const tokens = await volatilePair.tokens();

    expect(tokens[0]).to.be.equal(token0.address);
    expect(tokens[1]).to.be.equal(token1.address);
  });

  describe("Oracle functionality", () => {
    it("reverts if the first observation is stale", async () => {
      await expect(
        volatilePair.getTokenPrice(tokenA.address, parseEther("1"))
      ).to.revertedWith("Pair: Missing observation");
    });

    it("returns a TWAP", async () => {
      // * 1 Token A === 0.5 Token B
      // * 2 Token B === 2 Token A
      await Promise.all([
        tokenA.connect(alice).transfer(volatilePair.address, parseEther("500")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("250")),
      ]);

      await volatilePair.mint(alice.address);

      const amountOut = await volatilePair.getAmountOut(
        tokenA.address,
        parseEther("2")
      );

      await tokenA
        .connect(alice)
        .transfer(volatilePair.address, parseEther("2"));

      const amount0Out = tokenA.address > tokenB.address ? amountOut : 0;
      const amount1Out = tokenA.address > tokenB.address ? 0 : amountOut;

      await volatilePair
        .connect(alice)
        .swap(amount0Out, amount1Out, alice.address, []);

      await expect(
        volatilePair.getTokenPrice(tokenA.address, parseEther("1"))
      ).to.revertedWith("Pair: Missing observation");

      const advanceAndSwap = async () => {
        for (let i = 0; i < 13; i++) {
          await advanceBlockAndTime(PERIOD_SIZE + 1, ethers);

          const amountOut = await volatilePair.getAmountOut(
            tokenA.address,
            parseEther("1")
          );

          await tokenA
            .connect(alice)
            .transfer(volatilePair.address, parseEther("1"));

          const amount0Out = tokenA.address > tokenB.address ? amountOut : 0;
          const amount1Out = tokenA.address > tokenB.address ? 0 : amountOut;

          await volatilePair
            .connect(alice)
            .swap(amount0Out, amount1Out, alice.address, []);
        }
      };

      await advanceAndSwap();

      await network.provider.send("evm_setAutomine", [false]);

      const blockTimestamp = await (
        await ethers.provider.getBlock(await ethers.provider.getBlockNumber())
      ).timestamp;

      const [reserve0Cumulative, reserve1Cumulative] =
        await volatilePair.currentCumulativeReserves();

      const firstObservation = await volatilePair.getFirstObservationInWindow();

      const timeElapsed = ethers.BigNumber.from(blockTimestamp + 100).sub(
        firstObservation.timestamp
      );

      const reserve0 = reserve0Cumulative
        .sub(firstObservation.reserve0Cumulative)
        .div(timeElapsed);

      const reserve1 = reserve1Cumulative
        .sub(firstObservation.reserve1Cumulative)
        .div(timeElapsed);

      const reserveA = tokenA.address > tokenB.address ? reserve1 : reserve0;
      const reserveB = tokenA.address > tokenB.address ? reserve0 : reserve1;

      await network.provider.send("evm_increaseTime", [100]);

      const tx = volatilePair.getTokenPrice(tokenA.address, parseEther("1"));

      await network.provider.send("evm_mine");
      await network.provider.send("evm_setAutomine", [true]);

      const price = await tx;

      expect(price).to.be.closeTo(
        parseEther("1")
          .mul(reserveB)
          .div(reserveA.add(parseEther("1"))),
        parseEther("0.0001")
      );

      // * 86400 is the window size
      await advanceBlockAndTime(86400, ethers);

      await expect(
        volatilePair.getTokenPrice(tokenA.address, parseEther("1"))
      ).to.revertedWith("Pair: Missing observation");
    });
  });

  describe("function: mint", () => {
    it("reverts if you do not send enough liquidity", async () => {
      await expect(volatilePair.mint(alice.address)).to.reverted;

      await tokenA
        .connect(alice)
        .transfer(volatilePair.address, parseEther("12"));

      await expect(volatilePair.mint(alice.address)).to.reverted;

      await Promise.all([
        tokenA.connect(alice).transfer(volatilePair.address, parseEther("12")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("5")),
      ]);

      await volatilePair.mint(alice.address);

      tokenA.connect(alice).transfer(volatilePair.address, parseEther("12"));

      await expect(volatilePair.mint(alice.address)).to.revertedWith(
        "Pair: low liquidity"
      );
    });

    it("has a reentrancy guard", async () => {
      const brokenToken = (await deploy("ERC20RMint", [
        "Broken Token",
        "BT",
      ])) as ERC20RMint;

      await factory.createPair(tokenA.address, brokenToken.address, false);
      const pairAddress = await factory.getPair(
        tokenA.address,
        brokenToken.address,
        false
      );

      const brokenPair = (await ethers.getContractFactory("Pair")).attach(
        pairAddress
      );

      await brokenToken.mint(alice.address, parseEther("100"));

      await Promise.all([
        tokenA.connect(alice).transfer(brokenPair.address, parseEther("10")),
        brokenToken
          .connect(alice)
          .transfer(brokenPair.address, parseEther("10")),
      ]);

      await expect(brokenPair.mint(alice.address)).to.revertedWith(
        "Pair: Reentrancy"
      );
    });

    it.only("mints the right amount of LP tokens", async () => {
      const [aliceBalance, addressZeroBalance] = await Promise.all([
        volatilePair.balanceOf(alice.address),
        volatilePair.balanceOf(ethers.constants.AddressZero),
      ]);

      expect(aliceBalance).to.be.equal(0);
      expect(addressZeroBalance).to.be.equal(0);

      await Promise.all([
        tokenA.connect(alice).transfer(volatilePair.address, parseEther("100")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("50")),
      ]);

      const amount0 =
        tokenA.address > tokenB.address ? parseEther("50") : parseEther("100");
      const amount1 =
        tokenA.address > tokenB.address ? parseEther("100") : parseEther("50");

      await expect(volatilePair.mint(alice.address))
        .to.emit(volatilePair, "Mint")
        .withArgs(owner.address, amount0, amount1);

      const [aliceBalance2, addressZeroBalance2] = await Promise.all([
        volatilePair.balanceOf(alice.address),
        volatilePair.balanceOf(ethers.constants.AddressZero),
      ]);

      expect(aliceBalance2).to.be.equal(
        sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY)
      );
      expect(addressZeroBalance2).to.be.equal(MINIMUM_LIQUIDITY);

      await Promise.all([
        tokenA.connect(alice).transfer(volatilePair.address, parseEther("150")),
        tokenB.connect(alice).transfer(volatilePair.address, parseEther("100")),
      ]);

      const _amount0 =
        tokenA.address > tokenB.address ? parseEther("100") : parseEther("150");
      const _amount1 =
        tokenA.address > tokenB.address ? parseEther("150") : parseEther("100");

      await expect(volatilePair.mint(alice.address))
        .to.emit(volatilePair, "Mint")
        .withArgs(owner.address, _amount0, _amount1);

      const [aliceBalance3, addressZeroBalance3] = await Promise.all([
        volatilePair.balanceOf(alice.address),
        volatilePair.balanceOf(ethers.constants.AddressZero),
      ]);

      expect(aliceBalance3).to.be.equal(
        min(
          _amount0.mul(MINIMUM_LIQUIDITY.add(aliceBalance2)).div(amount0),
          _amount1.mul(MINIMUM_LIQUIDITY.add(aliceBalance2)).div(amount1)
        ).add(aliceBalance2)
      );
      expect(addressZeroBalance3).to.be.equal(MINIMUM_LIQUIDITY);
    });
  });
});
