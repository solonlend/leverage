# Solon CLM 红队记录（M3）

> 范围:src/range/ 四合约 + 测试套件。基线 commit 17146d0。
> 轮次:R1 自打(下方) → Codex 异构只读复审 → R2 自打(汇总后针对性补刀)。

## R1 自打（2026-09-09）

| # | 严重度 | 发现 | 处置 |
|---|---|---|---|
| R1-1 | LOW | 公众 `harvest()` 高频重复调用会不断重置 `lastHarvest`,把既有 lockedProfit 反复拉回新的 1h 窗口,轻微压低 balances()。攻击者无利可图(每次真实 collect,无费则小费为 0,纯烧 gas);效果方向反而保守(净值低估)。上游同源 | 接受,不改 |
| R1-2 | MED(政策) | vault.withdraw / strategy 全线无重入锁(上游同源,仅 deposit 有 nonReentrant)。WETH/USDG 无回调面安全;若将来上架带 hook/777 类代币的池即成真实攻击面 | **池准入政策硬条款**:只上标准 ERC20 池。写进运维手册与 checklist |
| R1-3 | LOW | 全员退出后若策略残余资产取整到 0(微型库),`previewDeposit`/`deposit` 分母为 0 revert,金库永久拒存(烧毁份额还在)。需要资产精确归零,MINIMUM_SHARES 留存机制使其难以达成。上游同源 | 接受;监控加"金库空转"告警项 |
| R1-4 | INFO | `setTwapInterval` 只设下限 60s 无上限;owner 设超大值会使 observe 无历史而 revert,阻塞存款(owner 信任范围内)。上游同源 | 接受(owner=后续多签) |
| R1-5 | INFO | createRangeVault 将新对 ownership 转给 factory.owner()瞬时值;factory 易主后旧金库 owner 不随迁 | 运维手册注明:换 owner 时逐金库 transferOwnership |
| R1-6 | — | RT-1(见 PORT-DIFF):首存两币价值 wei 级精确相等 → alt 区间未初始化 → 除零 revert。无资金风险,上游同源 | 接受;若 Codex 也点名则加防御分支 |

R1 核对无恙项:_chargeFees 分账数学与上游同构(逐 token 同比例);treasury 零地址双闸;keeper 权限面(globalPause 可开可关,无资金动作);retireVault 全员退出闸;paused 时 withdraw 单边放行路径;minting 标志复用作 mint 回调闸(mock 场景遗留 true 无害,真池必回调清零)。

## Codex 异构复审（gpt-6-astra,effort high,只读）

声明改动外 diff:clean;金库份额移植逐行:clean;权限/接线:clean;原币分账数学:clean。6 项发现:

| # | 严重度 | 发现 | 处置 |
|---|---|---|---|
| C-1 | **MED** | **取款也要 calm**(上游 zk 硬化的副作用):withdraw 尾部 re-add 走 `_addLiquidity(onlyCalmPeriods)`,风暴期未暂停时用户被困——恰在最想跑的时候跑不掉。我的 FK4 测试因早退分支虚绿,没抓到 | **已修(决议外 fork 改动#3)**:NotCalm 时跳过 re-add,资金闲置策略内可取,下一个 calm 动作自动重新入池。FK4 重写为确定性触发(阈值收 1 tick+递增推价),新断言:NotCalm 拦存款/放取款/闲置/恢复后 re-add,fork 实测过 |
| C-2 | LOW | 空 harvest 高频调用不断重置锁定窗口(量化:每分钟一次,1 小时后仍有 ~36.5% 利润被锁) | 接受(=R1-1):攻击无利可图纯烧 gas,效果方向保守(净值低估不高估)。keeper 正常节奏下无感 |
| C-3 | LOW | factory 易主不迁移既有策略 ownership | =R1-5,运维手册条款 |
| C-4 | LOW | RT-1 可达性比我标注的高:攻击者可故意构造 amount1=floor(amount0×price/1e36) 精确平衡,阻塞首存 | **已修(决议外 fork 改动#4)**:`_setAltTick` 末分支 else-if→else,平衡态确定走 token0 侧;新单测 F7 覆盖 |
| C-5 | INFO | 测试吞错:守恒 fuzz 对取款 try/catch、FK4 有早退虚绿 | **已修**:FK4 去早退+强制 NotCalm;守恒 fuzz 主路径(alice)改硬调用,粉尘路径保留 catch(拒付粉尘是设计行为) |
| C-6 | INFO | 未测行为清单:锁定期多用户会计、双币费分账精确性、回调型代币、ownership 交接、retireVault | **桩清单**(下方) |

附:factory 字节码在 Robinhood 96KB 上限内(Codex 核对)。

## R2 处置汇总与桩清单

**本轮新增 fork 改动(决议外,均已报备/将报备用户)**:#3 withdraw NotCalm 跳过 re-add;#4 _setAltTick 平衡态分支。PORT-DIFF 同步更新。

**遗留桩处置(2026-09-09 R2 收尾)**:
- [x] 锁定期多用户会计 fork 测试 → FK6:harvest 制造活跃锁定,锁定期中途入金者本金回环 >99%、吃不到存量费;全退后金库只剩烧毁份额
- [x] 双币费分账精确断言 → FK2 两侧独立 19:1 断言+至少一侧有实质费量的哨兵断言
- [x] retireVault 单测 → F8:有外部份额拒退役/清空后资金扫 treasury/所有权烧毁
- [ ] 回调型代币:政策排除(R1-2),不写码——池准入条款
- [ ] 空 harvest 锁窗重置:接受,产品文档注明 keeper 节奏
- [ ] ownership 批量交接:运维手册条款(C-3/R1-5)
