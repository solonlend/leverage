# Dual → 单币金库保护移植对照矩阵

> 对照基线：2026-09-05，生产代码改动前。行号均指该基线；移植范围仅 `UniV3LeverageVault` / `UniV4LeverageVault`，测试另列于 `test/`。

| 保护项 | Dual V3 已有实现 | Dual V4 已有实现 | 单币 V3 现状 | 单币 V4 现状 | 本次移植目标 |
|---|---|---|---|---|---|
| 全平残债前置门 | `close(id, CloseParams)`，341–349 行；参数 `id/c.percent`，全平前用嵌套 `try this.positionValue(id)` + `try this.totalDebtInLoan(id)` 记录 `preChecked && positionValue < totalDebt`；383–392 行仅当 RISK 残债非 `_riskIsDust` 或 LOAN 残债 `> GAP_EPS` 时检查，否则忽略粉尘；无资不抵债证明则 `SolventBadDebt()`，有证明才 `BadDebt` | `close(id, CloseParams)`，359–367、406–415 行；参数、条件、`try/catch`、`GAP_EPS` 与错误均同 V3 Dual | `close(id, CloseParams)`，262–295 行；全平后任意 `residual > 0` 都直接 `BadDebt`，无平仓前估值、无 oracle 故障处理、无粉尘阈值、无错误 | `close(id, CloseParams)`，291–327 行；行为同单币 V3 | 增 `GAP_EPS=1e3`、`SolventBadDebt()`；全平前以 `positionValue(id) < currentDebt` 为单债口径证明并用嵌套 `try/catch` fail-closed；仅 `residual > GAP_EPS` 触发门与事件 |
| 风险腿兑换滑点下限 | `_settleGap(...)`，433–470 行；`LOAN→RISK` 的 `minOut = gotLoan×95%×1e18/riskValueInLoan(1e18)`，`RISK→LOAN` 的 `minOut = riskValueInLoan(gotRisk)×95%`；强制空 path；常量 `MAX_GAP_SLIPPAGE_BPS=500`（119–122 行） | `_settleGap(...)`，456–479 行；同一 5% 口径与同名常量（128–131 行） | `_zapToBothSides(totalLoan,ticks,zapPath)` 429–440 行及 `_consolidateToLoan(got0,got1,zapPath)` 443–452 行均传 `minOut=0`，且沿用调用方 path | 对应函数 499–525 行，均传 `minOut=0`，且沿用调用方 path | 增同名 500 bps 常量；按 oracle 的 `riskValueInLoan` 对两个方向分别推导 95% `minOut`；保留调用方 path，但即使路径恶意/执行价过差也必须由合约下限回滚 |
| 部分平仓取整与事后健康 | `_dues(pos,percent,fullClose)` 396–403 行：部分应还 `(debt×percent+9999)/10000` 并封顶；`close` 380 行：未全平则 `isHealthy(id)`，否则 `UnhealthyAfterClose()` | `_dues(...)` 419–423 行委托 `LpMathExt.dues`（同样向上取整）；`close` 402–403 行做事后健康门，错误 `UnhealthyAfterClose()` | `close` 282–294 行：部分应还 `debt×percent/10000` 向下取整，平后无健康检查，无对应错误 | `close` 313–326 行：同单币 V3 | 部分应还改为向上取整并封顶 `curDebt`；转账/事件前后保持原子回滚；未全平必须 `_isHealthy(id)`，否则 `UnhealthyAfterClose()` |
| 清算参数护栏 | 构造器 `InitParams` 168–190 行：`lltv ∈ (0,1e18]`→`BAD_LLTV`；`closeFactorBps ∈ (0,10000]`→`BAD_CLOSE_FACTOR`；`liqBonusBps≤2000 && protocolFeeBps≤5000 && harvestFeeBps≤3000`→`BAD_FEES`；`minWidthTicks>0`→`BAD_MIN_WIDTH` | 构造器 169–191 行；参数、边界、错误字符串同 V3 Dual | 构造器 128–153 行直接写入上述参数，无上下界校验；它们进入 313–317 行 repay 上限与 `SettlementMath.liquidationSeize` | 构造器 130–155 行直接写入；进入 343–349 行同一路径 | 在两个单币构造器中原样加入 Dual 的四组边界与错误字符串；不修改 `SettlementMath`，不扩张到 Dual 没有的 `borrowFeeBps` 规则 |

## 行为一致性测试目标

- V3/V4 单币版均覆盖：健康仓制造真实残债时 `SolventBadDebt`；`≤ GAP_EPS` 残债不触发坏账门；oracle 无法证明时不得带真实残债退出。
- V3/V4 单币版均覆盖：开仓 `LOAN→RISK` 与平仓 `RISK→LOAN` 的执行价低于 oracle 95% 下限时回滚。
- V3/V4 单币版均覆盖：部分应还向上取整；部分平仓后不健康时 `UnhealthyAfterClose`。
- V3/V4 单币版均覆盖：Dual 的构造参数边界接受/拒绝结果一致。
