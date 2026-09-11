# 设计 doc — 降低大仓位损耗 v1:原地再平衡 + 双币入出金

> 2026-09-04。依据 [RESEARCH-rebalance-2026-09-04.md]。**本 doc 只写 v1 scope**;v1.5/v2(swap 解耦聚合器/私有 mempool/单边零头仓/触发策略层/分片/单池风控)见研究 doc 第 5 节,不在此展开。
> 状态:**待 review**。review 通过再 TDD 落地。不在设计阶段写码。

## 0. 架构前提(与 Charm 的关键差异)

Charm 是**池化 ERC4626**:所有 LP 归一个共享仓位,deposit 发 share,strategy 统一 rebalance。
我们是**每仓位独立**:每个借款人一张 Solon NFT = 独立 LP 仓位 + 独立 ExtraFi 债务(debtId),无共享份额。
所以 Charm 的机制要**适配到"单仓位"粒度**:再平衡是"重设某一张 NFT 的区间",入金是"某仓位开/加仓时带两腿",不是池化 share 存取。

## 1. v1 目标(砍损耗两大头)

| 痛点 | v1 解法 |
|---|---|
| 换区间 = close+open 两次全额 zap | **原地 rebalance**:撤本仓 LP → 只换净额 delta → 重铺新区间,**债务不动** |
| 大额开/平单币 zap 冲击大 | **双币 in-kind 入/出金**:借款人自带两腿按比例进/出,只补差额,不做半仓 zap |

## 2. 功能一:原地再平衡 `rebalance`

### 2.1 触发者(v1 决策)

**v1 = 仅仓位持有人(onlyHolder)自己再平衡**。理由:swapAmount 是调用方传参(见 2.3),owner 传坏参数只伤自己;不引入新信任。
keeper 代管/自动再平衡(需 owner opt-in + 更严的参数门禁)推到 v1.5。**此点请 review 确认:v1 是否只要 owner-triggered。**

### 2.2 函数签名(V4;V3 同构)

```
struct RebalanceParams {
    int24  newTickLower;
    int24  newTickUpper;
    int256 swapAmount;      // 链下算好的净兑换额;>0 = RISK→LOAN,<0 = LOAN→RISK
    uint256 minSwapOut;     // 该笔 swap 的滑点下限(必填非零)
    uint128 minLiquidity;   // 重铺流动性下限(滑点/被夹保护)
    bytes  zapPath;         // swap 路由
    uint256 deadline;
}
function rebalance(uint256 id, RebalanceParams calldata p)
    external nonReentrant onlyHolder(id);
```

### 2.3 执行流程(照抄 Charm 三段式,叠债务不动)

1. `_requireTwoSidedRange(newLower, newUpper)`;入口 `_snap()` 记基线(退零头用)。
2. **撤本仓全部流动性** `_removeLiquidity(pos.dexTokenId/v4TokenId, pos.liquidity, fullClose=true, deadline)` → (got0, got1)。
3. **收累积手续费 + 抽协议成** `_collectFees` + `_skimHarvestFee`(与 close 同口径,防绕过抽成),净额并入 (got0, got1)。
4. **只换净额 delta**:按 `swapAmount` 符号方向,`_swapExactIn(tokenIn, tokenOut, |swapAmount|, minSwapOut, zapPath)` —— **只这一笔**,不做整条腿往返。
5. **重铺新区间**:`_liquidityFor(newLower, newUpper, bal0, bal1)` → require `>= minLiquidity` → mint/increase 到新区间;更新 `pos.{tickLower,tickUpper,liquidity, v4TokenId}`(V4 全平重铸产生新 tokenId,底层旧 NFT 销毁、Solon NFT id 不变)。
6. `_refundDust(msg.sender, base0, base1)` 退零头(仅本次增量)。
7. **`require(_isHealthy(id), "UNHEALTHY_AFTER_REBALANCE")`** —— 债务未变,此检查兜住滑点过大导致的抵押缩水。
8. `emit Rebalanced(id, newLower, newUpper, swapAmount, newLiquidity)`。

### 2.4 债务不动(核心不变量,必须测)

- rebalance 全程**不调用** `borrow`/`repay`/`newDebtPosition`;`pos.debtId` 与 `getCurrentDebt(debtId)` 前后完全相等。
- Solon NFT id 不变、owner 不变;仅底层 LP NFT 与区间/流动性变。
- 健康度只随价格变;rebalance 本身应近似健康中性(仅损耗 swap 滑点 + fee 抽成)。

## 3. 功能二:双币 in-kind 入/出金

### 3.1 开仓/加仓带两腿(省 zap)

现状:`open` 只 pull USDG(invest)+ 借 USDG,再 zap 一半换 RISK。
v1:`OpenParams`/`IncreaseParams` 增加 `amountInvestRisk`(用户自带的 RISK 腿)+ 由调用方传 `swapAmount`(净额,可为 0):
- pull USDG invest + pull RISK invest + 借 USDG;
- 目标两腿 = `_liquidityFor` 反推;**只换 swapAmount 这笔差额**补平,不做半仓 zap;
- 自带比例正好时 `swapAmount=0` → **零 swap 开仓**。
- 向后兼容:`amountInvestRisk=0` 且 `swapAmount` 走原逻辑时 = 现有单币 zap 行为(小额散户仍可用)。

### 3.2 平仓出双币(省 zap)

现状:`close` 把 RISK 腿全换成 USDG 单币出金。
v1:`CloseParams` 增加 `outInKind`(bool):
- 必须先留足 USDG 还清应还债务(`debtToRepay`);
- 还债后剩余:`outInKind=true` → 按撤出比例出 RISK+USDG 双币(免 close zap);`false` → 维持现有单币出金。
- 注意:还债那部分若 RISK 腿不够 USDG,仍需换足额 —— 即"只把还债缺口换成 USDG",而非整条腿。

## 4. 安全分析(动审计过的核心,必须严守)

1. **swapAmount 调用方传参的风险**:owner 传错只伤自己;`minSwapOut` + `minLiquidity` + 末尾 `_isHealthy` 三重兜底,坏参数最坏是 revert 或自身滑点,**不影响他人/出借人**。keeper 代管留到 v1.5(需额外参数上限门禁)。
2. **跨仓位隔离**:rebalance/双币路径只动 `positions[id]` 与本仓 debtId,复用现有 onlyHolder;补测跨仓位不受影响(对标 Exploit3 G3/G6)。
3. **重入**:`nonReentrant`;沿用 baseline-aware `_refundDust`(防 E6 捐赠薅取)。
4. **抽成不被绕过**:rebalance 收 fee 时照 `_skimHarvestFee` 抽 10%(与 close/harvest 一致),防"用 rebalance 白拿 fee"。
5. **MEV**:rebalance 的 swap 必须带非零 `minSwapOut`;前端/keeper 默认走最深池,能上私有 mempool 更好(RH FCFS 已弱化三明治,但杠杆场景滑点直接吃抵押,不可裸奔)。
6. **健康中性**:补测 rebalance 前后 `getCurrentDebt` 恒等、健康度不因 rebalance 恶化(除滑点)。
7. **清算独立性不受影响**:rebalance 不改变"清算可不依赖 keeper 独立撤 LP 还债"这一性质。

## 5. 测试计划(TDD,先红后绿)

- rebalance:正常换区间成功、债务恒等、健康中性;`minSwapOut`/`minLiquidity` 触发 revert;非持有人 revert;fee 照抽;swapAmount=0(纯换区间无净额)路径。
- 双币入金:自带正比零 swap 开仓;比例不齐只补差额;向后兼容单币 zap。
- 双币出金:还债后双币出;还债缺口只换足额;`outInKind` 两分支。
- 不变量:把 rebalance/双币动作加进 `Invariants.t.sol` 的 handler,20 万次调用复测 5 条铁律不破。
- 对抗:rebalance 被夹(低 minSwapOut)→ 健康检查/滑点兜底;owner 传恶意 swapAmount 只伤自己。

## 6. 落地顺序建议

1. rebalance(V4 先,V3 同构)+ 全套测试 —— 直接解决"换区间损耗"。
2. 双币入/出金 —— 解决"大额开平损耗"。
3. keeper 侧净额计算工具(TS,复用 `FairLpMath.zapSwapAmountToToken0` 的价值比例)。

> review 关注点:①rebalance v1 是否只 owner-triggered;②双币路径是改现有 open/close 入参(向后兼容)还是新增 openDual/closeDual 函数;③outInKind 出金的还债缺口换算口径。确认后进 TDD。
