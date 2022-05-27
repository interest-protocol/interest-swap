# :seedling: Welcome to Interest Protocol! :seedling:

[![codecov](https://codecov.io/gh/interest-protocol/interest-swap/branch/main/graph/badge.svg?token=FF611VO5MR)](https://codecov.io/gh/interest-protocol/interest-swap)
[![docs](./assets/gitbook_2.svg)](https://docs.interestprotocol.com/)
[![twitter](./assets/twitter.svg)](https://twitter.com/interest_dinero)
[![discord](./assets/discord.svg)](https://discord.gg/PJEkqM4Crk)
[![reddit](./assets/reddit.svg)](https://www.reddit.com/user/InterestProtocol)

Interest Swap is a DEX that supports both the constant product and stable swap invariant.

## :money_with_wings: Features :money_with_wings:

- Swap Between stable and volatile pairs
- Create volatile and stable pairs
- Provide liquidity to pairs to earn fees
- Router will automatically find best prices between stable and volatile pairs
- Flash loans via hook function
- 24 hour TWAP Oracle

## :fire: Technology :fire:

Core technologies:

- [Typescript](https://www.typescriptlang.org/)
- [Hardhat](https://hardhat.org/)
- [Solidity](https://docs.soliditylang.org/)

> :warning: **If your node runs out of memory write in your terminal `export NODE_OPTIONS="--max-old-space-size=8192" `**

## Swap Formulas

- Stable pairs follow the stableswap invarant [x3y+y3x >= k](https://curve.fi/files/stableswap-paper.pdf)
- Volatile pairs follow the constant product invariant [x * y >= k](https://uniswap.org/whitepaper.pdf)

## Credits

- Andre Cronje [solidly](https://github.com/solidlyexchange/solidly)
- Uniswap [V2 Core](https://github.com/Uniswap/v2-core)
- Curve [exchange](https://github.com/curvefi/curve-contract)

## Social Media

**Get in touch!**

- info@interestprotocol.com
- [Twitter](https://twitter.com/interest_dinero)
- [Medium](https://medium.com/@interestprotocol)
- [Reddit](https://www.reddit.com/user/InterestProtocol)
- [Telegram](https://t.me/interestprotocol)
- [Discord](https://discord.gg/PJEkqM4Crk)
