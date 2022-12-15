# :seedling: 欢迎来到Interest Protocol! :seedling:

[![codecov](https://codecov.io/gh/interest-protocol/interest-swap/branch/main/graph/badge.svg?token=FF611VO5MR)](https://codecov.io/gh/interest-protocol/interest-swap)
[![docs](./assets/gitbook_2.svg)](https://docs.interestprotocol.com/)
[![twitter](./assets/twitter.svg)](https://twitter.com/interest_dinero)
[![discord](./assets/discord.svg)](https://discord.gg/PJEkqM4Crk)
[![reddit](./assets/reddit.svg)](https://www.reddit.com/user/InterestProtocol)

Interest Swap 是一个支持常用资产与稳定交换不变量的去中心化交易所。

## :money_with_wings: 特点 :money_with_wings:

- 支持稳定与非稳定加密货币对的交换
- 创造稳定与非稳定加密货币对
- 为加密货币对提供流动性以赚取费用
- 路由器会自动寻找定与非稳定加密货币对的最佳价格
- 通过挂钩函数提供快速贷款
- 24小时时间加权平均价格数据库

## :fire: 技术 :fire:

核心技术:

- [Typescript](https://www.typescriptlang.org/)
- [Hardhat](https://hardhat.org/)
- [Solidity](https://docs.soliditylang.org/)

> :warning: **如果你的 node 用完了存储空间，在你的命令行中输入`export NODE_OPTIONS="--max-old-space-size=8192" `**

## 交换公式

- 稳定加密货币对遵循以下公式 [x3y+y3x >= k](https://curve.fi/files/stableswap-paper.pdf)
- 非稳定加密货币对遵循以下公式 [x * y >= k](https://uniswap.org/whitepaper.pdf)

## 参考

- Andre Cronje [solidly](https://github.com/solidlyexchange/solidly)
- Uniswap [V2 Core](https://github.com/Uniswap/v2-core)
- Curve [exchange](https://github.com/curvefi/curve-contract)

## 社交媒体

**欢迎交流!**

- info@interestprotocol.com
- [Twitter](https://twitter.com/interest_dinero)
- [Medium](https://medium.com/@interestprotocol)
- [Reddit](https://www.reddit.com/user/InterestProtocol)
- [Telegram](https://t.me/interestprotocol)
- [Discord](https://discord.gg/PJEkqM4Crk)
