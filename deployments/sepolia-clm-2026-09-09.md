# Solon CLM Sepolia 实链演练 — 2026-09-09

链: Sepolia (11155111) · deployer/keeper/treasury/rebalancer: `0xe3c5…9922` · commit: 7327fe5
池: 既有 WETH/USDG mock fee100 `0x81ffB0C7127e90212f85cc825e9ecA8056A28A02`(2026-09-06 dual 部署同池)

## 关键发现(本次演练的最大价值)

**首版单体工厂 34.6KB 被 Sepolia 按 EIP-170(24KB)拒绝**——CREATE tx `0x950577d2…` status 0;RH 限宽(96KB)所以 fork 演练未暴露。且 forge broadcast 的 hash↔tx 映射错位,后续调用打在无码地址上"假成功",极具迷惑性。修复:拆出 RangeVaultDeployer/RangeStrategyDeployer 两个创建码持有合约(Uniswap pool-deployer 同款),工厂 34.6KB→3.3KB,全部产物 <24KB,任何链可部。

## 地址(重部后)

| 合约 | 地址 |
|---|---|
| RangeFactory | 0xE51fFB9F04Ff812f2A8838A256e0C42E5898E2c5 |
| SolonRangeVault | 0x7C0cCcCB2C41e3DE01b4cB0Ba7d0EbdA11bb3701 |
| RangeStrategyUniV3 | 0x8352d9Df9006c21Cfc4dCaeBA8ec91Dae4Af8F4F |

参数: width 500(±5%) · deviation 30 tick · fee 10%(caller 5% of fee) · 种子 1 WETH + 2500 USDG(shares 5000000009)

## 全生命周期实链交易(全部 status 1)

| 步骤 | tx |
|---|---|
| 池 observationCardinalityNext→120(生产 runbook 项实战) | 0x618dafb4…50db9 |
| TWAP 观测预热 swap ×2(间隔>120s) | 0x11a25e86…c8394 / 0x8b6ca78d…690ae |
| 部署+种子(forge script) | broadcast/DeploySepoliaClm/11155111/run-latest.json |
| 用户(aux1)存款 0.5 WETH+1250 USDG → 2499999989 shares(精确比例) | 0x5cf57769…9f5de |
| 生费 swap ×3 | 0x03e6e015… / 0x61749629… / 0xa3d1babc… |
| **NotCalm 实拦**:推价后 aux2 harvest 被拒(门控真链生效) | (revert,无哈希) |
| calm 恢复后 aux2 公众 harvest:小费 785807617018 wei WETH + 3934 USDG;treasury 74755 USDG(=19.0×小费 ✓) | 0xa9301cfa…02a2d |
| 推价 +2832 tick 后 moveTicks 重铺:(-198580,-197580)→(-196248,-195248),现价 -195748 居中 ✓ | 0x09b22740…f993d |
| aux1 半仓取款 | 0x6751d19d…78a29 |
| aux1 全退:收 2531.6 USDG+尘 WETH(价格上行 32.7% 期间 LP 自然换仓,IL 符合模型);totalSupply 精确回到种子 5000000009 | 0x6d001177…92520 |

## 结论

存款/份额/滑动费/公众收割分账/calm 门控(拦+放)/moveTicks/部分与全额取款/供给守恒——全部在真链验证通过。CLM 合约层达到可部 RH 主网标准;RH 部署仍走 LAUNCH-CHECKLIST-CLM.md A 段拍板流程。
