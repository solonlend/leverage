# 参数对标调研 — 2026-09-05

目的：上线参数不靠拍脑袋。本文只记录**实测数据**及其来源，结论与建议单独标注，采用与否由人决定。

所有数据均为 2026-09-05 通过 RPC 直接读取链上合约所得，非二手资料。复现命令见每节。

---

## 1. 预言机心跳（实测）

方法：读 `latestRoundData()` 取 roundId，回溯 8 轮 `getRoundData()`，计算相邻轮 `updatedAt` 差值。

| feed | 链 | 地址 | 实测间隔 (s) | 判定 |
|---|---|---|---|---|
| ETH / USD | Robinhood (4663) | `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` | 30 / 90 / 210 / 557 / 660 / 2371 / 2521 / 3451 | 兜底心跳 ≈ 1h，偏差触发频繁 |
| USDG / USD | Robinhood (4663) | `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` | 86403 ~ 86426（8 轮） | 纯 24h 心跳，中间不更新 |
| ETH / USD | Ethereum | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` | 3612 ~ 3636（8 轮） | 1h 心跳，本次采样期内未见偏差触发 |

**关键对照**：RH 的 ETH feed 与以太坊主网 ETH feed 心跳同为 1 小时量级；RH 的 USDG feed 是 24 小时，比 ETH 腿慢 25 倍。两条腿用同一时效阈值在数据上站不住。

其它已确认事实（同日实读）：
- WETH `0x0Bd7d308…` decimals 18；USDG `0x5fc5360d…` decimals 6 → 清单 1.9 的 `18/6/6` 成立。
- 两条 feed 的 `description()` 分别为 `"ETH / USD"`、`"USDG / USD"`，`decimals()` 均为 8。
- V3 fee100 池 `0x52e65B17…`：token0 = WETH，token1 = USDG，fee = 100，tickSpacing = 1，liquidity 1.263e19。
- Permit2 `0x0000…78BA3` codesize 9152（≠ 0）；V4 PoolManager `0x8366a39C…` codesize 24009。

---

## 2. 借贷风险参数（实测）

### Aave V3 — Ethereum
来源：`AaveProtocolDataProvider` `0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3` 的 `getReserveConfigurationData(address)`。

| 资产 | LTV | 清算阈值 | 清算奖励 | 储备金率 |
|---|---|---|---|---|
| WETH | 80.50% | 83.00% | 5.00% | 15% |
| USDC | 75.00% | 78.00% | 4.50% | 10% |
| USDT | 75.00% | 78.00% | 4.50% | 10% |

### Compound V3 (Comet) — USDC 市场，WETH 抵押
来源：Comet `0xc3d688B66703497DAA19211EEdff47f25384cdc3` 的 `getAssetInfoByAddress(WETH)`。

| 项 | 值 |
|---|---|
| borrowCollateralFactor | 82.5% |
| liquidateCollateralFactor | 88.0% |
| liquidationFactor | 93.0%（即清算折价 7%） |
| storeFrontPriceFactor | 60% |

### Morpho Blue — 全局允许的 LLTV 档位
来源：Morpho `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` 的 `isLltvEnabled(uint256)`，逐个验证返回 true。

`0% · 38.5% · 62.5% · 77% · 86% · 91.5% · 94.5% · 96.5% · 98%`

Morpho 只允许这九档，市场创建者从中选一档。Solon 作为 Morpho curator，选档时受此约束。


### 利率曲线（实测）

**Aave V3 — Ethereum**，来源：`ProtocolDataProvider.getInterestRateStrategyAddress()` → `0x9ec6F08190DeA04A54f8Afc53Db96134e5E3FdFB` 的 `getInterestRateDataBps(address)`，返回 (最优利用率, 基础利率, 斜率1, 斜率2)：

| 资产 | 最优利用率 | 基础利率 | 斜率1 | 斜率2 | 最优点利率 | 100% 利用率 |
|---|---|---|---|---|---|---|
| WETH | 92% | 0% | 2.20% | 6.00% | 2.20% | 8.20% |
| USDC | 94% | 0% | 4.30% | 10.00% | 4.30% | 14.30% |

**Compound V3 (Comet) — USDC 市场**，来源：Comet `0xc3d688B6…` 的 `borrowKink()` 与三个 `borrowPerSecondInterestRate*()`，按 31,536,000 秒/年换算：

| 项 | 值 |
|---|---|
| kink（supply 与 borrow 相同） | 90% |
| 基础利率 | 1.500% |
| kink 以下斜率 | 2.778% |
| kink 处借款利率 | 4.28% |
| kink 以上斜率 | **360%** |

两家的共同形状：**拐点设在 90%~94% 的高利用率**，拐点以下利率平缓（2%~4%），拐点以上陡峭（Aave 6%~10%，Compound 直接 360%）。陡峭段的作用不是赚利息，是强制把利用率拉回拐点以下、保证出借人能赎回。

### 容量上限（实测）

来源：`ProtocolDataProvider.getReserveCaps(address)`。

| 资产 | borrowCap | supplyCap |
|---|---|---|
| WETH | 2,400,000 | 2,700,000（约 66 亿美元） |
| USDC | 2,250,000,000 | 2,500,000,000 |

两家都设了有限上限，**没有一家用无限容量**。本项目 `LendingPool` 当前默认无限（`src/lending/lendingpool/LendingPool.sol:75-103`），首发必须设一个值。


## 2b. 预言机过期检查 —— 同业怎么做（已核实源码）

之前这一项标为"未核实"，现已读过三家的官方实现源码。结论是**同业分成两派**。

**Aave V3 —— 完全不检查。** `aave-dao/aave-v3-origin` 的 `src/contracts/misc/AaveOracle.sol`：

```solidity
int256 price = source.latestAnswer();
if (price > 0) { return uint256(price); }
else { return _fallbackOracle.getAssetPrice(asset); }
```

调用的是 `latestAnswer()`，这个方法根本不返回时间戳。唯一的校验是"价格 > 0"。喂价停更一年，它照样返回最后那个价。

**Morpho Blue —— 拿得到时间戳，但主动丢弃。** `morpho-org/morpho-blue-oracles` 的 `ChainlinkDataFeedLib.sol`：

```solidity
(, int256 answer,,,) = feed.latestRoundData();
require(answer >= 0, ErrorsLib.NEGATIVE_ANSWER);
```

用了 `latestRoundData()`，但四个返回值里只取 `answer`，`updatedAt` 被下划线吞掉。源码里有一句注释说明这是有意的：**"Staleness is not checked because it's assumed that the Chainlink feed keeps its promises on this."**

**Euler v2 —— 检查，且有明确上下界。** `euler-xyz/euler-price-oracle` 的 `src/adapter/chainlink/ChainlinkOracle.sol`：

```solidity
uint256 public immutable maxStaleness;
uint256 internal constant MAX_STALENESS_LOWER_BOUND = 1 minutes;
uint256 internal constant MAX_STALENESS_UPPER_BOUND = 72 hours;
...
uint256 staleness = block.timestamp - updatedAt;
if (staleness > maxStaleness) revert Errors.PriceOracle_TooStale(staleness, maxStaleness);
```

构造期校验 `maxStaleness` 落在 1 分钟 ~ 72 小时之间，取值期超时直接 revert。

### 对本项目的意义

| | 是否检查过期 | 阈值上界 |
|---|---|---|
| Aave V3 | 否 | — |
| Morpho Blue | 否（显式注明有意为之） | — |
| Euler v2 | 是 | 72 小时 |
| **本项目（当前设计）** | **是，两条腿分开** | 风险腿 6h / 稳定币腿 48h |

我们的做法与 Euler 同派，且比它更细（按 feed 分别设阈值 + 稳定币脱锚带）。我们提议的护栏区间 —— 风险腿 1~6 小时、稳定币腿 25~48 小时 —— **完整落在 Euler 的 1 分钟~72 小时之内**，没有超出已被同业采用的范围。

**限制声明**：以上三段均取自各项目官方仓库主分支的**公开源码**，未逐字节验证与链上已部署实例的字节码一致。Aave 的已部署 oracle（`0x54586bE6…`，codesize 3405）为 WETH 注册的价格源是 `0x5424384B…`（一个适配器合约，非 Chainlink 原始 proxy `0x5f4eC3Df…`），适配器层的行为未单独核实。

---

## 3. 对照区间汇总

| 参数 | 同业实测区间 | 备注 |
|---|---|---|
| 单币抵押 LTV | 75% ~ 82.5% | Aave WETH 80.5%，Compound WETH 82.5% |
| 清算阈值 | 78% ~ 88% | Compound 的阈值明显更高 |
| 清算奖励 / 折价 | 4.5% ~ 7% | Aave 4.5–5%，Compound 7% |
| 协议留存（储备金率） | 10% ~ 15% | Aave WETH 15%，稳定币 10% |
| ETH 预言机心跳 | 1h | RH 与以太坊主网一致 |
| 利率曲线拐点 | 90% ~ 94% | Aave 92/94%，Compound 90% |
| 拐点处借款利率 | 2.2% ~ 4.3% | 视资产而定 |
| 拐点以上斜率 | 6% ~ 360% | Compound 用极陡斜率强制回落 |
| 容量上限 | 均为有限值 | 无人使用无限容量 |

---

## 4. 与本项目的差异（分析，非实测）

以下是判断，不是数据，采用与否需人确认：

1. **我们的抵押物不是单币，是 LP 头寸。** 上表所有 LTV / 清算阈值对标的都是"一个币做抵押"。LP 头寸同时暴露于两种资产、含无常损失、且价值随价格区间非线性变化。因此本项目的 LLTV **应当低于**同业单币档位，而不是持平。参照 Morpho 档位，77% 一档比 86% 更贴合 LP 抵押的性质。

2. **清算奖励要覆盖清算人的额外成本。** 同业 4.5% ~ 7% 对应的是"卖掉一个币"；我们的清算人需要先拆 LP、再兑换、可能跨两腿，成本更高、滑点更大。取同业区间的上沿（接近 7%）比下沿更合理。

3. **时效阈值这一项我们比同业更严格，不是更松。** 已核实：Aave V3 与 Morpho Blue 都不检查过期，Euler v2 检查且上界 72 小时（见 §2b）。我们目前的做法（两条腿分别设阈值 + 稳定币脱锚带）是基于本项目实测心跳自行设计的，无同业直接对标。

## 5. 待确认

- LLTV 具体档位（建议不高于 77%，理由见 4.1）
- 清算奖励具体数值（建议靠近 7%，理由见 4.2）
- 协议留存比例（同业 10~15%）
- maxStaleness 风险腿 / 稳定币腿 / 脱锚带三个值
- ~~Aave / Morpho 的预言机过期检查实现~~ 已核实，见 §2b
