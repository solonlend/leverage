# Solon CLM(Auto LP)RH 主网部署 — 2026-09-11

链: Robinhood Chain (4663) · deployer/governor/treasury: `0xD034…cC84` · keeper: `0xB606…210e`
KousanS 拍板("部署吧" 2026-09-11);A 段默认值;B 段冻结核查通过(src/range 零改动 since 7327fe5)。

## 地址(createRangeVault 事件解码 + cast 互指复核)

| 合约 | 地址 |
|---|---|
| RangeVaultDeployer | 0xdbdf878f739011db619faa178ec9cb16c8a75da9 |
| RangeStrategyDeployer | 0xe11cd05c69b20407aa0ed3f246c25db9c8709662 |
| RangeFactory | 0x9dad908f3f94552f821ed6a46f680c937fdd4197 |
| **SolonRangeVault** | **0xfd7Ab6A724f28cE958Ee29E7A9DfAE7b9efC6B91** |
| **RangeStrategyUniV3** | **0x6F7343369d9AaFFC45d790b64E9543A8c804E844** |
| Pool (旗舰 ETH/USDG 0.01%) | 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca |

部署块 60232418-60232505;8 笔全 status 1;gas 实付 0.00165 ETH(fork 演练估 0.0023)。
参数:width 500(±5%) · deviation 30 · fee 10%/caller 5% · 种子 0.02 WETH + 50 USDG → 99,171,356 shares(≈$99)。
read-back:vault↔strategy 互指 ✓ pool ✓ treasury=governor ✓ getFees=(1e17,5e16) ✓ isCalm ✓。

## C.3 烟测(真钱,keeper EOA 当外部用户)

| 步骤 | 结果 |
|---|---|
| 资金:deployer→keeper 0.004 WETH + 0.0008 ETH gas;router 换 0.002 WETH→4.915 USDG | 全 status 1 |
| 单边 WETH 预览 | 全零(金库缺 USDG 侧)——失衡语义实证,与 AUTO-LP-GUIDE 一致 |
| 双边定额入金 ×2 | TooMuchSlippage revert:**池速>预览-广播延迟,固定 take+99/98% minShares 必然过期**(公共 RPC 慢) |
| 单边 USDG 现预览即发 @95% | ✓ 4,923,337 shares(≈$4.92,balancing fee 247 raw) |
| 第三方 harvest(deployer 调) | ✓ 0xd9431c84…f1d35 |
| withdrawAll @95%/币 | **revert(status 0)**:±5% 带内币种配比漂移快于逐币 95% 下限——真实教训 |
| withdrawAll @80%/币 现预览即发 | ✓ 0xdd91d077…78d861,收 0.000972 WETH + 2.534 USDG,shares 归零 |
| 往返经济性 | 存 $4.92 → 回 $4.91,损耗 ≈$0.005(失衡费+配比漂移) ✓ |

**运营结论(写进 keeper/前端参数依据)**:旗舰池速度下,CLI 逐币 95% 下限不可靠;前端抽屉(预览→点击秒级)99% 仍合理,agent/脚本路径建议 80-90% 且现预览即发。AUTO-LP-GUIDE 的 minOut 建议需补此实测注记。

## 上线状态

- 前端 cfg 已填(deployBlock 60232400),生产已部署,详情页 LIVE:Net APR 45.94%(live feed)、TVL $99.23、区间/地址/费用全渲染 ✓
- positions/history feed RH 条目已加(后台首跑中)
- 待办:keeper launchd 实弹、monitoring CLM 项、addresses.json+skill push、公告
