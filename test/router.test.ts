import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { expect } from "chai";

import { ethers } from "hardhat";

import { Factory, Router, WBNB, ERC20, Pair } from "../typechain";

import { deploy, multiDeploy } from "./utils";

const { parseEther } = ethers.utils;

describe("Router", () => {
  let factory: Factory;
  let router: Router;
  let wbnb: WBNB;
  let volatilePair: Pair;

  let tokenA: ERC20;
  let tokenB: ERC20;

  let owner: SignerWithAddress;
  let alice: SignerWithAddress;

  beforeEach(async () => {
    [[owner, alice], [factory, tokenA, tokenB, wbnb]] = await Promise.all([
      ethers.getSigners(),
      multiDeploy(
        ["Factory", "ERC20", "ERC20", "WBNB"],
        [[], ["TokenA", "TA"], ["TokenB", "TB"], []]
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

    router = await deploy("Router", [factory.address, wbnb.address]);

    await Promise.all([
      tokenA.mint(alice.address, parseEther("10000")),
      tokenB.mint(alice.address, parseEther("5000")),
      tokenA
        .connect(alice)
        .approve(router.address, ethers.constants.MaxUint256),
      tokenB
        .connect(alice)
        .approve(router.address, ethers.constants.MaxUint256),
    ]);
  });

  it("sets the WBNB to the correct address", async () => {
    expect(await router.WBNB()).to.be.equal(wbnb.address);
  });

  describe("function: sortTokens", () => {
    it("reverts if the tokens are invalid", async () => {
      await Promise.all([
        expect(
          router.sortTokens(tokenA.address, tokenA.address)
        ).to.revertedWith("Router: Same address"),
        expect(
          router.sortTokens(tokenA.address, ethers.constants.AddressZero)
        ).to.revertedWith("Router: Zero address"),
        expect(
          router.sortTokens(ethers.constants.AddressZero, tokenB.address)
        ).to.revertedWith("Router: Zero address"),
      ]);
    });
    it("sorts tokens", async () => {
      const [token0, token1] = await router.sortTokens(
        tokenA.address,
        tokenB.address
      );

      expect(token0).to.be.equal(
        tokenA.address > tokenB.address ? tokenB.address : tokenA.address
      );
      expect(token1).to.be.equal(
        tokenA.address > tokenB.address ? tokenA.address : tokenB.address
      );
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
});
