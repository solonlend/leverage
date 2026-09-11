# 单币清算移植对照（修改前）

| 来源函数 | 原有单币函数 | 修改后行为 | 差异适配 |
| --- | --- | --- | --- |
| UniV3DualVault.liquidate:595 `_collectFees` → `_skimHarvestFee` → remove → 加回净费 | UniV3LeverageVault.liquidate:361 直接 remove | 撤 LP 前领费并抽成，净费并入撤仓所得 | dexTokenId；净双币统一兑换 LOAN |
| UniV4DualVault.liquidate:564 同上 | UniV4LeverageVault.liquidate:393 直接 remove | 同上 | v4TokenId；collect 传 deadline |
| 两个 Dual._payoutLiquidation `_repayLeg` 返回实际还款额后计算退款 | 两个单币 liquidate 第二笔 repay 忽略返回值并减请求额 | excess 减实际 repay 返回值，剩余退款 | 单币仍直接退 LOAN |

执行：先 fee 部分/全额清算 RED → 移植 fee → GREEN；再第二笔实际还款 RED → 修扣账 → GREEN。全量非 fork 与四金库体积由主代理统一验证。
