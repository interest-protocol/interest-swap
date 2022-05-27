import { BigNumber } from "ethers";
import { ethers } from "hardhat";
import { ecsign } from "ethereumjs-util";

// @desc follow the same order of the signers accounts
export const PRIVATE_KEYS = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
];

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

export const getPairDomainSeparator = (
  pairAddress: string,
  pairName: string,
  chainId: number
) =>
  ethers.utils.solidityKeccak256(
    ["bytes"],
    [
      ethers.utils.defaultAbiCoder.encode(
        ["bytes32", "bytes32", "bytes32", "uint256", "address"],
        [
          ethers.utils.solidityKeccak256(
            ["bytes"],
            [
              ethers.utils.toUtf8Bytes(
                "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
              ),
            ]
          ),
          ethers.utils.solidityKeccak256(
            ["bytes"],
            [ethers.utils.toUtf8Bytes(pairName)]
          ),
          ethers.utils.solidityKeccak256(
            ["bytes"],
            [ethers.utils.toUtf8Bytes("v1")]
          ),
          chainId,
          pairAddress,
        ]
      ),
    ]
  );

export const getPairDigest = (
  domainSeparator: string,
  owner: string,
  spender: string,
  value: BigNumber,
  nonce: number,
  deadline: number
) =>
  ethers.utils.keccak256(
    ethers.utils.solidityPack(
      ["bytes1", "bytes1", "bytes32", "bytes32"],
      [
        "0x19",
        "0x01",
        domainSeparator,
        ethers.utils.keccak256(
          ethers.utils.defaultAbiCoder.encode(
            ["bytes32", "address", "address", "uint256", "uint256", "uint256"],
            [
              ethers.utils.keccak256(
                ethers.utils.toUtf8Bytes(
                  "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                )
              ),
              owner,
              spender,
              value.toString(),
              nonce,
              deadline,
            ]
          )
        ),
      ]
    )
  );

export const getECSign = (privateKey: string, digest: string) =>
  ecsign(
    Buffer.from(digest.slice(2), "hex"),
    Buffer.from(privateKey.replace("0x", ""), "hex")
  );

const ONE = ethers.BigNumber.from(1);
const TWO = ethers.BigNumber.from(2);

export function sqrt(value: BigNumber) {
  const x = ethers.BigNumber.from(value);
  let z = x.add(ONE).div(TWO);
  let y = x;
  while (z.sub(y).isNegative()) {
    y = z;
    z = x.div(z).add(z).div(TWO);
  }
  return y;
}

export const min = (x: BigNumber, y: BigNumber) => (x.gt(y) ? y : x);

export const quoteLiquidity = (
  amountA: BigNumber,
  reserveA: BigNumber,
  reserveB: BigNumber
) => {
  if (reserveA.isZero()) return BigNumber.from(0);

  return amountA.mul(reserveB).div(reserveA);
};
