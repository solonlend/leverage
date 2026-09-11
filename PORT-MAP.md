# Extra → Solon 杠杆 LP 移植地图

> **状态 2026-09-04**:SwapExecutorV3 ✅(生产合约+8单测,fork e2e 在用);LendingPool ✅(Extra 原样 vendor 进 `src/lending/` + SolonVaultRegistry 实现 IVaultFactory,集成测试 3 条 + V3 fork e2e 已全真——真池借款/计息/还款/出借人赚息);金库生命周期事件 ✅(PositionOpened/Increased/Closed/Harvested/Liquidated + ERC-721 Transfer + nextPositionId,两金库同签名,8 条事件测试);清算 keeper ✅(独立包 `../keeper/`,TS+viem,math 与 SettlementMath 逐式对齐,14 单测,默认 dry-run)。部署脚本 ✅(`script/DeployRhV3.s.sol`,anvil fork 演练通过,真部署待用户拍板);keeper anvil-fork 全链路 ✅(部署→入金→开仓→dry-run 识别→实弹清算,债务 8000→4000,keeper 净赚 326.89 USDG);开仓/加仓健康检查 ✅(修复:此前可秒开可清算仓位置出借人于险地,现 UNHEALTHY_OPEN/UNHEALTHY_INCREASE 拦截)。待办:真部署(用户拍板)、V4 原生 swap(v1.5)、完整 ERC-721(可转让,现只有 Transfer 事件)、前端。注:健康检查修复后,fork 演练里造不健康仓需改走 mock 预言机或推价,不能再靠超借。
> **红队 2026-09-04**:见 `RED-TEAM-2026-09-04.md` —— 修 3 问题(open/increase 健康卫、compound 零头、ZERO_LIQ),20 万次调用不变量 5/5,攻击重放 6/6;种子存款为上线硬前置;残留风险清单在报告内。

> 2026-09-03 定。fork ExtraFi/extra-contracts(MIT),把 DEX 层从 Velodrome CL 换成 Uniswap V3(v1)/ V4(v1.5)。

## 关键发现:难度砍半

Velodrome CL(Slipstream)**本身是 Uniswap V3 的分叉** —— 同样的集中流动性、tick 区间、NFT 仓位。
所以 Extra 已经在一个"V3-fork"上做好了杠杆集中 LP 的**全部难点**(集中仓位估值 + tick 清算数学 + 出区间处理)。
我们不是重建这些,是把 DEX 接口从 Velodrome 换成官方 Uniswap V3 —— 同源,调用近乎 1:1。

## 原样复用(不改)

- `LendingPool.sol` — 出借池(存 USDG 收息、借款、利率模型)
- `VaultFactory.sol` — 每用户仓位工厂
- `ExtraInterestBearingToken.sol` — 出借凭证
- `StakingRewards.sol` — 代币激励(正好是"额外代币奖励"那块)
- 整个 `libraries/` — 利率、精度、数据结构
- `Payments.sol`、`AddressRegistry.sol`

## 要改:VeloVault 实现 → UniV3Vault(逐函数)

DEX 交互都在 Vault 实现里(VeloPositionManager 只是薄路由,保留)。逐个函数移植:

| Velo 函数 | 干什么 | 换成 Uni V3 的点 |
|---|---|---|
| `newOrInvestToVaultPosition` | 开仓:借款 + mint 集中 LP | Velo CL NFT manager → Uniswap `NonfungiblePositionManager.mint`;两边平衡校验;tick 区间入参 |
| `closeVaultPositionPartially` | 平仓:burn + 还款 + 结算 | → `decreaseLiquidity` + `collect` + `burn`;zap 成单币还用户 |
| `liquidateVaultPositionPartially` | 清算 | 复用框架,估值换成我们的抗操纵预言机(TWAP+Chainlink,见 LpShareOracle.sol) |
| `investEarnedFeeToLiquidity` | 复投手续费 | → `collect` + 重新 mint/increase |
| `closeOutOfRangePosition` + `setRangeStop` | 出区间处理 | Velo 已有此机制,直接沿用逻辑,换 DEX 调用 |
| `getVaultPosition` | 读仓位估值 | tick+liquidity → `LiquidityAmounts.getAmountsForLiquidity`(V3 同源) |

## 清算估值(唯一真自研,安全命门)

- LP 仓位价值必须用**抗操纵公允价**(TWAP + Chainlink 交叉),不用 spot —— 见 `src/LpShareOracle.sol` 的设计。
- Extra 的清算框架 + 我们的公允估值 = 安全的清算。
- 红队:差分测试 vs Python golden + fuzz + 重放 Alpha Homora 攻击,上主网前必过。

## 清算执行

- 复用今天部署的 morpho-blue-liquidation-bot(改成盯 Extra 仓位事件;拆单/深度逻辑照用)。Extra 清算是白名单制,keeper 进白名单即可。

## 顺序

1. fork Extra,LendingPool/Factory 部署到 RH(RH 是 Arbitrum Orbit,Extra 本就跑 OP/Base L2,兼容)
2. 逐函数把 VeloVault 改成 UniV3Vault(上表)
3. 清算估值接 LpShareOracle(公允价)
4. TDD + 红队 + 测试网重放攻击
5. 前端(Extrafi 风格发现表 + 一键 zap 开平)
6. V4 版排 v1.5

## 已拉到本地参考

- `reference/CharmAlphaVault.sol`(LP 估值参考)
- `reference/MorphoLeverageSnippet.sol`(杠杆循环 + 预言机写法参考)
- `reference/extra/{VeloPositionManager,IVeloVaultPositionManager,VaultTypes}.sol`

## 仓位凭证:Solon 仓位 NFT(他 2026-09-03 定,解决"仓位显示尴尬")

- 开仓 mint 一张 Solon 仓位 NFT(ERC-721)给用户 = 杠杆仓位所有权凭证。把 Extra 内部的 manager/owner 归属(transferManagerOfVaultPosition)做成 NFT。
- 两层 NFT:底层 Uni LP NFT 锁金库当抵押(用户碰不到);上层 Solon 仓位 NFT 在用户钱包(可见/可转让/可交易)。
- 查询:钱包能看到 NFT → 界面用它读仓位 → 渲染 LP价值/杠杆/健康度/PnL。
- 平仓:持 NFT → 验证 → 平仓+还款+zap 单币 → 销毁 NFT。
- 权限=持有即所有,最干净;清算作用于 NFT 对应仓位,持有人承担。
