import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { expect } from "chai";
import { ethers } from "hardhat";

import { Factory, ERC20 } from "../typechain";

import { multiDeploy } from "./utils";

describe("Factory", () => {
  let factory: Factory;

  let owner: SignerWithAddress;
  let treasury: SignerWithAddress;
  let alice: SignerWithAddress;

  let tokenA: ERC20;
  let tokenB: ERC20;

  beforeEach(async () => {
    [[owner, treasury, alice], [factory, tokenA, tokenB]] = await Promise.all([
      ethers.getSigners(),
      multiDeploy(
        ["Factory", "ERC20", "ERC20"],
        [[], ["TokenA", "TA"], ["TokenB", "TB"]]
      ),
    ]);
  });

  it("sets the deployer as the governor", async () => {
    expect(await factory.governor()).to.be.equal(owner.address);
  });

  it("returns the total number of pairs deployyed by the factory", async () => {
    expect(await factory.allPairsLength()).to.be.equal(0);
    await factory.createPair(tokenA.address, tokenB.address, false);
    expect(await factory.allPairsLength()).to.be.equal(1);
    await factory.createPair(tokenA.address, tokenB.address, true);
    expect(await factory.allPairsLength()).to.be.equal(2);
  });

  it("returns the hash of the creation code of the Pair contract", async () => {
    const pairContract = await ethers.getContractFactory("Pair");
    const hash = ethers.utils.solidityKeccak256(
      ["bytes"],
      [pairContract.bytecode]
    );

    expect(await factory.pairCodeHash()).to.be.equal(hash);
  });

  describe("function: setFeeTo", () => {
    it("reverts if it is not called by the governor", async () => {
      await expect(
        factory.connect(alice).setFeeTo(owner.address)
      ).to.be.revertedWith("Factory: Unauthorized");
    });
    it("sets a new feeTo address", async () => {
      expect(await factory.feeTo()).to.be.equal(ethers.constants.AddressZero);
      await expect(factory.connect(owner).setFeeTo(treasury.address))
        .to.emit(factory, "NewTreasury")
        .withArgs(ethers.constants.AddressZero, treasury.address);

      expect(await factory.feeTo()).to.be.equal(treasury.address);
    });
  });

  describe("function: setGovernor", () => {
    it("reverts if it is not called by the governor", async () => {
      await expect(
        factory.connect(alice).setGovernor(alice.address)
      ).to.be.revertedWith("Factory: Unauthorized");
    });
    it("reverts if the new governor is the zero address", async () => {
      await Promise.all([
        expect(
          factory.connect(owner).setGovernor(ethers.constants.AddressZero)
        ).to.be.revertedWith("Factory: Unauthorized"),
        expect(
          factory.connect(alice).setGovernor(ethers.constants.AddressZero)
        ).to.be.revertedWith("Factory: Unauthorized"),
      ]);
    });
    it("sets a new governor", async () => {
      expect(await factory.governor()).to.be.equal(owner.address);
      await expect(factory.connect(owner).setGovernor(alice.address))
        .to.emit(factory, "NewGovernor")
        .withArgs(owner.address, alice.address);

      expect(await factory.governor()).to.be.equal(alice.address);
    });
  });

  describe("function: createPair", () => {
    it("reverts if you pass invalid data or pair has been deployed already", async () => {
      await Promise.all([
        expect(
          factory.createPair(
            tokenA.address,
            ethers.constants.AddressZero,
            false
          )
        ).to.be.revertedWith("Factory: Zero address"),
        expect(
          factory.createPair(
            ethers.constants.AddressZero,
            tokenA.address,
            false
          )
        ).to.be.revertedWith("Factory: Zero address"),
        expect(
          factory.createPair(tokenA.address, tokenA.address, false)
        ).to.be.revertedWith("Factory: Invalid"),
      ]);

      await factory.createPair(tokenA.address, tokenB.address, false);

      await expect(
        factory.createPair(tokenA.address, tokenB.address, false)
      ).to.be.revertedWith("Factory: Already deployed");
    });

    it("deploys a new pair", async () => {
      const pairContract = await ethers.getContractFactory("Pair");

      const [token0, token1] =
        tokenA.address > tokenB.address
          ? [tokenB.address, tokenA.address]
          : [tokenA.address, tokenB.address];

      const initCodeHash = ethers.utils.solidityKeccak256(
        ["bytes"],
        [pairContract.bytecode]
      );
      const salt = ethers.utils.solidityKeccak256(
        ["bytes"],
        [
          ethers.utils.solidityPack(
            ["address", "address", "bool"],
            [token0, token1, false]
          ),
        ]
      );
      const predictedAddress = ethers.utils.getCreate2Address(
        factory.address,
        salt,
        initCodeHash
      );
      const [pairsLength, isPair, getPairA, getPairB] = await Promise.all([
        factory.allPairsLength(),
        factory.isPair(predictedAddress),
        factory.getPair(tokenA.address, tokenB.address, false),
        factory.getPair(tokenB.address, tokenA.address, false),
      ]);

      expect(pairsLength).to.be.equal(0);
      expect(isPair).to.be.equal(false);
      expect(getPairA).to.be.equal(ethers.constants.AddressZero);
      expect(getPairB).to.be.equal(ethers.constants.AddressZero);

      await expect(factory.createPair(tokenA.address, tokenB.address, false))
        .to.emit(factory, "PairCreated")
        .withArgs(token0, token1, false, predictedAddress, 1);

      const [pairsLength2, isPair2, getPairA2, getPairB2] = await Promise.all([
        factory.allPairsLength(),
        factory.isPair(predictedAddress),
        factory.getPair(tokenA.address, tokenB.address, false),
        factory.getPair(tokenB.address, tokenA.address, false),
      ]);

      expect(pairsLength2).to.be.equal(1);
      expect(isPair2).to.be.equal(true);
      expect(getPairA2).to.be.equal(predictedAddress);
      expect(getPairB2).to.be.equal(predictedAddress);
    });
  });
});
