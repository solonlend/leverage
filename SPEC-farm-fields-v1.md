# SPEC — Farm Auto LP + Portfolio 字段字典 v1.6

> 2026-09-10。v1 经 Codex 复核 29 项→v1.1;二轮复核 6 项→v1.2;v1.3=走查整改;v1.4=Risk 区;v1.5=P2 四小项(区间宽度标注/加载骨架/链名/统计头去重);v1.6=DESIGN v1.5 §II 三项(入金差额提示+CTA 余额校验/calm 措辞统一去未实测时长/OOR 说明行);v1.7=挂账清理①⑨⑩⑪(stableLeg 统一计价/股票池时段句/合规页脚/APR warming 副注);v1.8=⑬同步标注+⑭全退历史行;v1.9=⑦金库历史面板;v1.10=③Borrow 风险维度并入 Risk 区+②杠杆成本价 feed 并入总览;其中 6 项按 SPEC 语义反向修了代码(见文中【已修】)。与 `FLOW-farm-auto-v1.html`(旅程)、`FLOW-farm-modules-v1.html`(模块)配套:图管结构与关联,本文管**每个字段的来源、口径、空态**。改字段先改这里。
> 代码域:refs/morpho-lite-apps/apps/lite。约定:**Auto 模块空态字符为全角减号 `－`(U+FF0D)**;Points 区沿用其原空态(`—` 与加载态 `…`)。金额 tabular-nums。计价:当前已部署池(Sepolia ETH/USDG)token1=USDG≈USD;NVDA/SPY 候选池 token1 非稳定,部署前置见 §5。

## 0. 数据源总表

| 源 | 内容 | 刷新 | 缺失/降级 |
|---|---|---|---|
| `useAutoVault(cfg)` | 链上单一口径源:vault.balances/totalSupply/isCalm/balanceOf(user) + strategy.price/range/lastPositionAdjustment | 30s 轮询(vault 与 strategy 两组请求,**同口径但非同区块原子**) | coming-soon 时 reads 关闭;加载中派生值缺省(shares→0,占比→0),**范围/CALM 徽标及详情 CURRENT 的 (in range)/(out) 注记均在加载完成后才显示【已修·二轮补全】** |
| `data/auto-pools.json` ← `points/auto_pools.py` | 池级 tvlUsd/volume24hUsd/feeTier/lpFeeShare/feeAprGross(**已 ×lpFeeShare**) | 脚本 cron(主网部署时挂);前端 useQuery 15min | lpFeeShare 实读 slot0.feeProtocol,**读失败兜底 0.75 不按 1.0【已修】**;tvl/fee≤0 **或 volume 字段缺失(None≠真实 0)** 的池**不写入**(前端显 `－`,不显 $0)【已修·二轮补全】 |
| `data/auto-positions-<chainId>.json` ← `points/auto_positions.py` | 每用户 costBasisUsd/shares/deposits/withdrawals;每笔入金按其区块 strategy.price()(档案 RPC)计价,取款按份额比例扣减 basis | 脚本 cron;前端 10min | At deposit/Yield `－` |
| `data/farm-fee-apr.json` ← `points/farm_fee_apr.py` | feeGrowth **滚动窗口估算**毛 APR(窗口末端 active liquidity 外推;冷启动时窗口很短,前端未检查 warmedUp/windowSeconds——数值波动大属预期);天然已含 lpShare | 脚本 30min;前端 5min | 仅覆盖 RH ETH/USDG 池。**已部署池缺 feed 时 APR 显 `－`,不回退池级**;未部署+非测试网才用池级回退,若 live feed 覆盖该池则优先 live |
| Deposit/Withdraw 事件回放 `useNetContribution` | net0/net1(累计净存入两币),自 cfg.deployBlock getLogs | 120s | vs HODL `－`;**deployBlock 目前仅 Sepolia 配置**,RH 池部署时必须补 |
| `RangeVaultCfg`(solon-range.ts) | chainId/testnet/slug/pair/feeLabel/vault/strategy/pool/deployBlock?/token0/token1/explorer | 静态 | — |

## 1. Vault List 行(auto-vault-list.tsx)

| 字段 | 口径 | 空态/条件 |
|---|---|---|
| pair + `V3 · {feeLabel}` 徽标 | cfg;整块挂 AutoPairInfo 悬停卡(字段见 §1.1) | 恒显 |
| TESTNET 徽标 | cfg.testnet | 仅测试网 |
| IN RANGE / OUT OF RANGE | lower≤price≤upper | 已部署且 price/range **加载完成**才显示【已修】 |
| COMING SOON 徽标 | !cfg.vault | 未部署 |
| Net APR(farmSignedColor,18px) | 已部署:live feed 毛 APR×0.9;未部署:**优先 live feed(若覆盖该池)**,否则 poolStats.feeAprGross×0.9 | `－`;未部署行只要显示任何数字(无论来自 live feed 还是池级 JSON)副注 "pool, pre-launch" 恒随【已修·二轮】 |
| Daily | netApr/365,4dp | 随 APR |
| TVL | 已部署:bal0×price+bal1;未部署:poolStats.tvlUsd。**显示统一 $ 前缀+紧凑记数(金额显示约定)** | `－`;**加载态(已部署且链上读未返回)显示 pulse 骨架块而非 `－`(v1.5,APR/Daily/TVL/My deposit 四格同)** |
| My deposit | tvl1×myShares/totalSupply(**$ 前缀+紧凑**) | 未连接 `－`;连接无仓 "$0";有仓行 ring 高亮 |
| 排序 | 表头 APR/TVL 可点,默认 TVL 降序;未部署行以池级数参与 | **缺数升序降序都排末位【已修】** |
| 筛选行 | 池数 ≥7 才渲染:token 搜索 + My positions 开关 | <7 隐藏 |

### 1.1 pair 悬停卡(auto-vault-info.tsx;列表行与详情标题同款)
Properties:DEX `Uniswap V3 (official deployment) · fee tier {feeLabel}`、Pool 地址;Contracts:Vault、Strategy;Tokens(canonical, verified on-chain):token0、token1。**地址逐个判断**:存在→缩写+浏览器链接,缺失→"pending deployment"(coming-soon 池仅 Vault/Strategy 显 pending,Pool 与两币照常带链接)。

## 2. 详情页(auto-vault-detail.tsx)

### 2.1 统计头四卡(与列表同 hook 同口径)
Net APR(语义色,副注 "after the 10% performance fee"/测试网无值时 "no APR feed on testnet";**(v1.7,挂账⑪)live feed 存在且 warmedUp=false 时副注追加 " · 24h window warming"——短窗口估算波动大的如实披露**)· Daily · TVL · My deposit(未连接副注 "connect wallet")。主数值 16px;副注 10px secondary。

### 2.2 Range Visual
min/cur/max 三格(rangePriceToHuman=raw/1e36×10^(d0−d1),单位 `{t1}/{t0}`)· CURRENT 标 (in range)/(out) · CALM/VOLATILE 徽标=vault.isCalm(**加载完成才显示【已修】**;false 才 VOLATILE,含 tooltip)· 区间条:**仅 lower/upper/price 全存在且 upper>lower 时渲染**;marker left=10+80×(price−lower)/(upper−lower),clamp[2,98];**色带为示意图非比例尺,区间紧窄度由文字标注传达:`±X% range`,X=(upper−lower)/2/price×100(1dp)(v1.5)**。
**OOR 说明行(v1.6,DESIGN v1.5 II.3)**:price/lower 已加载且 !inRange 时,面板底部一行说明:出区间不赚费、持仓偏单币、keeper 在市场平静时重定区间、不强制卖出——措辞与 Strategy 段同源;调仓时机**不写经济条件**(moveTicks 实际仅 calm+白名单)。in-range 或加载中不渲染。

### 2.3 LP Breakdown
每 token 一行:数量 fmtAmt(0→"0",<0.0001→"<0.0001",**最多** 4dp/2dp,不补尾零)· token0 附 `· {val} USDG` 折价 · 占比条 share0=val0/tvl1(最小显示 2%)· 脚注 drift 声明。

### 2.4 My Position 六格
**Value 格已删(v1.5)**:与统计头 My deposit 同数去重,六格→五格(At deposit/Yield/vs HODL/Vault share/Shares)。
**同步标注(v1.8,挂账⑬)**:存/取交易成功时写 `localStorage solon-auto-lasttx:{chainId}:{vault}=now`;My Position 面板与 Portfolio Auto 总览在 `now−lastTx < 12min` 内显示琥珀色提示行 "Syncing your last transaction — cost basis and vs-HODL can lag a few minutes."(成本 feed 10min/事件 120s 的如实披露);超窗自动消失,不做跨端同步(单浏览器可见即可,榜单不受影响)。
**占位态(v1.3)**:连接且 myShares==0 时面板不消失,显示引导文案 "No position yet — your value, cost basis and yield will appear here after your first deposit."。未连接不渲染。有仓时六格如下(quote 值按金额显示约定 $ 前缀+紧凑):
| 格 | 公式 | 色 |
|---|---|---|
| Value | tvl1×myFrac | 白 |
| At deposit | positions feed costBasisUsd(tooltip 说明入金时点计价) | 白 |
| Yield | Value − At deposit | farmSignedColor,±前缀 |
| vs HODL | (claim0−net0)×price+(claim1−net1);claimN=balN×myFrac;tooltip 附分币 delta(最多 4dp) | farmSignedColor,±前缀 |
| Vault share | myFrac×100,2dp% | 白 |
| Shares | fmtAmt(myShares,d1) | 白 |
布局 2/3 列自适应,数值 break-all。

### 2.5 Fees Panel(正文+抽屉同款;**coming-soon 变体标题为 "Fees at launch"**,已部署态为 "Fees")
Deposit 0% / Withdrawal 0% / Performance 10% of yield;脚注:harvest 时收取、绝不动本金、任何行情可取。**整块为 secondary 灰色调**(标签与数值同色,无白色强调)。

### 2.5.5 Activity 面板(v1.9,挂账⑦;仅已部署态,置于 Strategy 与 My Position 之间)
数据=第四 cron 源 `data/auto-history-<chainId>.json` ← points/auto_history.py(策略事件回放,双端点并集加固):harvest 条目=Harvest(fee0,fee1 复投净额)+同 tx ChargedFees(协议分成);rebalance 条目=有 TVL 事件且同 tx 无 Harvest/无金库 Deposit·Withdraw 的策略交易(排除法),附当块 positionMain 新区间(档案调用,失败留空)。前端显示最近 8 条:kind 徽标(HARVEST emerald/RANGE cyan)+ ago(块时间戳)+ 数额(fmtAmt);feed 缺失整面板不渲染(降级总则);空列表显 "No activity yet"。

### 2.6 Vault Details
Platform `Uniswap V3 · {feeLabel} fee tier` · Last range adjustment=ago(lastPositionAdjustment)(<90s 秒/<90min 分/<36h 时/否则天;0 或缺 `－`;仅已部署显示该行)· Vault/Strategy/Pool/token0/token1 五地址,**逐个判断**存在→缩写+链接,缺→"pending deployment"。

### 2.7 Coming-soon 变体
左:COMING SOON 卡+池级三卡(Pool TVL `$`/24h volume `$`/LP fee APR gross+副注)——**三卡整体仅当 poolStats 有数据时渲染,feed 缺失整块消失**(不是逐卡破折号)+ Strategy 文案;右侧栏:Fees+Vault Details。无操作按钮。

### 2.8 Strategy 面板(已部署态)
独立散文段:集中流动性机制、keeper 重定区间、2 分钟 TWAP calm 门、本金不被 swap、出区间不赚费+单币敞口风险如实声明。**(v1.7)cfg.marketHours=true 的池(NVDA/GLD/SGOV)追加一句交易时段声明:股票/ETF 腿的底层市场收盘/周末停牌而池子持续交易,预期更大 drift 与跳空后重定区间——已部署 Strategy 段与 coming-soon 变体 Strategy 文案同句。**

## 3. 操作抽屉(480px)

**触发按钮(v1.3)**:未连接时 Deposit/Withdraw 按钮**直接唤起钱包连接弹层**(connectkit useModal),不开抽屉;连接后 myShares==0 时 **Withdraw 触发按钮禁用**。

**挂载契约【已修】**:Sheet 受控 open 状态,**内容组件仅在打开时挂载**——每次打开输入/mode/预览/交易态从零开始;详情子树另有 `chainId:slug:account` key 兜身份切换。

### 3.0 通用
未连接钱包:**整个表单不渲染**,显示 "Connect a wallet to deposit/withdraw." 提示。费用披露:**固定三行**(存0/取0/性能费),仅 Deposit 模式且 balancingFee>0 时出现第四行。交易反馈走 runTx toast 链(钱包等待/确认中/成功/回滚/取消/替换);txError 文案(截160字符):兜底 catch,另有一处**主动设置**——approve 后轮询 12×1.5s 仍未见 allowance 时提示 "Approval not visible on the RPC yet";View last transaction 链接仅在存/取**成功后**出现并更新。

### 3.1 Deposit
| 元素 | 口径 |
|---|---|
| % 档 25/50/75/Max | depositPctAmounts:maxA0=min(wallet0, wallet1×vb0/vb1)×p%,amt1=amt0×vb1/vb0;单边金库只填持有侧;空金库各 p%;填充值截 8 位小数;两侧余额全零时禁用 |
| 两输入 | Balance 行+MAX;手动输入清除 % 档选中 |
| 预览(400ms debounce,previewSeq 竞态守卫) | previewDeposit → Vault will take(take0+take1)· You receive shares · **shareFrac=入金后你的总占比(含原持仓)【已修】** |
| Balancing fee 行 | 仅 fee0/fee1>0(单边入金) |
| **差额提示行(v1.6,DESIGN v1.5 II.1)** | 锚点=previewDeposit take0/take1 逐侧对比钱包余额:take>balance 时显示 `Need ~{fmtAmt(take−balance)} more {token}`;非测试网且该链有官方 swap 前端时附 `Get {token} ↗`(Uniswap 前端预填 outputCurrency;链→URL 映射仅 RH 4663,其余无链接)。**钱包余额未加载(walletData undefined)不渲染不误报**;测试网不带链接(有 Mint 按钮)。措辞不得暗示"缺一币不能存"(合约允许失衡单币入金) |
| CTA Deposit | disabled:busy ∨ VOLATILE ∨ 预览中 ∨ 无预览 ∨ shares==0 ∨ **余额不足(任一侧 take>balance,且余额已加载)(v1.6)**;流程 approve×2(按需)+deposit(minShares=99%) |
| calm 拦截横幅 | isCalm===false;**只拦存款**;**措辞与 VOLATILE 徽标 tooltip 同机制(现价偏离 2 分钟均价,回归即自动恢复;取款不拦)——不写"usually minutes"等未实测时长(v1.6)** |
| Mint test tokens | 仅测试网:1 ETH+2500 USDG |

### 3.2 Withdraw
持有份额行 · % 档 25/50/75/Max(shares=myShares×p/100;**myShares==0 时档位禁用**)· previewWithdraw → You receive out0+out1 · Burning x of y · CTA disabled:busy ∨ 预览中 ∨ 无预览 ∨ shares==0 ∨ myShares==0(minOut=99%)。**永不被 calm 拦**。

## 4. Portfolio(/portfolio,顶级导航;**PageHeader 副标题末尾带当前链名(v1.5)**)

| 区 | 字段 |
|---|---|
| **Risk 区(v1.4 起;v1.10 并入 Borrow 维度)** | 统一行形:标识(杠杆=#id,Borrow=抵押票符号)+ KIND 徽标(LEV/BORROW)+ usage 健康条 + usage% + Value/Debt。杠杆源=useFarmPositions(usage=debt/(value×LLTV));**Borrow 源(v1.10)=useBorrowRisk:遍历 SOLON_MARKET_IDS,morpho.position(id,user) 有仓的市场——debt=borrowShares×totalBorrowAssets/totalBorrowShares,抵押价值=collateral×oracle.price()/1e36(loan 计价≈USD),usage=debt/(抵押值×市场lltv/1e18)**;两源合并后 usage 降序(mergeRiskRows 纯函数,缺 usage 排末);阈值色 0.9 红/0.75 黄;两源皆空整区隐藏;oracle 读失败该行 usage 显 `－` 不猜;Auto 仓位无清算线不入此区 |
| 未连接态(v1.3) | 整个 Farm 区(总览+仓位+杠杆表)替换为一张连接引导卡(文案+Connect 按钮);Points 区照常显示(公共榜单) |
| **杠杆并入总览(v1.10,挂账②)** | 新 feed `data/farm-basis-4663.json` ← points_v2.py basis 子命令:回放 PositionOpened/Increased/MarginAdded/PositionClosed,**入金价用 Chainlink ETH/USD feed 的历史 rounds 匹配事件时刻**(RH 无免费档案节点;round 粒度≈心跳/偏差阈,meta 披露)——每 owner 出 lifetimeInUsd(开仓自有本金+加仓+补保证金)/lifetimeOutUsd(平仓返还);总览卡改"Positions · overview":Value=Auto 值+杠杆 equity(value−debt,useFarmPositions 现值),At deposit=Auto basis+杠杆 netInvested(in−out),Yield=Value−At deposit;vs HODL 仍 Auto-only(杠杆无此口径,副注注明);owner 取开仓事件,持仓 NFT 转让场景记为已知限制 |
| Auto 总览四卡 | Total value/At deposit/Yield/vs HODL=各有仓池逐项求和;**求和初值 undefined:无仓位或该项数据全缺 → `－`(不是 0)**;Yield/vs HODL 语义色±;数值 break-all |
| **已平仓行(v1.8,挂账⑭)** | positions feed 增 lifetimeInUsd/lifetimeOutUsd(每笔存/取均按其块价折 USD 累计);shares==0 且 lifetimeOutUsd>0 的用户在 Auto 仓位列表尾部显示 CLOSED 行:pair+CLOSED 徽标 · Realized ±(=out−in,语义色)· 不参与总览四卡合计(那是在仓口径);无历史者不渲染。**走查态(2026-09-11):逻辑+数据链路已验(feed lifetime 字段实生成、双端点并集加固),CLOSED 行渲染路径未实证——链上暂无全退用户,合成账号验证被注入钱包链路所阻;首个真实全退出现时按此行补走查** |
| Auto 仓位行 | 仅 myShares>0 的池:pair+费率徽标 · Value · At deposit · Yield± · vs HODL±(**行内数值 14px**)· → 点击进详情;空态引导文案 |
| 杠杆表 | FarmPositions 原样嵌入(自带标题,无仓位渲染空):列=Position/Value/Debt/Leverage/Range/**Health**;不入总览合计(无成本价源) |
| Points 区 | 原 Points 页并入,**样式沿用原版**(卡标签 12px 非 mono,主数值 24px):说明段+四卡+Top100 榜(本人行高亮 "(you)")。口径:两源(points.json+data/farm-points.json)按地址合并求和;**Participants=合并后地址数;Markets 取 base 源优先不合计;Updated/block 各取两源最大值(UTC 显示)**。**一次性 fetch:无轮询、不随链切换**(固定两份 JSON)。空态:**加载中(undefined)显 `…` 且不显失败文案;两源确认全挂(null)才显 "Points snapshot unavailable"【已修·二轮】**;有数据空榜显 genesis 文案;**已知 bug 已修(2026-09-11):已连接未上榜显 "unranked"** |
| **Points v2(2026-09-11 已上线)** | 口径:1 pt=$1 实收×K(points/DESIGN-points-v2.md);数据=第三源 `data/points-v2.json`;展示=v1 冻结分+v2 实收分**合计**(Revenue (v2) 列 + Total 合计,v2-only 地址也有行,排序按合计);说明段=已批 v2 文案+activation 行(block 60,161,154=v1 冻结块,K=1);v1 两源展示逻辑不动;**farmpoints v1 launchd 索引器已 unload(冻结,plist 保留可逆)**;首版榜单 0 地址(外部可归因收入/活动为零,全线 proxy 模式) |

路由:/points 与 /farm/portfolio 均客户端 replace 跳 /portfolio。

### 4.1 全局页脚(v1.7,挂账⑩部分)
Footer 组件由空占位改为单行声明(11px secondary,居中,非 fixed):"Solon is not offered to persons or entities in the US, China, or sanctioned jurisdictions. Pre-audit software — use at your own risk."(§4.5 合规口径+风险实话);首次存款二次确认交互**待定**,不在本轮。

## 5. 全局约定

- **语义色**:只有方向性收益指标(Net APR/Yield/vs HODL/杠杆 Net APY)用 farmSignedColor(正绿负红);TVL/Daily 白;Fees 面板整体 secondary 灰。
- **字号(Auto 模块基线)**:标签 10px mono 大写;主数值 16px(仅列表行 APR 18px;详情统计头 APR 同 16px);说明 11-12px light。**例外**:portfolio 仓位行数值 14px;Points 区沿用原版(12px 标签/24px 主值);统计卡副注 10px(无 light)。
- **APR 口径链**:池级=feeTier×vol24h/TVL×365 → ×lpFeeShare(链上 slot0,现三池 0.75;读失败兜底 0.75)→ ×0.9(性能费)=展示 Net APR。live feed(feeGrowth)天然含 lpShare,只再 ×0.9;为滚动窗口估算,短窗口未过滤。
- **单位约束(v1.7 重写,挂账①解决)**:cfg 增 `stableLeg: 0|1` 标注稳定腿;所有 quote 值统一折算到稳定腿≈USD——stableLeg=1(ETH/USDG 等):tvl=bal0×price+bal1(原口径);stableLeg=0(USDG 为 token0 的股票池):tvl=bal0+bal1÷price。列表排序自然跨池可比;LP breakdown 的折价注记挂在**非稳定腿**上。deployBlock 仍为各池部署日必补项。
- **一致性边界**:列表与详情共用 useAutoVault——**同口径**保证一致,但 vault/strategy 是两组独立轮询,不保证同区块原子快照。
- **金额显示(v1.3)**:quote 计价值(TVL/My deposit/Value/At deposit/Yield/vs HODL)当 |v|≥1,000,000 时用紧凑记数(`$2.18B`/`$7.78M`,3 位有效数字),否则全精度千分位;计价资产为 USDG(≈USD)或池级 USD 时统一 **$ 前缀**(不再显示 "USDG" 后缀),未来非稳定 token1 保留 `{数} {符号}` 格式。
- **降级总则**:任何 feed 缺失显空态字符,不显错误、不借用别池数据;auto-pools 缺数池不写入文件。
