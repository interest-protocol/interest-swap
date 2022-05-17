import { ethers } from "hardhat";

export const multiDeploy = async (
  x: ReadonlyArray<string>,
  y: Array<Array<unknown> | undefined> = []
): Promise<any> => {
  const contractFactories = await Promise.all(
    x.map((name) => ethers.getContractFactory(name))
  );

  return Promise.all(
    contractFactories.map((factory, index) =>
      factory.deploy(...(y[index] || []))
    )
  );
};

export const deploy = async (
  name: string,
  parameters: Array<unknown> = []
): Promise<any> => {
  const factory = await ethers.getContractFactory(name);
  return await factory.deploy(...parameters);
};

export const advanceTime = (
  time: number,
  _ethers: typeof ethers
): Promise<void> => _ethers.provider.send("evm_increaseTime", [time]);

export const advanceBlock = (_ethers: typeof ethers): Promise<void> =>
  _ethers.provider.send("evm_mine", []);

export const advanceBlockAndTime = async (
  time: number,
  _ethers: typeof ethers
): Promise<void> => {
  await _ethers.provider.send("evm_increaseTime", [time]);
  await _ethers.provider.send("evm_mine", []);
};

export const sortTokens = (a: string, b: string): [string, string] =>
  a < b ? [a, b] : [b, a];
