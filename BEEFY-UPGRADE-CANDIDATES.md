# Beefy 对标升级候选（记录稿，未启动）

> 2026-09-08 由 Beefy 合约深读得出（源码:beefyfinance/beefy-contracts + beefy-zk）。用户已确认"后面启动这里的升级"，本文是启动前的候选清单与范围记录——**只记录，不含实现**。启动时逐条拍板取舍，按合约改动纪律走（改合约 = 全量重测 + 红队重打）。

## 背景

Beefy = 复投工厂（经典 vault）+ 区间管家（CLM），859 个池、41 链、TVL $116m、六年零本金事故。无杠杆无清算，风险档比我们低一档；值得抄的是工程冗余层，不是数学层。CLM 全套源码在 beefy-zk 仓（MIT），可直接对照实现。

深读要点存档:`~/.claude/projects/.../memory/beefy_clm_reference.md`；机制细节当天已逐条发用户（TG 13041~13043）。

## 候选清单（按预估性价比排序）

### U1. calm check —— 池内 TWAP 偏差门控
- **抄什么**:Beefy 所有进攻性动作（deposit/addLiquidity/harvest/moveTicks）要求 |current tick − 120s TWAP| ≤ maxTickDeviation，否则 revert;纯 withdraw 永远放行。
- **落到我们**:open / increase / rebalance 入口加同款校验（V3 池 observe() 已有基础设施;RH 池 cardinality 需先确认）。与现有 Chainlink 估值防护互补:feed 管"价值算对"，calm 管"进场时机没被操纵"。
- **改动面**:小（一个 modifier + 两个参数）。但属合约改动，触发全量重测。

### U2. rebalance 不卖币 —— 债务侧配平代替现货 swap
- **抄什么**:CLM 比例歪了不 swap，多余币种开贴现价的窄单边 alt 仓继续赚费，IL 不落袋。
- **落到我们**:双腿借贷架构天然适配——区间调整时优先调两腿债务比例（还一腿/多借一腿），而不是现货 swap 配平。省真实滑点+手续费（Robin 链实盘教训:swap 成本是剥头皮亏损主因之一）。
- **改动面**:大，动 rebalance 核心路径。建议进 V4/v1.2 设计讨论，先出设计 doc 再动手。alt 仓双仓位法是否引入另议（我们单 NFT 模型 vs 他们策略持仓模型，形态不同）。

### U3. harvest 公众化 —— caller 赏金
- **抄什么**:harvest 任何人可调，收益的 0.01~0.5% 给 caller;白名单只留给有风险的动作（他们:moveTicks;我们:rebalance/清算）;官方 bot（Cowllector，开源）兜底保 24h 至少一次。
- **落到我们**:harvest 是无风险动作，可开放公众+小费，解 keeper 单点问题的第一步（比双 EOA 更彻底）。
- **改动面**:中（harvest 加 callFeeRecipient 分账）。

### U4. lockedProfit 线性释放（暂不需要，条件触发）
- **抄什么**:harvest 利润按 lockDuration 线性计入净值，防"harvest 前存后取"的 PPS 三明治。
- **我们现状**:每仓独立 NFT 独立账，无共享净值，**天然免疫**。
- **触发条件**:将来若做出借侧共享份额包装金库（存 USDG 吃被动收益类产品），此机制必须带上，同时带 MINIMUM_SHARES 烧毁（inflation attack 防御）。

### U5. 策略热换模式（远期，随多签一起议）
- **抄什么**:proposeStrat → approvalDelay 公示 → upgradeStrat 整体替换，用户可在窗口内撤资。
- **我们现状**:金库逻辑不可换，升级只能迁移。扩容换多签/审计时一并评估要不要引入。

## 启动前置

- U1~U3 均为合约改动 → 全量回归 + fork 演练 + 红队补打（合约改动纪律）。
- 与主网软启动的关系:当前 200 USDG/0.05 WETH 容量下**不急**，可与"多签+审计+扩容"同一波做，避免两次冻结窗口。
- 启动信号:等用户明确"开工"，先出 U2 的设计 doc（v1 scope），U1/U3 可并入同一批。
