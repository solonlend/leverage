# DESIGN — Beefy 对标升级 v1（U1 calm check / U2 债务侧 rebalance / U3 公众 harvest）

> 2026-09-09。承接 `BEEFY-UPGRADE-CANDIDATES.md`（U1~U3 三条入本批，U4/U5 不动）。
> 状态:**待 review**。review 通过前不写代码（工业流程）。
> 对标源码:beefy-zk `StrategyPassiveManagerUniswap.sol` / `BeefyVaultConcLiq.sol`（MIT）。
> 我方基线:`src/UniV3DualVault.sol`（主网 vaultId 1）、`src/UniV3LeverageVault.sol`（vaultId 2）。V4 版本随 D.8 专项另做。

## 0. 范围与非目标

**做**:三个入口级/路径级改动，全部围绕已上线的 V3 双金库与单金库。
**不做**:alt 双仓位法（他们策略持仓模型与我们单 NFT 模型形态不同，收益不明确）、共享份额金库、lockedProfit（U4 触发条件未到）、策略热换（U5 随多签议）。

---

## 1. U1 — calm check（池内 TWAP 偏差门控）

### 1.1 机制（照抄 Beefy，参数归我们）

```
isCalm(): |currentTick − twapTick(TWAP_INTERVAL)| ≤ MAX_TICK_DEVIATION
```

- `twapTick` 用池自身 `observe([TWAP_INTERVAL, 0])` 两点差商（Beefy 同款，默认 120s）。
- 门控范围（revert `NotCalm`）:
  - `open` / `increase` / `rebalance`（进攻性动作，双金库+单金库同步加）
  - `harvest(compound=true)`（复投按现价 mint，与 increase 同风险面;`compound=false` 纯取现不拦）
- **永不门控**:`close`、`addMargin`、`liquidate`（退出与自救通道任何行情必须畅通;Beefy 同哲学——withdraw 永远放行）。清算尤其不能拦:清算窗口常常正是行情剧烈时。

### 1.2 与现有 oracle 防护的分工

Chainlink 双 feed 管"估值与债务算对"（staleness/depeg 已有）;calm check 管"进场瞬间的池内价没被推离"。两层正交，都便宜。

### 1.3 参数与治理

- `MAX_TICK_DEVIATION`:immutable 不可行（要按池波动性调），governor setter + 硬边界 `[10, 500] tick`（fee100 池 1 tick≈1bp，即 0.1%~5%）。初值建议 **100**（≈1%，比 Beefy 常用值保守）。
- `TWAP_INTERVAL`:governor setter，边界 `[60, 600]s`，初值 120s。
- setter 走 governor（首发=部署者，将来=多签），事件必发。
- `isCalm()` 公开 view，keeper/UI/skill 工具预检可用。

### 1.4 部署前置（硬依赖）

RH 主网 WETH/USDG fee100 池的 `observationCardinality` 必须 ≥ 覆盖 120s 的观测数（RH ~10 blocks/s，波动期观测写入频繁）。上线步骤含:链上读 `slot0().observationCardinality`，不足则先 `increaseObservationCardinalityNext(N)`（无权限函数，任何人可调，gas 一次性）——**N 的取值在实施期实测后定**，checklist 项。

---

## 2. U2 — 债务侧 rebalance（零 swap 配平）

### 2.1 现状与问题

现 `rebalance`:collect fee → 全部 remove → `swapAmount` 现货 swap 配平 → 新区间 mint → 健康检查。
问题:每次调仓付真实滑点+池费（Robin 实盘教训），且 swap 面是 E-1 之后仅存的用户路由入口（zapPath）。

### 2.2 新机制

给 `RebalanceParams` 增加两条带符号债务增量，swap 降级为兜底:

```solidity
struct RebalanceParams {
    int24  newTickLower; int24 newTickUpper;
    int256 debtDeltaRisk;   // >0 加借 RISK;<0 偿还 RISK（新增）
    int256 debtDeltaLoan;   // >0 加借 LOAN;<0 偿还 LOAN（新增）
    int256 swapAmount;      // 保留，默认 0=零 swap 路径
    uint256 minSwapOut; uint128 minLiquidity; bytes zapPath; uint256 deadline;
}
```

执行序（remove 之后、mint 之前插入债务段）:

1. collect fee + 抽成、remove 全部流动性（不变）
2. **偿还段**:`debtDelta* < 0` → 用在手余额 `repay`（capped at 当前债务与在手余额，多还不出错）
3. **加借段**:`debtDelta* > 0` → `borrow` 沿用本仓位既有 debtId（increase 同款）
4. swap 段（不变，通常为 0）
5. 新区间 mint → `_repayOpenDust`（E-2:借而未用先还债）→ `_refundDust` → `isHealthy` 检查（不变）

零 swap 情形下 `zapPath` 为空，swap 面完全不触发——与 dual 开仓/increase 的 E-1 纪律对齐。

### 2.3 数字示例（为什么值得）

仓位 $300，区间上移后需多 $60 USDG、少 $60 WETH:
- 旧路径:swap $60 WETH→USDG，付池费+滑点+失败重试 gas，Robin 实测单次 $0.3~1+
- 新路径:还 $60 WETH 债 + 多借 $60 USDG，两笔 lending pool 记账，无滑点无池费。借贷利率差是持仓期成本（USDG 90% 利用率下 4% APR → $60 一天 ¢0.7），远低于每次调仓的 swap 成本

### 2.4 约束与兜底

- **授信硬顶**:加借受 per-vault credit（现 dual: USDG 100/WETH 0.04）与 reserve capacity 限制，超了 revert——此时 caller 改用 `swapAmount` 兜底，两条路互备。
- **利率不对称**:高利用率时加借贵。选债务路径还是 swap 路径是 caller（keeper/UI）的经济决策，合约两条都留。UI/keeper 的选择算法（比较 borrow APR 增量 vs swap 成本）属实施期链下工作，不进合约。
- **健康检查兜底一切**:任何配平组合最终过 `isHealthy`，杠杆不会被 rebalance 悄悄推高越界。
- 单金库（vaultId 2）只有一条 LOAN 债，同构地加 `debtDeltaLoan` 一个参数，行为一致。

### 2.5 Surface diff（合约改动纪律要求的对照矩阵，实施期逐行填）

| 函数 | 旧 | 新 | 语义变化 |
|---|---|---|---|
| `rebalance` | swap 配平 | +债务配平段，swap 保留 | 参数 struct 变（**ABI breaking**，skill 工具/前端/keeper 同步改） |
| `open/increase/close/harvest/liquidate/addMargin` | — | 仅 U1 门控插入（open/increase/harvest-compound） | revert 面新增 NotCalm |
| lending pool | — | 不动 | 无 |
| oracle | — | 不动 | 无 |

### 2.6 不变量（新增进 invariant 套件）

- rebalance 前后:`总债务价值变化 == debtDelta 净额 ± 利息`（无凭空债务）
- 零 swap 路径:金库对 ROUTER 的 allowance 全程为 0 使用
- 任意 rebalance 后 `isHealthy == true`（已有，保留）
- repay 段封顶:还款额 ≤ min(在手余额, 当前债务)，永不 revert 于"多还"

---

## 3. U3 — 公众 harvest（caller 赏金）

### 3.1 机制

新增独立入口（不动现有 `harvest`，holder 语义不变）:

```solidity
function harvestFor(uint256 id, uint256 deadline) external; // 任何人可调
```

- 行为:collect fee → 抽 harvest fee（现 10%，不变）→ **抽成中划 CALL_FEE 给 msg.sender** → 剩余全部复投（公众触发只能 compound，不能替 holder 取现）
- `CALL_FEE_BPS`:从 harvest fee 的 10% 里切（即 gross fee 的 ≤1%），governor setter，边界 `[0, 2000]`（fee 的 0~20%），初值 **1000**（fee 的 10% = gross 的 1%）。协议少拿一点换 keeper 去中心化，holder 收益不受影响——对齐 Beefy"从协议抽成里出小费"的分账结构。
- 门控:calm check（复投 mint 同风险面）+ `minCallReward`?——不设最低额，Robin gas 便宜，无利可图时自然没人调，不构成攻击面（见 3.2）。
- keeper 官方 bot 兜底照跑（D 段现有 dual keeper 挂 harvest 职能即可）。

### 3.2 攻击面检查

- 频繁调用薅小费?每次真实 collect,fee 池子说了算，无 fee 则小费为 0，攻击者只烧自己 gas。
- 三明治 harvest?复投走 increaseLiquidity 现价 mint，calm check + amount0Min/1Min=0 但有 `_refundDust`——与现有 holder harvest 完全同面，无新增。
- 对 holder 的强制性?复投永远是 holder 收益增厚（fee 进仓位），无损。唯一改变是 holder 失去"fee 攒着不动"的选择——**开关**:`position.autoHarvestOptOut`?v1 不做，保持简单;用户不想被复投的场景想不出实际损失。列开放问题 Q3。

---

## 4. 测试与上线

- **全量重测**:三改动同批进主线 → offline 325+ 全跑，新增:calm 门控单测（边界 tick、observe 不足 revert 面）、债务 rebalance 单测+fuzz（授信顶/多还封顶/健康边界）、harvestFor 单测（分账精确、无 fee 空转）、不变量 §2.6。
- **fork 演练**:RH mainnet fork 上 rebalance 零 swap 全径 + calm 触发/放行两态 + harvestFor 真金分账。
- **Sepolia 实链**:门控参数调到易触发值实测 NotCalm 路径。
- **红队补打**:重点 §3.2 与债务段（新增借贷入口 = 新增攻击面），Codex 异构复审照旧。
- **上线波次**:与"多签+扩容"同一波（避免两次冻结窗口）;ABI breaking 项(§2.5)要求 skill 三件套 sim/read、Farm UI、keeper 同 PR 更新。现主网金库不可升级 → 本批以**新版本金库部署+旧库缩容停新仓**方式上线（F.2 路径），存量仓位在旧库自然退出。

## 5. 开放问题（review 时拍板）

- **Q1** MAX_TICK_DEVIATION 初值 100 tick（≈1%）是否同意?（Beefy 各池 50~200 不等）
- **Q2** rebalance 权限:现 onlyHolder。要不要同时开白名单 rebalancer 代客调仓（Beefy moveTicks 模式，为将来托管型产品铺路）?v1 建议**不开**，维持 holder 自管。
- **Q3** harvestFor 要不要 per-position opt-out?v1 建议不做。
- **Q4** 新版金库上线节奏:随多签波（建议），还是独立先发?
