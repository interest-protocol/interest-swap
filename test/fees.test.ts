import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { expect } from "chai";
import { ethers } from "hardhat";

import { Fees, ERC20 } from "../typechain";

import { multiDeploy, deploy } from "./utils";

const { parseEther } = ethers.utils;

describe("Fees Contract", () => {
  let fees: Fees;
  let token0: ERC20;
  let token1: ERC20;

  let owner: SignerWithAddress;
  let alice: SignerWithAddress;

  beforeEach(async () => {
    [token0, token1] = await multiDeploy(
      ["ERC20", "ERC20"],
      [
        ["TokenA", "TA"],
        ["TokenB", "TB"],
      ]
    );
    [[owner, alice], fees] = await Promise.all([
      ethers.getSigners(),
      deploy("Fees", [token0.address, token1.address]),
    ]);

    await Promise.all([
      token0.mint(fees.address, parseEther("100")),
      token1.mint(fees.address, parseEther("50")),
    ]);
  });

  describe("function: claimFor", () => {
    it("reverts if it is not called by the owner", async () => {
      await expect(
        fees.connect(alice).claimFor(alice.address, 1, 1)
      ).to.revertedWith("PairHelper: only the pair");
    });

    it("reverts if you try to send more than the contract balance", async () => {
      await expect(
        fees.connect(owner).claimFor(alice.address, parseEther("150"), 1)
      ).to.revertedWith("PairHelper: failed to transfer");
    });

    it("sends tokens to the recipient", async () => {
      const [aliceToken0Balance, aliceToken1Balance] = await Promise.all([
        token0.balanceOf(alice.address),
        token1.balanceOf(alice.address),
      ]);

      expect(aliceToken0Balance).to.be.equal(0);
      expect(aliceToken1Balance).to.be.equal(0);

      await expect(
        fees.connect(owner).claimFor(alice.address, parseEther("90"), 0)
      )
        .to.emit(token0, "Transfer")
        .withArgs(fees.address, alice.address, parseEther("90"));

      const [aliceToken0Balance2, aliceToken1Balance2] = await Promise.all([
        token0.balanceOf(alice.address),
        token1.balanceOf(alice.address),
      ]);

      expect(aliceToken0Balance2).to.be.equal(parseEther("90"));
      expect(aliceToken1Balance2).to.be.equal(0);

      await expect(
        fees.connect(owner).claimFor(alice.address, 0, parseEther("40"))
      )
        .to.emit(token1, "Transfer")
        .withArgs(fees.address, alice.address, parseEther("40"));

      const [aliceToken0Balance3, aliceToken1Balance3] = await Promise.all([
        token0.balanceOf(alice.address),
        token1.balanceOf(alice.address),
      ]);

      expect(aliceToken0Balance3).to.be.equal(parseEther("90"));
      expect(aliceToken1Balance3).to.be.equal(parseEther("40"));

      await expect(
        fees
          .connect(owner)
          .claimFor(alice.address, parseEther("10"), parseEther("10"))
      )
        .to.emit(token0, "Transfer")
        .withArgs(fees.address, alice.address, parseEther("10"))
        .to.emit(token1, "Transfer")
        .withArgs(fees.address, alice.address, parseEther("10"));

      const [aliceToken0Balance4, aliceToken1Balance4] = await Promise.all([
        token0.balanceOf(alice.address),
        token1.balanceOf(alice.address),
      ]);

      expect(aliceToken0Balance4).to.be.equal(parseEther("100"));
      expect(aliceToken1Balance4).to.be.equal(parseEther("50"));
    });
  });
});
