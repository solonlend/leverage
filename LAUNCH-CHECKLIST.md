# LP 正式环境上线 Checklist(总控)

> 2026-09-07 创建。这是**上线总控清单**,包住 `DEPLOY-CHECKLIST.md`(合约部署逐项)——那份照旧从阶段 0 打勾到阶段 5,本清单管它前后的一切。
> 首发范围:**UniV3DualVault(WETH/USDG fee100)单金库**。V4 与单币金库不在首发(Sepolia 只实战验证了 dual-v3;V4 走 D.8 专项后另行上线)。
> 红线:私钥绝不进聊天/日志/提交/环境快照;每一项"完成"都要有链上或命令输出证据。

---

## A. 上线前置 — 需要拍板/提供的(当前 blockers)

| # | 项目 | 状态 | 说明 |
|---|---|---|---|
| A.1 | **Safe 多签** | ⛔ 等签名人地址 + 阈值 | RH 链(4663)上部署 Safe;所有 owner/governor 交给它(阶段 2.12/4.1)。建议 2/3。**没有多签就不上线** |
| A.2 | **资金到位** | ⛔ 等打款 | 2026-09-07 拍板:沿用 RH 主网原部署者 `0xD034…cC84`。fork 演练实测缺口:①gas——部署估算 **0.0100 ETH**,现有 0.0070,**需补 ≥0.005 ETH**;②种子 **1000 USDG + 0.5 WETH**(现仅 1.97 USDG / 0 WETH,**全额待打款**);③keeper 垫款(keeper 暂=部署者,首发容量下建议另备 ~500 USDG + 0.25 WETH);④烟测小额(~80 USDG + 0.03 WETH,fork 烟测实际用量 0.02 WETH+50 USDG 自投) |
| A.3 | **上线时间窗** | ⛔ 待定 | 选**美股开市时段**(ETH feed 偏差触发活跃、最新鲜),避开周末(周末 feed 停摆是已知特性,清算演练也要开市做) |
| A.4 | **要不要再买一轮外部审计** | ⛔ 待拍板 | DEPLOY-CHECKLIST 红线原话:"真钱上线前,再买一轮外部审计"。现状:5 轮红队 + Codex 异构复审 + 296+9 测试 + Sepolia 实链清算演练。选项:(a)买审计再上;(b)接受现状,以**极小容量**(现定 1000 USDG/0.5 WETH)软启动即"用小钱当审计"。二选一,记录在案 |
| A.5 | 私钥纪律 | ✅ 规则已立 | deployer/keeper key 本地生成、0600 存 `~/.config/solon/`;命令里只用 `$(cat ...)` 注入,输出一律脱敏;交权多签后 deployer 除历史记录外无任何权限;上线后 deployer 剩余 gas 归集走一笔干净转账 |

## B. 代码与参数冻结(上线前 24h,执行:agent)

- [ ] B.1 `leverage` 全量回归:`forge test --offline --threads 1 --no-match-path 'test/fork/*'` 全绿;fork 套件带网另跑全绿
- [ ] B.2 keeper 测试套件全绿;monitoring 105 测试全绿
- [ ] B.3 部署 env 文件定稿:8 个必填参数 + 4 个软启动容量/授信 + oracle 3 项,逐项对照 DEPLOY-CHECKLIST 阶段 1 的**已确认值**填写(LLTV 0.77e18 / liqBonus 700 / protocolFee 0 / harvest 1000 / closeFactor 5000 / 利率 (0,0,9000,400,20400) / staleness 93600·93600 / depeg 50 / capacity 1e9·5e17 / credit ≤8e8·≤4e17 / seed 1000e6·0.5e18)。env 文件存本地不入库
- [ ] B.4 anvil fork RH mainnet:`DeployRhDual` 全流程演练(fork 广播)→ `VerifyDeployment` 通过 → 烟测脚本(开仓/加保证金/rebalance/平仓/清算)fork 上全走通
- [ ] B.5 公开仓 `solonlend/leverage` 与本地部署 commit 完全一致(开源承诺;部署 commit 哈希记入部署记录)
- [ ] B.6 冻结:B 完成后到部署完成前,合约与脚本**零改动**;改一行=B 重来(合约改动纪律)

## C. 部署日执行(照 `DEPLOY-CHECKLIST.md` 从头打勾)

- [ ] C.1 阶段 0:外部地址逐个链上核对(feed description 亲眼看)
- [ ] C.2 阶段 1:参数环境变量与已确认值逐项对照
- [ ] C.3 阶段 2:按序部署 + 每步 read-back(含 D.1~D.3 dual 专属)
- [ ] C.4 阶段 3:`VerifyDeployment` 一条命令全量核对通过
- [ ] C.5 阶段 4:权限移交多签(VaultRegistry 两步 accept 完成)+ keeper 双 EOA 白名单 + 应急权限确认
- [ ] C.6 阶段 5:小额真钱烟测闭环(open→harvest→部分平→全平),**开市时段做一次真实清算演练**(人为小不健康仓)
- [ ] C.7 部署记录落盘 `deployments/rh-mainnet-<date>.md`:全部地址、部署 commit、参数快照、烟测交易哈希

## D. 运维带起(部署当天)

- [ ] D.1 keeper:`pnpm start:dual` 以 `DRY_RUN=true` 常驻(screen/launchd 保活),双 EOA 都跑、都有告警
- [ ] D.2 monitoring daemon 常驻:health/feed 新鲜度/脱锚/利用率/BadDebt/SurplusRetained 全量监控
- [ ] D.3 告警路由定版:发到哪个 TG bot/群(建议复用策略群模式,主聊天不刷屏)+ **打一发测试告警验证链路通**
- [ ] D.4 DRY_RUN 观察 2~3 天,would-liquidate 与手算一致后 keeper 实弹
- [ ] D.5 头 72h 值守:监控面板谁看、多签人响应预期写清楚

## E. 表面同步(C+D 验证通过后,执行:agent)

- [ ] E.1 `solon-skill/addresses.json`:`leveragedFarms.robinhoodMainnet` 填真实地址,`status` 改 live、`verifiedAt` 填当日;SKILL.md/FARM-GUIDE 里 "mainnet TBD" 措辞同步;skill 三件套工具(read/sim/market)**指着 mainnet 真金库实测一遍**再 push
- [ ] E.2 Farm UI:`solon-farms.ts` 换 mainnet 地址,e2e 走查,前端发布
- [ ] E.3 官网 status/首页:TESTNET LIVE → 主网 live,带日期,逐句核对不超售
- [x] E.4 公告:上线推 09-07 05:17 UTC 已发(卡片+推文);09-08 追加 day-1 运维进展推(live fee APR/监控/工具复验,用户审过文案与配图)——https://x.com/Solonlend/status/2097274025680736648
- [ ] E.5 合约开源页/文档链接检查(全部指向 solonlend 公开仓)

> **教训(2026-09-07):git push ≠ 上线。** E 段每项"完成"必须:build → rsync 到服务器 8.209.235.70(`/var/www/solon/{site,app}`)→ curl 线上验证真变了。曾把 push 当发布,被抓两次。

### E.6 Farm 应用主网双金库重构(完整版,2026-09-07 用户拍板)

**问题**:morpho-lite Farm 应用当初按"Sepolia 单金库 playground"写死——`solon-farms.ts` 的 `SEPOLIA_PLAYGROUND` 全局配置被 5 处引用(`farm-positions`、`use-reserve-rates`、`use-farm-paused`、`use-farm-protocol`、`farm-lending-vaults`),`farm-positions` 只认单个 `P.vault`。SOLON_FARMS 表只是展示目录。主网上线后交互层(开仓/管理/利率/存款)仍读 Sepolia。

**完整版目标**:Farm 应用在主网真正支持**双腿+单腿两个金库**交互。

- [ ] E.6.1 全局 farm 数据配置从 `SEPOLIA_PLAYGROUND` 重指主网(chainId 4663、lendingPool `0xA4af…91Dd`、oracle `0x52b5…Ef0f`、pool `0x52e6…71Ca`、WETH/USDG、explorer blockscout);保留 `SEPOLIA_PLAYGROUND` 仅供 `farm-testnet-playground`(测试网专用,主网隐藏)
- [ ] E.6.2 `farm-positions` 支持两个金库:双腿 `0x9Db7…8ce0`(vaultId 1,reserveRisk 2/reserveLoan 1,有 addMargin/rebalance)+ 单腿 `0x9e10…C3aE`(vaultId 2,只借 USDG,无 addMargin/rebalance,close 用 CloseParams 单币)。按金库形态渲染对应操作(dual vs single ABI/参数不同,不能混用)
- [ ] E.6.3 出借侧 `farm-lending-vaults` 指主网 LendingPool、去掉 mock mint(`testnet` 标志已加);展示两储备真实 cash/rate/credit
- [ ] E.6.4 `use-reserve-rates`/`use-farm-paused`/`use-farm-protocol` 全部走主网配置
- [ ] E.6.5 **测试网/fork 先验证**每条交互(开/加保证金/rebalance/平,双腿+单腿)跑通,再 build → rsync → curl 线上确认
- [ ] E.6.6 单腿若 UI 交互一期做不完,明确标"单腿只读/即将开放",不给坏按钮;不半修上线

## F. 应急预案(上线前书面确认)

- [ ] F.1 熔断权限:`freezeReserve`/`deActivateReserve` 在 governor(首发=部署者 EOA,A.1 跳过多签);触发条件写明——BadDebt 事件、feed 停摆超阈值、USDG 脱锚出带、池深骤降(对照 0.6 基线)
- [ ] F.1b SwapExecutorV3 应急闸:`revokeRouterApproval` 的 owner **永久=部署者 EOA(immutable,不可移交)**;将来引入多签后此闸仍在部署者钥匙上,预案须写明该钥匙的保管与使用条件
- [ ] F.2 缩容路径(不伤存量):`setReserveCapacity` 降至已用量 + 授信降 0 = 停新仓;存量仓位正常平仓
- [ ] F.3 keeper 双活:任一 EOA 掉线告警;垫款低于阈值告警
- [ ] F.4 决策链:异常 → TG 主通道 → 多签人执行;多签响应时间预期(建议 ≤2h,与 26h staleness 和 DRY_RUN 缓冲匹配)

---

**执行顺序:A(人)→ B(agent)→ C(部署日,人+agent)→ D(当天)→ E(验证后)→ F 贯穿。**
A 的四项不齐,B 以后全部不动。
