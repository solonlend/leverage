# DESIGN — Solon CLM v1（fork Beefy V3 托管这一套）

> 2026-09-09。用户拍板方向:"不管 V4，fork 他们的 V3 这一套"。
> 状态:**待 review**，过了再写码。上游:beefyfinance/beefy-zk（MIT，可自由 fork 商用）。
> 定位:**1x 无杠杆的集中流动性托管**——用户存双币，合约自动管区间/复投/调仓。与杠杆金库是两条产品线:CLM 卖"省心"，杠杆金库卖"放大"。

## 0. 为什么做（一句话论证）

RH 链 WETH/USDG fee100 池 $29M TVL、fee APR 长期 30~60%，链上没有任何 ALM/机枪池竞品;我们已有全套配套（keeper、监控、fee-apr 索引器、Farm UI、清算机器人经验），fork 成本主要在测试不在开发。CLM 还是杠杆金库的获客漏斗（先存 1x，再上杠杆）。

## 1. 搬什么、不搬什么

### 1.1 搬（4 个合约 + 工具库）

| 上游 | 我方命名 | 改动量 |
|---|---|---|
| `BeefyVaultConcLiq.sol` | `SolonRangeVault.sol` | 小:改名/事件/移除 rcow 关联 |
| `BeefyVaultConcLiqFactory.sol` | `SolonRangeVaultFactory.sol` | 小 |
| `StrategyPassiveManagerUniswap.sol` | `RangeStrategyUniV3.sol` | **中**（§2 逐条） |
| `StratFeeManagerInitializable.sol` | 并入 strategy 或极简化 | 中:砍掉 FeeConfigurator 外部依赖 |
| utils: `TickUtils/TickMath/FullMath/LiquidityAmounts/UniswapV3OracleLibrary/Path/UniV3Utils` | libraries/ 下复用 | 零/微（TickMath 等与我方现有重复的用我方版本，diff 审计确认一致性） |

### 1.2 不搬

- **BeefySwapper / 全部 swap 路由**:Beefy 把性能费换成 native 分账，是他们跨 41 链统一分账的需求。我们单链单池起步——**性能费直接以 token0/token1 原币转 treasury**，整条 swap 依赖砍掉。少一个路由攻击面（E-1 哲学延续），少一套 swapper 合约。
- `BeefyFeeConfigurator`:费率就三个数，直接放 strategy 常量+setter。
- CLM Pool/rcow 奖励层、Boost、zap:v1 无此需求。
- beacon proxy 体系:他们要量产 859 个池;我们首发 1 个池，**直接部署不可升级实例**（与杠杆金库同哲学，比上游更保守——上游 beacon 可升级恰是我们红队会打的点）。多池需求出现时再议工厂。

### 1.3 测试栈

上游是 hardhat + 几乎没有公开测试。**测试全部自写 foundry**（我方标准:单测+不变量+fork+fuzz），不搬他们的测试。这是本项目最大工作量所在。

## 2. RangeStrategy 逐条适配

1. **池与 TWAP**:目标池 WETH/USDG fee100（`0x52e6…71Ca`）。calm check 照抄（|tick−TWAP120s|≤deviation）。**前置已实测通过（2026-09-09）**:`slot0().observationCardinality = 2500`（已拉满），`observe([120,0])` 直接可用，实测当刻 TWAP 偏差仅 ~2.5 tick——无需 `increaseObservationCardinalityNext`，此前置销项。
2. **rebalancer 白名单**:上游是 StrategyFactory 级 mapping;我们不搬工厂 → strategy 内直接 `mapping(address=>bool) rebalancers` + governor setter。初期 = 现有 keeper 双 EOA，moveTicks 节奏 6h 起步（链下 cron，复用 dual keeper 框架）。
3. **harvest 公众化**:保留上游"任何人可调 + tx.origin 拿 call fee"。分账简化为两方:`callFee`（初值 gross 的 0.5%）+ `treasury`（其余全部），无 strategist/无 BIFI。
4. **性能费**:上游 9.5%。我们初值 **10%**——与杠杆金库 harvest fee 持平，产品线内一致，setter 硬顶 ≤15%。
5. **利润线性释放（lockedProfit）**:**必须保留**——共享份额池,这是防 PPS 三明治的核心（对应我方 U4 触发条件:现在触发了）。lockDuration 上游默认按池况调,初值 1h。
6. **滑动 swap fee（不平衡入金费）**:保留,照抄 `_getTokensRequired`,这段数学是他们防"借存取款免费 rebalance"的关键,删了就是送钱漏洞。
7. **panic/pause**:保留 onlyManager panic(拔仓+暂停+撤授权)。接进现有 monitoring daemon(新增 CLM 健康项:仓位在池、区间覆盖现价、TWAP 偏差、未收 fee 堆积)。
8. **首存 MINIMUM_SHARES 烧毁**:保留。
9. **无外部 oracle**:CLM 全程不用 Chainlink——份额计价用池 spot,安全靠 calm+滑动费。这是与杠杆金库的关键架构差异,红队重点(§4)。

## 3. 产品面

- **首发池**:仅 WETH/USDG fee100 一个（我们最懂、监控最全、和杠杆金库同池共振）。第二批候选从 observation indexer 的 TVL 榜筛（有真量、无奇怪 fee 档的 V3 池）。
- **区间宽度**:positionWidth 初值对齐我们 Farm UI 的 Balanced 档（±5%），governor 可调。
- **前端**:Farm UI 加 "Range Vaults (1x)" 区块——存取双币、份额价值、当前区间可视化。E.6 教训:交互层同步接，不许只挂展示目录。
- **skill/agent 工具**:read 工具加 `clm` kind（份额→双币价值换算）;sim 工具支持 deposit/withdraw 预演。
- **命名与叙事**:对外 "Solon Range Vaults——auto-managed concentrated liquidity, no leverage"。与 leveraged farms 并列为两档风险产品。

## 4. 风险与红队重点

- **份额池是新攻击面**（杠杆金库单 NFT 没有的）:inflation attack（MINIMUM_SHARES+首存路径）、PPS 操纵（lockedProfit+calm）、不平衡入金套利（滑动费数学逐行验）、同块存取（lastDeposit calm 强制）。
- **spot 计价依赖**:存款时的 price() 是池 spot——calm check 是唯一防线,deviation 参数保守起步（100 tick≈1%）。
- **上游已知边界**:急跌穿区间时 out-of-range IL 在下次 moveTicks 前敞口存在（上游文档自认）;6h 节奏+monitoring 告警是缓解,不是消除。产品页要如实写。
- **上游代码新鲜度——已考证（2026-09-09）**:把 beefy-zk 源码与两个 Arbitrum 链上已验证实例做了逐函数 normalize-diff:
  - beefy-zk 比早期部署版（`0x05e4…584D`）**多出整代功能**:moveTicks/rebalancer 白名单、isCalm 公开、retireVault、滑动费接线;
  - 比后期部署版（`0xDdcA…8111`）**多 4 处安全硬化**:①`_addLiquidity` 加 onlyCalmPeriods（含零流动性分支强制 calm）②`_harvest` 加 onlyCalmPeriods ③`_setAltTick` 增加 alt==main 区间 revert ④新增 `lastDeposit`——同块"存后即取"强制 calm（堵同块操纵向量）。
  - 结论:**beefy-zk 是已知最新、含事后硬化的版本，适合做 fork 基线**。残留不确定性:2024 后的 Base/主网新部署无法抓源码验证（浏览器 WAF），实施期若能拿到再补一轮 diff，拿不到不阻塞。
- **审计史（上游）**:CLM 于 2024-05 上过 Sherlock 公开赛（134 份提交,官方口径仅 1 个有效 medium——LP token 与 reward token 同币时未收割 fee 计入份额价值的记账问题,已修）;运行至今公开渠道查不到 CLM 被盗/事故记录。我们 fork 后仍按我方标准全量红队,不因上游干净而减档。

## 5. 里程碑（估两周,含冻结测试）

1. **M1 合约移植**:4 合约改名适配+编译过（1~2 天）
2. **M2 测试**:foundry 单测+不变量+RH fork 全套,目标覆盖率与杠杆金库同档（1 周,大头）
3. **M3 红队**:自打 2 轮+Codex 异构复审（2~3 天）
4. **M4 部署**:RH fork 演练→主网小容量软启动（deposit cap 起步 $5k 档）→烟测→监控接线→前端/skill/公告（复用 LAUNCH-CHECKLIST 模板走一遍）

## 6. 决议（2026-09-09 review 通过,全部拍板）

- **Q1 性能费 = 10%**（用户委托判断,定 10%:与杠杆金库 harvest fee 持平,产品线内一个数好记好讲;对 $1000 仓位年 fee $400 而言即 $40,和上游 9.5% 的差异每年 $2,品牌一致性优先）。其中 caller 小费 0.5%(gross),treasury 9.5%。
- **Q2 不可升级单实例**(采纳建议)。
- **Q3 v1 与杠杆金库资金完全隔离**(采纳建议);组合玩法进 FULL-VISION。
- **Q4 进 solonlend/leverage 同仓**(采纳建议),源码放 `src/range/`。

→ 本 doc 即日生效,进入 M1(合约移植)。
