import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { expect } from "chai";
import { ethers } from "hardhat";

import { Pair, ERC20, Factory, ERC20Small } from "../typechain";

import { multiDeploy, sortTokens } from "./utils";

const { parseEther } = ethers.utils;

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
  });
});
