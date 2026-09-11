# Solon CLM(Range Vaults)上线 Checklist

> 2026-09-09 创建。范围:RangeFactory + WETH/USDG fee100 首发对。软启动,与杠杆金库资金完全隔离。
> 红线同主表:私钥不进任何输出;每项"完成"要链上/命令证据;`forge script --broadcast` 是真交易,只在 KousanS 拍板后执行。

## A. 拍板项(人)

- [x] A.1 部署时间窗(2026-09-11 12:2x UTC;ETH/USDG 为加密对,无股票开市约束)(建议开市时段,与杠杆金库同标准)
- [x] A.2 种子 0.02 WETH + 50 USDG(gas 实付 0.00165,未补 ETH——RH 实际费率远低于预估)(部署者现持 0.0501 WETH / 50.56 USDG,够;gas 需 ≥0.005 ETH,现 0.007 附近,**建议先补 0.005 ETH**)
- [x] A.3 keeper=0xB606…210e(现网唯一 keeper EOA;双 EOA 名单实际只有一个,记录在案)(默认=现有 dual keeper 双 EOA)
- [x] A.4 treasury=governor 0xD034…cC84(与杠杆同)(建议与杠杆金库同收款地址)

## B. 冻结前验证(agent)

- [x] B.1 全量回归:离线 345/345 + fork 6/6(2026-09-09,commit cdc9723);**2026-09-10 在最终 commit(含 7327fe5 EIP-170 拆分)重跑:离线 345/345 + RangeClmFork 6/6 全绿**——动合约全量重测纪律闭环
- [x] B.2 红队:R1 自打 6 项 + Codex 异构 6 项,2 修 4 接受,记录在 RED-TEAM-CLM-2026-09-09.md
- [x] B.3 fork 演练:DeployRangeClm 模拟通过(接线 read-back 全对,种子 99906445 shares,gas est 0.0045 ETH)
- [x] B.4 公开仓同步:2026-09-10 push origin/main(HEAD 见 git;部署 commit 哈希部署日再记入部署记录)
- [x] B.5 冻结:部署时 src/range 零改动(since 7327fe5):B 完成后到部署完成前合约零改动

## C. 部署日(人+agent)

- [x] C.1 fork 演练+实链广播 8 笔全 status 1(2026-09-09 拆分 deployer 后全部产物 <24KB,已不需要 --code-size-limit;Sepolia 实链验证)
- [x] C.2 read-back 全对(脚本自带 require)+ 手动 cast 复核 factory/vault/strategy 三地址
- [x] C.3 烟测(真钱):单边存$4.92→第三方harvest→全退到账;两条实测教训见部署记录:外部地址 deposit ~$20 → 查份额 → harvest(第三方地址调,验 caller 小费到账)→ withdrawAll → 到账
- [x] C.4 部署记录 deployments/rh-mainnet-clm-2026-09-11.md deployments/rh-mainnet-clm-<date>.md

## D. 运维(当天)

- [x] D.1 keeper 实弹 launchd(xyz.solonlend.rangekeeper)已跑,首 tick 健康:`keeper/range.mjs`(6h 定时+出区间触发+calm 前提+OOR 告警+心跳文件,DRY_RUN 对 Sepolia 实测过);部署日配 launchd 常驻+实弹 key
- [ ] D.2 monitoring daemon 加 CLM 项:仓位在池/区间覆盖现价/TWAP 偏差/未收 fee 堆积/金库空转
- [x] D.3 告警路由接策略群,测试告警已达
- [ ] D.4 运维手册条款:池准入只上标准 ERC20(R1-2);factory 易主需逐金库 transferOwnership(C-3);keeper harvest 节奏写明(C-2)

## E. 表面(验证后)

- [x] E.1 addresses.json rangeVaults 主网已填(push 后生效):`solon-skill/tools/solon-range-read.mjs`(对 Sepolia 真金库实测过:TVL/份额/区间/calm/账户 previewWithdraw);addresses.json 与 mainnet 实测待部署日
- [x] E.2 Farm UI 已上线(5d0af74):交互模块 UE 级走查过(真钱包存取+移动端);RH 显 coming-soon,填地址即点亮
- [x] E.3 官网三卡分层(4aa6629)+docs overview 段(bc0e21c)已部署并 curl 验证;正式产品页细化(含 out-of-range 敞口说明)随主网上线补
- [ ] E.4 公告(烟测闭环后)
- [ ] E.5 每项:build → rsync → curl 线上验证(push≠上线)
