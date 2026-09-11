# DESIGN — Farm 页双 tab 拆分 v1（Leveraged / Range）

> 2026-09-09。状态:**待 review,过了再改码**。
> 背景:用户指出杠杆 farm 与 Range Vaults 堆在一页,风险性格相反的两个产品共享滚动条,新用户难理解;方向已合意"Farm 内 tab 拆分,不动顶级导航"。
> 代码域:refs/morpho-lite-apps(solon 分支)apps/lite;改动圈=farm 模块 + main.tsx 一行路由声明(见 §6)。

## 1. 目标与非目标

**目标**:①两个产品各占一个视图,风险定位一眼可辨 ②tab 可直链/可刷新/可分享 ③现有 /farm 链接不断
**非目标**:不动顶级导航(6 项不变);不改 Earn/Borrow 等其他页;不重设计两个产品各自的内部布局(刚 polish 过);不做移动端抽屉式导航之类的新交互模式。

## 2. 信息架构

```
/:chain/farm            → redirect → /:chain/farm/leverage   (旧链接兼容,replace 跳转)
/:chain/farm/leverage   → Leveraged tab(默认)
/:chain/farm/range      → Range tab
/:chain/farm/<其他值>    → redirect → leverage(容错)
```

页面结构(两 tab 共享 PageHeader 区域):

```
FARM
[ Leveraged ⚡ borrow to amplify · liquidation risk ] [ Range 🌱 passive · no liquidation (NEW) ]
────────────────────────────────────────────────
tab=leverage: FarmProtocolPanel + FarmTable + FarmPositions   (现状原样平移)
tab=range:    RangeVaults(去掉自带的节标题行,标题职责上移到 tab)
```

- PageHeader 的 subtitle 随 tab 切换:leverage 用现文案;range 用"Deposit both tokens; the vault manages the range and compounds fees. No leverage, no liquidation."
- NEW 徽标:仅 range tab、仅主网配置未上线前后 30 天内显示(常量硬编码截止日,过期自动消失,不留运营债)。

## 3. 组件重排矩阵

| 组件 | 现在 | 之后 | 改动 |
|---|---|---|---|
| FarmProtocolPanel / FarmTable / FarmPositions | farm-subpage 顺序渲染 | leverage tab 内,顺序不变 | 零(纯移位) |
| RangeVaults | 页尾追加 | range tab 内 | 删除自带 `<h2>Range Vaults` 节标题行(职责上移),其余零改动 |
| farm-testnet-playground | FarmSheetContent 内部(Sepolia) | 不动 | 零 |
| PageHeader | 固定文案 | subtitle 按 tab | 小 |

## 4. 视觉与交互基准(照抄,不自创)

- Tab 组件:**复用 uikit shadcn Tabs**(farm-lending-vaults.tsx 340 行已有使用先例),但受控值来自 URL 参数而非本地 state——点 tab = `navigate(\`../\${tab}\`, { replace: false })`,浏览器前进后退可用。
- Tab 视觉:TabsList 全宽基准样式;tab 标签 = 产品名 + 一句风险副标签(小号 secondary 色,移动端隐藏副标签只留产品名)。
- 宽度轨道:tab 条与内容同用 `max-w-7xl px-2 lg:px-8`(本次宽度教训,写死进走查清单)。
- 切换不做动画(页面现状无路由动画,不新增)。

## 5. 状态与边界

- 链切换(RH↔Sepolia):保持当前 tab,只换 chain 段(现有 chain 切换逻辑已按 slug 重导航,tab 段随 path 保留——走查项)。
- 钱包未连接:两 tab 各自已有处理(leverage 现状;range 上轮 polish 已做),无新增。
- URL 容错:未知 tab 值重定向 leverage,不 404。
- SEO/分享:两个 URL 都可直达,刷新不丢 tab。

## 6. 改动圈声明

1. `main.tsx`:`<Route path="farm" …>` → `<Route path="farm/:tab?" …>`(唯一的模块外改动,一行,不影响其他路由)
2. `farm-subpage.tsx`:读 `useParams().tab` + 渲染 tab 条 + 条件渲染两组内容 + 非法值 redirect
3. `range-vaults.tsx`:删自带节标题(约 -8 行)
其余零文件。预计净增 ~70 行。

## 7. 走查清单(实现后逐项过,含截图)

- [ ] /farm 旧链接 → 302 到 /farm/leverage,内容与拆分前一致
- [ ] /farm/range 直达+刷新+浏览器返回
- [ ] 非法 tab 值(/farm/xyz)→ leverage
- [ ] RH:leverage 全功能;range 显 coming-soon
- [ ] Sepolia:range 全交互(存取 sheet 抽查一次)
- [ ] 链切换保 tab;连接钱包状态两 tab 各自正确
- [ ] tab 条与内容同宽度轨道;移动端 390px 无溢出、副标签隐藏
- [ ] 全程零 console 报错;截图逐张设计自审后再交付

## 8. 部署

build → rsync → curl 验证 /farm/leverage 与 /farm/range 都能直达(nginx SPA fallback 已配,无需服务器改动——走查确认)。

---

# v1.1 追加 — Auto LP 改版(2026-09-09,基于 app.beefy.com 实测调研)

> 触发:用户指出 ①单卡混杂"目录/仓位/入口"三角色难理解 ②"Range"是机制命名不是卖点命名 ③前端没对标正主 Beefy。
> 调研:app.beefy.com 列表页+CLM 金库详情页(MSFTc-USDC)实测截图 /tmp/beefy-1~3。状态:**待 review**。

## A. 命名

- 用户可见层:**Auto LP**;tab 标签 `Auto`,副标签 "auto-compound · auto-rebalance · no leverage";URL `/farm/auto`(旧 /farm/range 301 到新址)。合约/内部代码名不动。
- 上线公告用新名,一句 "auto-managed range" 衔接预告推,不发更正。

## B. Beefy 实测结论 → 我们的映射

| Beefy 模式(实测) | 采纳 | 我们的做法 |
|---|---|---|
| 列表行:pair+平台/类型徽标 \| CURRENT APY(醒目) \| DAILY \| TVL \| DEPOSITED | ✅ | Vaults 表:pair+徽标 \| Fee APR(主网接现有 live 源,APY 口径注明) \| Daily(=APR/365) \| TVL \| My deposit。单行起步,多金库即扩 |
| 详情右侧粘性操作面板:Deposit/Withdraw tab + %滑杆(0/25/50/75/100) + You receive + 大 CTA + 费用披露三行(存 0/取 0/性能费只抽收益) | ✅ | 同构照搬:我们已有 %档(取款)推广到存款侧;费用披露加第四行 Balancing fee(仅失衡入金时出现) |
| 价格区间可视化:MIN/CURRENT(IN RANGE 绿标)/MAX 三格 + 价格线叠加区间色带图 | ✅(分步) | v1.1 先做三格+横向区间条(现价位置指示);历史线图需价格历史源,列为 v1.2(observation 索引器可供数据) |
| LP Breakdown:环形图+双资产数量/价值表 | ✅ | 简化为双资产行+占比条(不引入图表库) |
| Strategy 散文段 | ✅ | 一段:存两币→托管区间→复投;不卖本金;calm 机制一句;风险一句(out-of-range 敞口如实写) |
| Boost/Insurance/mooBIFI | ❌ | 无此体系,不搬 |
| 全局筛选chips/搜索 | ❌(暂) | 单金库无意义,多金库时再加 |

## C. 页面结构(Auto tab)

```
Vaults 表(目录+入口,Beefy 列表同构)
  行点击 → 展开详情区(单金库先做同页展开,不新增路由):
    左列:三格价格(MIN/CURRENT/MAX+IN RANGE 标)+区间条 · LP Breakdown · Strategy 段
    右列:粘性操作面板(Deposit/Withdraw tabs,%滑杆,You receive,CTA,费用披露 4 行)
My positions 区(连接且有份额才出现):价值/占比/份额,快捷 Withdraw
```

## D. 走查增补

- [ ] /farm/range 旧址跳 /farm/auto
- [ ] 列表行/详情/操作面板三处数字同源一致(一个数据 hook,同类归一渲染教训)
- [ ] 费用披露四行与合约实际一致(存0/取0/性能费10%只抽收益/失衡费条件显示)
- [ ] %滑杆存取两侧都过一遍真交易(Sepolia)
- [ ] Beefy 截图对照自审:信息层级不缺席(APY/Daily/TVL/My deposit/区间三格)

---

# v1.2 — Auto LP 两层结构(2026-09-09,推翻 v1.1 §C 的同页展开)

> 触发:用户指出 v1.1 形态在多池时直接垮——"如果有 10 个池子,怎么办,入口在哪,怎么排列"。
> 结论已合意:回到 Beefy 两层(列表=目录+入口,详情=子路由),单池不再特例。
> 状态:**待 Codex review,过了再开工**。v1.1 §C 的"同页展开"作废,其余 v1.1 条目(命名/费用披露/组件映射)继续有效。

## E. 信息架构(取代 v1.1 §C)

```
/:chain/farm/auto            → Vaults 列表页(落地)
/:chain/farm/auto/:vault     → 单金库详情页
/:chain/farm/range           → 客户端 replace 跳 /farm/auto
/:chain/farm/range/:vault    → 客户端 replace 跳 /farm/auto/:vault(带段跳,不丢金库)
/:chain/farm/leverage/:任意   → replace 规范化回 /farm/leverage
非法 :vault                   → redirect 回 /farm/auto(容错,不 404)
```

- 跳转全部是客户端 replace(BrowserRouter,无服务端参与),不是 HTTP 301——doc 前文 v1.1 写"301"系口误,统一按此更正。
- 更深路径(如 /farm/range/x/extra)不在承诺范围:`farm/:tab?/:vault?` 最多两段,走 app 现有未匹配路由行为,不为它加 splat。

**第一层·列表(落地)**:每池一行,`pair+徽标 | Net APR | Daily | TVL | My deposit | →`。
- 默认按 TVL 降序;表头 APR/TVL 可点排序(本地 state,不进 URL)。
- 池子数 >6 时出现筛选行(按 token 搜索 + 只看我有仓位的);≤6 不渲染,避免单池时一排空控件。
- My deposit 列:未连接钱包显示"—";连接后有仓位的行高亮标记。
- 一屏扫完所有池,这一层不放任何操作面板/区间图/strategy 散文。

**第二层·详情(子路由)**:点行进入 `/farm/auto/:vault`。
- 内容 = v1.1 §C 已定的详情布局原样:左列(三格价格 MIN/CURRENT/MAX + IN RANGE 标 + 区间条 · LP Breakdown · Strategy 段),右列粘性操作面板(Deposit/Withdraw tabs、%滑杆、You receive、CTA、费用披露 4 行)。
- 顶部加一行返回链接(`← All vaults`)+ pair 标题 + 徽标,替代列表行上下文。
- URL 可直达/刷新/分享——选子路由而非展开的核心理由;杠杆金库将来同构也走这形态。

**单池 = 多池的退化情形,不是特例**:单池时列表也是一行,点开进详情。现 RangeVaults 里"详情当落地"的实现拆掉。

## F. :vault 段与配置

- `RangeVaultCfg` 增加 `slug: string` 字段(如 `eth-usdg`),人读、可分享;URL 用 slug 不用地址。
- slug 在同链内唯一;查找 = `RANGE_VAULTS.filter(chainId).find(slug)`,找不到 redirect 列表页。
- RH 未部署(cfg 无 vault 地址)时:列表行照常显示(APR/TVL 显"—",行尾 COMING SOON 徽标),点击**可进详情**,详情页操作面板位置放 coming-soon 说明(现 ComingSoon 文案平移),左列展示静态 strategy 说明。目录完整性优先——用户应能看到即将上线的池。

## G. 路由与组件改动圈

1. `main.tsx`:`farm/:tab?` → `farm/:tab?/:vault?`(仍单条路由声明,FarmSubPage 内分发;不引入嵌套 Route)。
2. `farm-subpage.tsx`:读 `useParams().vault`;auto tab 下 vault 有值渲染 `<AutoVaultDetail>`,无值渲染 `<AutoVaultList>`;range→auto 跳转带上 vault 段(现 :48 的固定 `${farmBase}/${active}` 导航要改)。
3. `range-vaults.tsx`(826 行)拆三件:
   - `auto-vault-list.tsx` — 列表(新写,行数据走共享 hook)
   - `auto-vault-detail.tsx` — 现 AutoVault 组件平移改名 + 返回行 + coming-soon 变体;**以 `key={chainId}:{slug}:{account}` 强制重挂载**,输入/预览/交易态随金库、链、账户切换整体重置,过期异步预览不得提交到新 vault(上轮 preview 竞态教训的结构化解法)
   - 共享数据 hook `use-auto-vault.ts` — 现 useReadContracts 逻辑抽出,按 cfg 参数化,列表行与详情同源(v1.1 §D 同源一致条)
4. `use-live-fee-apr.ts`:现为无参全局单池源(缓存键/地址写死),改为按池参数化(接受 cfg/pool id);单池现状行为不变,多池时各行各拿各的 APR。
5. `page.tsx`(:72 链切换拼 `farm/${tab}`):补 vault 段处理——目标链存在同 slug 池则保详情,否则落列表。
6. `solon-range.ts`:+slug 字段(两条链各一行)。
7. 列表行组件与 FarmTable 的行视觉对齐(字号/行高/hover 态照抄,不自创第二套表格风格)。

**TVL 排序口径**:现 TVL 按 token1 计价(显示带 token1 符号)。v1.2 约束:排序键仅在全部池 token1 为同一稳定计价资产(USDG)时直接比较;引入非稳定 token1 池前必须先接统一 USD 计价源,此为多池扩容的前置项,写死进走查。

**存款 % 档**(v1.1 §B 承诺、现码未做):不属"原样平移",在 v1.2 内作为独立工作项实现——存款侧 25/50/75/100 档按双币余额中受限一侧等比联动填充;做不进就明说降级为 Max-only 并回报,不静默跳过。

预计:新增 ~300 行,删除 ~80 行(拆分平移不计)。leverage tab 零改动。

## H. 走查清单(v1.2 实现后)

> 2026-09-09 实现完成,e2e 20/20(ui-e2e/auto-two-layer-e2e.mjs,截图 /tmp/auto-e2e/);本地 commit 于 solon 分支。

- [x] /farm/auto 落地=列表;单池一行;点行进详情;`← All vaults` 返回
- [x] /farm/auto/eth-usdg 直达+刷新+浏览器返回;非法 slug 回列表
- [x] /farm/range 跳列表、/farm/range/eth-usdg 跳详情(replace,带段);/farm/leverage/xyz 规范化回 leverage
- [x] 详情页 vault/链/账户切换:整棵子树按 key 重挂载,输入/预览结构性重置(代码级保证)
- [x] 存款 % 档(50%)真跑一笔存款+25% 真跑一笔取款(Sepolia);双币按金库持仓比联动(auto-deposit.ts 3 组单测)
- [x] 列表行与详情同一 use-auto-vault hook,同源保证(截图对照过)
- [x] RH:列表 coming-soon 行可进详情,操作面板位显说明;Sepolia:全交互
- [x] 排序点击生效;≤6 池无筛选行
- [x] 移动端 390px:列表/详情横向溢出 0px(脚本实测 scrollWidth)
- [x] 链切换保 slug 逻辑:farmChainSwitchSubPath 5 组单测覆盖(头部菜单点击流未入 e2e,逻辑纯函数已测)
- [x] console:零本模块报错;残留 3 条为上游既有(uikit address-screening 提示、dev 环境 merkle.io/RH RPC CORS),改动前即存在

---

# v1.3 — 存取改右侧抽屉 + 候选池入目录(2026-09-10,已实现)

> 用户拍板:开平仓统一"点击→右侧抽屉",与杠杆侧交互语法一致("页面看信息、抽屉做交易")。

- 详情页粘性操作面板取消;页首 Deposit/Withdraw 两按钮唤起右侧 sheet(480px,同杠杆侧 FarmSheetContent 规格),费用披露随入抽屉。抽屉内容每次打开全新挂载,输入/预览/交易态天然按次重置。
- 信息列(区间/LP breakdown/strategy/My position)改全宽。
- RANGE_VAULTS 增两个 RH 候选池 coming-soon 行(2026-09-10 gateway 实拉):NVDA/USDG 0.05%(pool 0xd4EB…14a3)、SPY/WETH 0.05%(pool 0xDDCB…AB5e);cfg 增 feeLabel 字段,徽标不再写死 0.01%。
- **部署前置(未解)**:两新池 token1 为 NVDA/SPY,TVL/My deposit 的 token1 计价与列表排序假设失效——上线前必须先接统一稳定计价源(v1.2 §G 已声明,此处再钉一次);另股票池隔夜/周末跳空对 keeper rebalance 的影响要单独评估。
- 走查:auto-two-layer-e2e.mjs 改抽屉流后 21/21(2026-09-10,含 Sepolia 真存真取);列表 3 行形态、抽屉费用披露、移动端 0 溢出均过。

---

# v1.4 — 现状同步 + 流程图定为基准(2026-09-10 下午)

> 复盘决议(KousanS):**任何功能改动先改流程图与本 doc,确认完整度后才动代码**;打补丁式迭代造成的丢项漏项由此杜绝。流程图:`FLOW-farm-auto-v1.workflow.json` / `FLOW-farm-auto-v1.html`(archify,showcase 全绿),走查=按图逐边走并逐节点截图。

当日已落地(全部本地 commit,未部署),按图对应:

- **数据面**:三个 cron JSON(`points/auto_pools.py` 池级 TVL/APR——实读 V3 feeProtocol 折 LP 75% 留成;`points/auto_positions.py` 入金成本回填——档案 RPC 1rpc.io 取每笔入金时点价;既有 farm_fee_apr)+ 合约 30s 轮询 + Deposit/Withdraw 事件回放(vs-HODL PnL)。主网部署时 cron 挂进索引器家族。
- **详情页**:统计头四卡(Net APR 语义色/主数值 16px)+ 左内容右侧栏两栏(Fees+Vault details+大按钮)+ pair 悬停信息卡(Properties/Contracts/Tokens);My position 六格:Value/At deposit/Yield/vs HODL/Vault share/Shares。
- **抽屉**:Deposit/Withdraw 大按钮(侧栏顶,移动端在统计行下)唤起 480px sheet,存款 25/50/75/Max 按金库持仓比联动,calm 只拦存款。
- **Portfolio 升顶级**(/portfolio,导航 Borrow 与 Liquidations 之间):Auto 总览四卡+仓位行+杠杆表+**Points 区(Points 导航项已摘,/points 客户端 replace 跳转)**;/farm/portfolio 同为客户端 replace。Farm 回两 tab。
- **NVDA/USDG、SPY/WETH 两 coming-soon 池**(gateway 实拉地址,feeLabel 入 cfg;deployBlock 仅 Sepolia 已配,RH 池部署时补),coming-soon 详情=池统计卡+费用表。

**已知缺口(挂账,建前先改图):**①NVDA/SPY 部署前置——统一稳定计价源(token1 非稳定);②杠杆成本价 feed→并入 Portfolio 总计;③Portfolio 清算风险汇总维度(优先级最高的下一步);④价格历史线图;⑤审计后补 safety 区;⑥Points 卡已连接未上榜误显 connect wallet。

> 字段级口径见 `SPEC-farm-fields-v1.md`(字段字典,与两张流程图配套;改字段先改字典)。

---

# v1.5 — 产品/UX 维度补全(2026-09-10 晚)

> 触发:KousanS 要求补产品/UX 维度审查(画像、用户故事、路径、操作便利性、缺漏项)。审查结论:此前文档偏"实现字典",缺产品定义层。本节落档:画像与故事入 doc,分支路径入图(FLOW-farm-auto-v1 同步更新),缺口挂账。
> **Codex 只读复审已过一轮(2026-09-10 晚,effort=high,8 项发现全部采纳)**:S1.4/S1.5 覆盖标注下调、S2.2 表述限定到前端、II.1 重定义锚点、II.2 收敛为统一既有文案、II.3 删无依据的经济条件、connect 边改指回详情、⑦标注需新增索引、补 S1.6-S1.8 与⑬⑭。合约关键主张(同秒 calm 检查、失衡单币可入、moveTicks 条件)已抽查属实。状态:**已实现+二轮 Codex 实现复审已过**(KousanS 2026-09-10 拍板"动手";本地 commit a4ae476 + 复审整改 5f846cb,未部署)。二轮复审结论"需改"3 项已整改:P2-1 余额快照过期(schedulePreview 同步 refetchWallet)、P2-2 OOR 条件显式化 inRange===false(经核对 hook,lower/upper 同 tuple,原守卫下不可达,属防御性修正)、P3 swap 链接测试改严格 URL 断言;approve 进行中余额变化属既有交易流限制(minOut/minShares 99% 兜底),记录不改。走查:单测 auto-deposit 5/5、全 lib 单测 31/31、build 通过、e2e auto-two-layer 21/21(Sepolia 真存真取)、定向 shortfall-check 5/5(ui-e2e/shortfall-check.mjs,截图 /tmp/auto-e2e-v16/90-91)。已知边界:输入天文数字时 previewDeposit revert→无预览→CTA 禁用但不显差额提示(显"Enter an amount"),属既有预览失败路径,未单独处理;swapLinkFor 的 Uniswap RH 链 URL 参数(chain=robinhood)未实链验证,RH 部署前走查须点一次。

## I. 用户画像与故事(每条故事对应图上一条边;走查按边对故事)

**P1 被动收益型**(主力):持 ETH/USDG,想吃 LP 费但不盯盘、不懂 tick;对比对象 Aave 利率与 Beefy;最怕本金亏损与"看不懂"。
- S1.1 在列表页一眼比较各池收益与规模。(nav→list;已覆盖)
- S1.2 存款前想知道金库跑了多久、过去表现、多久调仓,才敢交钱。(list→detail;**缺口⑦:运行时长/rebalance 历史未展示**)
- S1.3 手里只有单币,想知道差多少、去哪换,而不是自己算比例。(detail→sheet;**缺口:II.1**)
- S1.4 存完随时看赚了多少、比 HODL 好多少。(tx→position→portfolio;**部分覆盖**——展示齐全,但成交后成本 feed 10min/事件 120s 才跟上:首存短暂显 `－`,追加入金会拿新价值减旧成本**短暂虚高收益**,无"同步中"标注=缺口⑬)
- S1.5 行情剧烈被拦时,想知道为什么、大概等多久。(calm blocked 边;**部分覆盖**——抽屉横幅已有自动恢复+"usually minutes",详情 tooltip 已解释 TWAP;II.2 收敛为统一两处既有文案)
- S1.6 已有仓位,追加入金/部分取款后想看数字对得上。(同 S1.4 缺口⑬)
- S1.7 全部退出后想回看历史收益。(**缺口**:PortfolioProbe 只认 myShares>0,全退后收益入口消失,历史归零不可见)
- S1.8 approve 成功但存款取消/等待确认时关掉抽屉,想知道下一步。(**部分覆盖**:重开抽屉全新挂载可重试、busy 态钱包请求不可中止是实现事实;但无任何"上次到哪了"提示)

**P2 杠杆型**(leverage 用户外溢):懂 LP,把 Auto 当低风险配比;关心 APR 口径真伪、费用、退出流动性。
- S2.1 想知道 Net APR 口径与窗口,判断数字可信度。(部分覆盖:副注有口径;**缺口⑪:估算窗口/warmedUp 未出前端**)
- S2.2 确认任何行情能退出。(已覆盖,**表述限定为"前端不因 calm 禁用取款"**——合约层 RangeStrategyUniV3.withdraw 在与任意入金同秒时仍过 calm 检查(策略级 lastDeposit,非本用户),且 minOut=预览 99%;"全额"指全部份额按现值赎回,非保本承诺)
- S2.3 在 Portfolio 一处看杠杆+Auto 全部仓位与风险。(部分覆盖;杠杆成本价并入总计=v1.4 挂账②)

**P3 观望研究型**(未存款,含 NVDA/SPY 关注者):决策周期长;关心审计、股票池上线时间与周末机制。
- S3.1 看到即将上线的池及其当前池子数据。(已覆盖:coming-soon 行可进详情)
- S3.2 存股票池前想知道周末停盘时收益和调仓怎么办。(**缺口⑨**)
- S3.3 看到审计报告与风险声明再决定。(v1.4 挂账⑤+**缺口⑩**)

## II. 便利性设计(v-next 必做;先过 review 再改码)

**II.1 入金差额提示(zap 的 v1 替代;Codex 复审后重定义)**:锚点是**用户想投入的目标量**,不是 % 档推算——`depositPctAmounts` 只算"钱包能负担的比例填充",单侧余额为零时两边得零,推不出"还差多少"。正确口径:以用户手填/选档后的 previewDeposit take0/take1 对比钱包余额,某侧不足时显示 `Need ~X more {token} · Get {token} ↗`(链接该链 DEX swap 预填 pair;RH 指 Uniswap 官方前端)。注意:合约 `_getTokensRequired` 允许失衡侧单币入金(收 balancing fee),所以"缺另一币"≠不能存,提示措辞不得暗示被挡。配套两件必做:①Deposit CTA 补余额不足校验(现在没有,超额会到链上才失败);②余额未加载完成时不渲染此行,不误报。不做站内 swap、不做合约级 zap(=缺口⑫,依赖审计)。
**II.2 calm 拦截预期管理(收敛)**:抽屉横幅**已有**自动恢复+"usually minutes"文案,详情 tooltip 已解释两分钟均价——不新增,只统一两处措辞。机制表述纠正:isCalm=现价 tick 与 TWAP 偏差回到 maxTickDeviation 阈值内,不是"TWAP 稳定";"通常几分钟"保留与否等 calm 恢复分布实测证据。
**II.3 OUT OF RANGE 预期管理(纠正)**:原稿"费用覆盖成本时重定区间"**无实现依据**——`moveTicks()` 的真实条件只有 calm + rebalancer 白名单,何时调仓是链下 keeper 策略。落点:Range Visual 下 OUT 态复用已核实的风险说明(出区间不赚费、持仓偏单币——此两句属实),调仓时机只写"由 keeper 在市场平静时执行",不编造经济条件;若要写更具体的触发逻辑,先落 keeper 策略文档再引用。

## III. 流程图分支边(已入图)

FLOW-farm-auto-v1 新增:`connect_modal` 节点——**真实路径(Codex 核对代码后纠正):点按钮→connectkit 弹层→回详情页(不记录原操作)→用户再点一次按钮→抽屉**,图上 connected 边指回 vault_detail;`calm_gate→action_sheet` "volatile: blocked" 回边(实际形态=黄横幅+Deposit CTA disable,详情入口与 Withdraw 不受影响);`onchain_tx→action_sheet` "revert / cancel" 回边(toast 报错,抽屉保留模式/输入/预览可重试,非重置);`action_sheet→onchain_tx` "withdraw · no calm gate" 直边(限定见 S2.2)。**走查=按图逐边,以上分支从此在走查范围内**;此前图只有 happy path,是"图为基准"制度的漏洞,已堵。

## IV. 挂账增补(接 v1.4 缺口①-⑥续号)

⑦信任材料:金库运行时长 + rebalance/harvest 历史——**需新增索引**(Codex 核:observation_pools.py 只有池规模/币对/日成交量,没有调仓与 harvest 历史;与价格线图④同批规划);⑧事件触达:out-of-range/APR 大跌/清算逼近通知(渠道待定:TG bot 或前端 badge);⑨股票池用户侧交易时段说明(部署前置,与计价源①同批);⑩合规声明位:风险声明+地区限制(不服务美/中/受制裁地区),页脚+首次存款确认;⑪APR 估算窗口声明出前端(warmedUp/windowSeconds 现未暴露给显示层);⑫合约级单币 zap(长期,依赖审计);⑬成交后数据同步:成本 feed 10min/事件 120s 造成首存 `－`、追加入金短暂虚高收益,详情与 Portfolio 需"同步中"标注或新旧一致性检查——**2026-09-11 走查实锤:同一时刻详情页 vs HODL -$239 vs Portfolio +$1.52B(两页各自缓存 netContribution),建议提优先级**;⑭全退用户的历史收益视图(S1.7)。

**2026-09-11 第一批池物色(KousanS 要求;gateway 实拉 01:32 UTC,单日快照)**:RH V3 TVL 前十中建议第一批 4 池——①ETH/USDG 0.01%(0x52e65B17…,$29.96M/$567.7M vol/毛 69.2%,**唯一 token1=USDG,零前置可部,旗舰**)②NVDA/USDG 0.05%(已 cfg,毛 98.8%)③GLD/USDG 0.3%(0x7A6A053e…,毛 51%,低波 IL 友好)④SGOV/USDG 0.3%(0xfAb52005…,毛 16.3%,IL≈0 类固收)。净 APR≈毛×0.75(lpShare,逐池实读确认)×0.9。**SPY/WETH 建议从候选摘除**(TVL 未进前十+双波动腿)。PONS 系/meme 不碰(无喂价/rug/拉盘 APR)。股票/ETF 池 token1 恒为股票腿(USDG 地址小)→ **统一计价源①成为第一批关键路径**。限额:拍板不设(无杠杆无清算);软约束=金库占池比。定稿前用 observation 索引器攒 7 天均值复核。cfg 变更待拍板。

**2026-09-11 整体走查记录(KousanS 要求,Sepolia 实链)**:UI 全流程 21/21+差额定向 5/5,28 张截图(/tmp/walkthrough-v16);自动复投真触发——SwapRouter02 往返生费(0x6638…03a4/0x89ee…0f40,calm 保持)→ 公众 harvest()(0xb405…f682):totalSupply 前后不变、balances 增加、lastHarvest 更新,复投=份额单价上涨语义链上验证 ✓,UI LP breakdown 与链上读数吻合。发现:⑬实锤(见上)、⑥在 Portfolio 截图可见。

另,v1.4 挂账③状态更正(Codex 核):杠杆清算风险区已在 Portfolio 落地(FarmRiskPanel,usage 排序+阈值色),③剩余范围=Borrow 负债维度并入 + Auto 侧风险维度(出区间时长/单币敞口),不再整体标未实现。
