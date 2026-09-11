# 杠杆 CLM 金库:降低大仓位开/平/再平衡损耗 — 技术调研结论

> 2026-09-04。回答 KousanS 的问题:"大仓位开平损耗大、仓位不适合要换区间怎么解"。
> 一手读源码 + 外部主流协议调研。落地设计以此为据,先 review 再 TDD。

## 0. 一句话结论

主流 CLM(Charm/Gamma/Arrakis/Steer/Beefy)**都不做"整条腿往返"**,统一是:
**全撤 → 链下算出达到目标比例所需的净 swap → 只换这一笔净额 → 重铺(零头用单边 limit 仓吸收)**;
入金/出金一律**双币 in-kind、免 zap**。"只换 delta"指的是 **swap 环节**,且 `swapAmount` 由**链下 keeper 算好传参**,合约不自算。
我们的增量只在于叠一层"**债务不参与再平衡**"的分层设计。唯一对口的本地参考是 **CharmAlphaVault**,可直接作合约骨架蓝本。

## 1. 损耗根因(复述,已确认)

大仓位损耗几乎全在 **zap 那笔兑换的价格冲击**,不在 LP 本身。当前设计两处放大损耗:
- 开/平各一次全额 zap(USDG↔WETH),仓位越大冲击越大;
- 无原地再平衡 → 换区间只能 close+open = **两次全额 zap**,损耗翻倍。
LP fee 和 gas 是地板省不掉;能省的全是 swap。

## 2. 一手源码发现(CharmAlphaVault,唯一对口参考)

**rebalance(swapAmount, sqrtPriceLimitX96, 新区间 ticks…)** 三段式:
1. `_burnAndCollect` 撤掉全部两个仓位;
2. 若 `swapAmount!=0`,`pool.swap(this, zeroForOne, |swapAmount|, sqrtPriceLimitX96)` — **只做一笔净额 swap**,方向/量由 swapAmount 符号决定,`sqrtPriceLimitX96` 即滑点保护;
3. `_liquidityForAmounts` + `_mintLiquidity` 重铺 base 仓,单边零头用 bid/ask 里较大的一侧铺 limit 仓。
→ **合约不算"换多少",swapAmount 是入参,由链下 strategy/keeper 算。**

**deposit(a0,a1,min0,min1,to)** 双币 in-kind:`_calcSharesAndAmounts` 用 `cross=min(a0·total1, a1·total0)` 反推真正收取量,**严格按金库当前 (total0,total1) 比例收**,多余那币不收 → **零 swap、零滑点**。

**withdraw(shares,…)** 按 `shares/totalSupply` 出**双币** + 手续费份额,不归并单币。

**触发阈值不在金库层**:在独立 PassiveStrategy —— `now≥lastRebalance+period` 且 `|tick−lastTick|≥minTickMove` 且过 `maxTwapDeviation/twapDuration` TWAP 校验,keeper 才调 rebalance。**分层要照抄**。

其余本地参考(vault-v2=借贷 curator 金库、earn-basic-app/pilot-bera=前端、clawd/rescue-lp=V2 LP 救援)与 CLM 再平衡无关。

## 3. 外部最佳实践

- **净额 swap 公式(链下算,一阶近似)**:全撤后持有 `(B0,B1)`,目标区间在现价下需比例 `R=amount1/amount0`,`p`=token1/token0 现价;token0 过剩时换出 `s ≈ (R·B0 − B1)/(R + p)`(s>0 换 token0,s<0 反向),代回 `getLiquidityForAmounts` 迭代 1–2 次修正冲击。这就是传进合约的 swapAmount。
- **Gamma 新版把 swap 从 rebalance 剥离**:rebalance 只重铺,换币走独立步骤/外部聚合器 → 便于走最深池 + 私有 mempool 降滑点。**swap 与 LP 解耦是大仓位关键。**
- **Arrakis V2 SimpleManager**:removeLiquidity→白名单 Router swap→**校验收到量 minOut + 池价偏离检查**→addLiquidity,防 operator 单次 rebalance 过度损失。
- **Beefy CLM alt 仓技巧**:主仓精确 50/50,单边零头做 single-sided alt 仓,**避免"靠卖跑赢币配平"当场兑现无常损失**。
- **大额执行**:分片/TWAP 摊薄冲击;私有 mempool(Flashbots Protect/MEV Blocker)防三明治 —— 定时 rebalance 是已知 MEV 猎物;swap 带 minOut/sqrtPriceLimit;聚合器选最深池。
- **触发**:out-of-range 阈值 + minTickMove 偏离带 + period 冷却 + TWAP 偏离门禁,组合满足才动。

## 4. 对我们杠杆金库的可落地建议

1. **金库层照抄 Charm 三段式** rebalance:撤全部→单笔净额 swap(带 sqrtPriceLimit+minOut)→重铺;swapAmount 由 keeper 传参,合约不自算。
2. **swap 与 LP 解耦**:换币做成可走外部聚合器/最深池 + 私有 mempool 的独立步骤;净额用上式迭代算。
3. **入/出金强制双币 in-kind,禁 zap**;大额零头用单边 limit 仓吸收。保留单币 zap 入口只给小额散户便利。
4. **触发放策略/keeper 层三重门禁**(minTickMove + period + maxTwapDeviation);金库只留一个 keeper 权限的 rebalance 入口。
5. **【我们的核心增量】杠杆/债务分层 —— 再平衡不动债务,只调 LP**:
   - rebalance 是库存中性操作:撤 LP→换净额→重铺,USDG 债务本金与欠息全程不变;健康度只随价格变、不因 rebalance 变。
   - "LP 再平衡循环" 与 "债务/杠杆管理循环(借更多/还款/去杠杆)" 彻底分成两条独立路径,触发条件各异。
   - 清算路径必须能**不依赖 keeper rebalance** 独立撤 LP 还债(对标 Charm emergencyBurn + Morpho forceDeallocate 的强制退出),否则 keeper 失灵无法清算。
   - **杠杆场景下私有 mempool + 分片 + minOut 是硬需求不是可选**:带债务的 rebalance 被三明治,滑点直接侵蚀抵押、逼近清算线。
6. **风控借鉴 Morpho Vault V2**:id-based 绝对/相对 cap + timelock + forceDeallocate 式付费强制退出,约束单池敞口、保证可提款性。

## 5. 提议的落地范围(待 review)

- **v1(先做,砍损耗大头)**:① 双币 in-kind 入/出金路径(跳过 zap);② keeper 权限的 `rebalance(swapAmount, sqrtPriceLimit, minOut, 新区间)`,债务不动,末尾健康校验;③ 净额 swap 的链下计算(keeper 侧,复用 FairLpMath.zapSwapAmountToToken0 的价值比例)。
- **v1.5**:swap 与 LP 解耦走聚合器 + 私有 mempool;单边 limit 仓吸零头;触发策略层(deadband/period/TWAP)。
- **v2**:分片/TWAP 大额执行;单池 cap 风控。

来源:CharmAlphaVault 本地源码 · Gamma(Consensys 审计)· Arrakis V2 docs · Beefy CLM docs · Steer docs · Flashbots/MEV 综述。
