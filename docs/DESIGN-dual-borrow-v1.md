# 设计 doc — Dual-Borrow 杠杆 LP(对大仓位友好)v1

> **⚠️ 历史归档（2026-09-06）**：本文档反映 2026-09-04 设计定稿时的状态，此后实现已多轮演进（清算实付记账、暂停语义重划、feed 分腿时效、盈余跨腿清偿等）。**实现以代码与 DEPLOY-CHECKLIST.md 为准**，本文仅作设计背景参考。

> 2026-09-04。依据 [RESEARCH-rebalance-2026-09-04.md];**取代**早前单币版草稿 DESIGN-rebalance-v1.md(已被 dual-borrow 架构超越)。
> KousanS 2026-09-04 拍板:①走 dual-borrow ②接受重做清算/健康度核心并重新红队 ③ETH 储备+ETH 出借人 OK。
> **本 doc 只写 v1 scope**;触发策略层/聚合器路由/私有 mempool/分片执行/单池风控见研究 doc 第 5 节(v1.5/v2)。
> 状态:**待 review**,review 通过再 TDD。设计阶段不写码。

## 0. 核心思想:两条腿各借各的,swap 只按缺口/差额

现状(单币借款):只借 USDG → zap 一半换 WETH → 铸 LP。大仓位那笔 zap 冲击 ∝ 规模,是损耗大头。
**Dual-borrow**:按 LP 需要的比例,**WETH 腿从 WETH 储备借 WETH、USDG 腿从 USDG 储备借 USDG**,直接铸 LP。
- 开仓:借两腿 → 直接 mint → **零 zap**。
- 平仓:撤 LP 得 WETH+USDG → 匹配还两笔债 → 盈余腿只补**短缺腿的缺口**(swap ∝ 价格漂移,非半仓;价回开仓点=零)。
- 换区间(rebalance):两腿目标比例变,只需一笔**小额 delta swap**。

大仓位:开仓零 swap;平仓/换区间的 swap 只按漂移缺口计,不按半仓名义计——这才配得上"对大仓位友好"。

## 1. 架构变更

### 1.1 借贷侧:两个储备(双池)

ExtraFi LendingPool 原生支持多储备。v1 初始化两个:
- `reserveLoan` = USDG(现有,id 1),USDG 出借人存 USDG 吃息。
- `reserveRisk` = WETH(新增,id 2),ETH 出借人存 WETH 吃息。
各自独立 eToken、利率曲线、credit。金库在两个储备上都要 `enableVaultToBorrow` + `setCreditsOfVault`。

### 1.2 仓位:每仓两笔债

`Position` 增加第二个 debtId:
```
struct Position {
    uint256 v4TokenId;   // 底层 LP NFT
    uint128 liquidity;
    int24 tickLower; int24 tickUpper;
    uint256 debtRisk;    // WETH 债务仓 (reserveRisk)
    uint256 debtLoan;    // USDG 债务仓 (reserveLoan)
}
```
金库 InitParams 增加 `reserveRiskId`/`reserveLoanId`(RISK/LOAN 资产地址已有)。

### 1.3 估值/健康度:两种借款资产合并计价(USDG 本位)

```
totalDebtInLoan = debtRisk_amount × (ETH/USD ÷ USDG/USD)   // WETH 债折 USDG
               + debtLoan_amount                            // USDG 债
healthy  ⇔  fairValueInLoan(LP) × LLTV ≥ totalDebtInLoan
```
LpShareOracleV4 已有 ETH/USD + USDG/USD 两个 feed,能把 WETH 债折成 USDG;新增一个 `debtValueInLoan(riskAmt, loanAmt)` 视图或金库内联算。

## 2. open(dual-borrow,零 zap)

```
struct OpenParams {
    uint256 investRisk; uint256 investLoan;   // 用户自带的两腿(可各为 0)
    uint256 borrowRisk; uint256 borrowLoan;   // 各储备借入量(前端按区间比例算)
    int24 tickLower; int24 tickUpper;
    uint128 amount0Max; uint128 amount1Max; uint128 minLiquidity;
    uint256 deadline;
}
```
流程:
1. `_requireTwoSidedRange`;`_snap()` 记基线。
2. pull `investRisk` WETH + `investLoan` USDG;`borrow(reserveRisk, debtRisk, borrowRisk)` + `borrow(reserveLoan, debtLoan, borrowLoan)`。
3. `total0/total1 = invest + borrow`(按币序 WETH/USDG)。
4. `liq = _liquidityFor(range, total0, total1)`;`require(liq>0, ZERO_LIQ)`;`require(liq>=minLiquidity)`。
5. mint LP;发 Solon NFT;`_refundDust`(退未用完零头,基线感知)。
6. `require(_isHealthy(id), UNHEALTHY_OPEN)`;emit。
- **无 swap**:前端按区间当前比例算好 borrow 两腿,零头退还。用户哪条腿自带就少借哪条(双币入金自然融入)。

> 说明:v1 开仓不做 zap;若用户/前端给的比例有偏差,只退零头不补 swap(避免任何大额 swap)。追求精确利用率的可选 delta 补齐推 v1.5。

## 3. close(dual-borrow,按缺口 swap)

> **KousanS 2026-09-04 指正**:价格一动,LP 成分就漂移(涨→LP 持更多 USDG 更少 WETH),撤出两腿几乎必然与两笔债不匹配,"零 swap 平仓"不成立。正确模型:**盈余腿 → 短缺腿,只换缺口那一笔**。swap 量 ∝ 开仓以来的价格漂移,不 ∝ 半仓名义——大仓位仍远优于旧"整腿 zap";价格回到开仓点时缺口为 0。

```
struct CloseParams {
    uint16 percent;
    uint256 maxSwapIn;      // 缺口 swap 的最大投入(盈余腿滑点上限,必填非零)
    uint256 minOutRisk; uint256 minOutLoan;   // 出金两腿下限
    bytes zapPath; uint256 deadline;
}
```
流程:
1. `dLiq = fullClose ? liq : liq×percent/1e4`;`require(dLiq>0)`;全平则 burn NFT。
2. 收 fee + `_skimHarvestFee`;`_removeLiquidity(dLiq)` → got0(WETH)+got1(USDG)+净 fee。
3. **匹配还债**:`repayRisk = min(got0, dueRisk)`、`repayLoan = min(got1, dueLoan)`(due = 债×percent);分别 repay。
4. **缺口结算**(核心新增,顺序 KousanS 定):
   - **① 用户自带缺口币 top-up(首选)**:`topUpRisk/topUpLoan` 入参,只拉实际所需、超出不碰;前端用 `previewClose(id,percent)` 视图先告知"补多少币可无损赎回"。**maxSwapIn=0 即明确拒绝任何 swap**——选择权在用户。
   - ② 仍有缺口且另一腿有盈余:
   - 链上精确知道 S → 调 SwapExecutor **exactOutput**:"买入恰好 S 的短缺币,投入盈余腿 ≤ maxSwapIn";
   - 换到后补还该腿;`maxSwapIn` 是滑点保险丝,超了整笔 revert。
5. 剩余双币 in-kind 退用户;`require(outRisk≥minOutRisk && outLoan≥minOutLoan, SLIPPAGE)`。
6. **坏账仅在两腿都榨干仍有残债时成立**(先匹配、再缺口互补,都不够才 BadDebt 按腿 emit)——不允许"一腿有盈余、另一腿却记坏账"。
- 三种价况:价≈开仓 → 缺口≈0 零 swap;价涨 → USDG 盈余买 WETH 缺口;价跌 → 反向。
- `previewClose` 按当前池价估算两腿到手/应还/缺口(不含未领 fee 与执行价差,前端加小缓冲)。
- 取整尘埃(GAP_EPS=1e3 wei):liquidity 数学向下取整会造 wei 级假缺口,低于阈值不触发 swap、不计坏账事件(TDD 实测抓出后补,同 Extra 已知取整漂移性质)。

## 4. rebalance(换区间,只换 delta,债务不动)

```
struct RebalanceParams {
    int24 newTickLower; int24 newTickUpper;
    int256 swapAmount;   // 链下算的净额;>0 WETH→USDG,<0 USDG→WETH
    uint256 minSwapOut; uint128 minLiquidity; bytes zapPath; uint256 deadline;
}
function rebalance(uint256 id, RebalanceParams p) external nonReentrant onlyHolder(id);
```
流程(照 Charm 三段式):
1. `_snap()`;`_requireTwoSidedRange(new)`。
2. 撤本仓全部 LP → got0/got1;收 fee + skim。
3. **只换净额** `_swapExactIn(方向由 swapAmount 符号, |swapAmount|, minSwapOut, zapPath)`。
4. `_liquidityFor(new, bal0, bal1)` → require≥minLiquidity → mint 新区间;更新 pos.{ticks, liquidity, v4TokenId}。
5. `_refundDust`;`require(_isHealthy(id), UNHEALTHY_AFTER_REBALANCE)`。
6. emit Rebalanced。
- **债务不动铁律**:全程不调 borrow/repay/newDebtPosition;debtRisk/debtLoan 前后恒等。v1 仅 owner 触发(swapAmount 传参,传坏只伤自己);keeper 代管推 v1.5。

## 5. liquidate(两资产清算,最重的核心重做)

现有 SettlementMath/liquidate 假设单一借款币,必须泛化。模型(keeper 原币收款;封顶盈余必要时跨腿 swap):
1. 守卫:非白名单 revert;`_isHealthy` 则 revert Healthy。
2. `k = min(入参比例, closeFactor 50%)`;`repayRisk = debtRisk×k`、`repayLoan = debtLoan×k`。
3. `repayValue = repayRisk×p_eth + repayLoan`(USDG 计);`seizeValue = repayValue×(1+bonus)`;`seizeLiq = liq×seizeValue/posVal`(封顶全仓);`require(seizeLiq>0, ZERO_SEIZE)`。
4. keeper 垫付 `repayRisk` WETH + `repayLoan` USDG;分别 repay 两储备。
5. 撤 `seizeLiq` → got0 WETH + got1 USDG(价值≈seizeValue)。
6. 协议抽 `bonus×protocolFeeBps`(按价值,从两腿按比例扣或折 USDG);**keeper 净得封顶到应得 s.liquidatorSeize(F2 保留)**;超额→多还该仓债务→退借款人。
7. keeper 拿到的是 **WETH+USDG 双币**(in-kind)。封顶盈余先分别还两腿同币债务,再经 SwapExecutor 默认路径 exactInput 兑换盈余偿还另一腿,最低产出沿用预言机公允价值的 95%。只有两笔当前债务都清零才退余额。兑换失败或实付封顶后仍有债务时,余额留在金库作为协议资金并 emit `SurplusRetained`,避免借款人先于债权人取款;minOut 舍入为零的尘额同样留存。既有基线快照隔离这些资金,本次不增加提取/坏账核销机制。兑换整个盈余,超过债务的已兑换余额也只在两债清零后退还,因此债务很小时可能产生额外兑换成本。emit;全平残债按腿 → BadDebt。
- **重做点**:SettlementMath 从"单币 repay"扩成"两币 repay + 合并计价";liquidate 分账在两 token 上做;F2 封顶与超额回冲在两资产上都要成立。**这块整体重新红队**(对标已有 Exploit/Exploit2 的 F1–F2、E1/E6、G/H 全套重跑)。

## 5.5 addMargin(补保证金,单侧/双侧皆可,KousanS 2026-09-04 提出)

**原则:补保证金 = 还债优先,不是加抵押。** 同样一块钱,还债让健康余量 +1,加抵押只 +LLTV(0.8);且还债对单侧输入零 swap。

```
function addMargin(uint256 id, uint256 amountRisk, uint256 amountLoan) external nonReentrant;
```
- **单侧 WETH**:pull WETH → repay debtRisk,封顶该腿当前债务,**超出部分原路退还**(不强制 swap)。
- **单侧 USDG**:同理 repay debtLoan。
- **双侧**:各还各的腿,各自封顶、各自退超。
- **调用者不限持有人**(repay-on-behalf,同 Aave/Morpho 惯例):任何人可替仓位还债救仓,资金只会进债务、退款回付款人,无被薅面。
- **无健康门槛**:不健康时更要能补(自救优先于被清算);补完健康度严格单调改善,无需末尾健康检查。
- 两腿债务都为 0 时整笔退还(此时"保证金"无意义,加仓走 increase)。
- emit `MarginAdded(id, payer, repaidRisk, repaidLoan, refundRisk, refundLoan)`。

边界说明:
- "想把钱加进 LP 当抵押"不属于补保证金,走 increase(需按比例/由前端引导);前端把「降杠杆(还债)」和「加仓」做成两个明确入口,防用户混淆。
- 自救与清算的竞态:owner 抢在 keeper 前 addMargin 恢复健康 → keeper 的 liquidate revert Healthy,属正常自救,非漏洞(keeper 浪费一笔 gas,已知 MEV 现实)。
- 对称操作「减保证金/再借」(borrowMore,不加 LP 只提债)v1 不做,记 v1.5 议题。

## 5.9 语义定案(2026-09-04 一致性审计后写死)

- **maxSwapIn=0 = 拒绝 swap;若缺口未被 topUp 补足 → 整笔 revert("SLIPPAGE_GAP")**。不允许"跳过 swap 完成平仓"——那等于把短缺腿留成坏账还把盈余付给用户。代码已短路,不再发起必败外部调用。
- **MarginAdded 事件 = 4 字段(id, payer, repaidRisk, repaidLoan)**;超出部分根本不拉款(无 refund 字段,退款仅 wei 级 repay 封顶差,随出金归还)。
- **V3 版 OpenParams ABI 与 V4 不同**(DEX 适配):V3 用 `amount0Min/amount1Min (uint256)`(铸造下限),V4 用 `amount0Max/amount1Max (uint128)`(支付上限)。前端/keeper 按各自 ABI 接。
- **liquidate 分账优先级:协议费先于 keeper**(深水下 keeper 先被削);keeper 用 `minSeizeValue` 自保(LiquidateParams 含 minSeizeValue+deadline)。
- **percent ≥ 10000 一律按全平**;部分平仓会一次性收走全部累计 fee(抽成照扣)。
- **rebalance 的健康门为"事后检查"**:若换区间恰把仓位换回健康则放行(对用户有利的放宽)。
- 错误串已统一:两金库 `NOT_TWO_SIDED`;V4 字段名统一为 `dexTokenId`。
- 预言机构造器强制 `loanFeed ∈ {feed0, feed1}`(错配会静默指错 RISK_FEED)。

## 6. SwapExecutor 去留与扩展

- 开仓:零 swap(前端按区间比例定借款量,零头只退)。
- 平仓:**缺口 swap**(exactOutput:买恰好短缺量,投入 ≤ maxSwapIn)。
- rebalance:delta swap(exactInput,链下算净额)。
- **SwapExecutorV3 需新增 `swapExactOutput(tokenIn, tokenOut, amountOut, maxIn, path)`**(Router02 原生支持 exactOutput),同样做路径端点校验;这是 v1 的一个新合约改动点。

## 6.5 场景矩阵(穷举边界,KousanS 要求"各种情况都考虑进去")

### close 的完整价况分支(补 §3)
| 场景 | 行为 |
|---|---|
| 价≈开仓 | 缺口≈0,零 swap |
| 价涨/跌(区间内) | 盈余腿 exactOutput 买缺口 |
| **价出区间**(LP 已 100% 单币) | 一腿全短缺、另一腿持全部;缺口 swap 变大但仍封顶于 min(短缺债, 盈余),机制不变 |
| **深度水下:盈余不够补缺口** | exactOutput 买不起 → **降级为 exactInput 把盈余全部换掉**,部分覆盖,残债才记坏账。此降级分支必须实现,否则水下平仓直接 revert 卡死用户 |
| 部分平仓 | 按比例还两腿,健康度近似不变;**末尾加健康检查**(防缺口 swap 滑点把仓位磨过线);全平豁免(仓位已消灭) |
| 取整方向 | dLiq 向下取整;应还债向上取整(偏向协议/出借人),统一写死并测 |

### open 边界
- 某储备可借流动性不足 → borrow revert,**干净失败不静默少借**;前端先查 availableLiquidity。
- 前端算比例与上链之间价格跳动 → 两腿比例失配,多余成 dust 退还;**minLiquidity 就是防比例过期的保险丝**(拿到的流动性低于预期即 revert)。

### rebalance 边界
- 仓位不健康时 rebalance:末尾健康检查会拒绝(UNHEALTHY_AFTER_REBALANCE)——**不健康先 addMargin 或平仓,不许换区间**(防"换区间"被当逃生通道绕过清算)。
- 出区间仓位重新居中 = 主用例,撤出为单币,delta swap 较大但有 minSwapOut/minLiquidity 兜底。

### addMargin / liquidate 边界
- 单腿债已为 0:addMargin 该腿整笔退;liquidate 的 k 作用于双腿,零债腿 repay=0,keeper 只需带另一币。
- **feed 断/过期 → 估值 fail-closed → 清算被阻塞**:已知取舍(宁停不错杀),运维必须监控 feed 存活(DEPLOY-CHECKLIST 1.10 的 maxStaleness 收紧 + 告警)。
- keeper 现在要备**两种币的垫款**(WETH+USDG),keeper README/资金准备更新。

### 储备管理状态
- 储备 frozen:只封 borrow/newDebtPosition,**repay 不受限** → close/addMargin/清算还债在冻结期照常可用(核对 Extra 源码后落测试)。
- 利用率打满:出借人暂时无法 redeem(标准利用率模型,利率曲线飙升自调节);两储备各自独立发生。
- **两个储备都要种子存款**(捐赠压零汇率 DoS 对 WETH 储备同样成立),部署脚本/清单双储备各 seed。

### UX / 周边
- 用户持原生 ETH 而合约只收 WETH:v1 合约层只收 WETH,**wrap/unwrap 放前端**(或后续加 payable 包装入口,v1.5)。
- keeper bot:健康度公式改双债合并计价、liquidate 参数改双币、垫款双币——keeper 包同步改造列入落地顺序。
- 无迁移负担:主网未部署,绿地直接上双储备版。

## 7. 安全与不变量(重点补测)

1. **债务恒等**:rebalance 前后 debtRisk/debtLoan 各自恒等。
2. **两资产偿付能力**:每个储备的 eToken 现金 + 该储备在外债务 ≥ 名义存款(两个储备各测一遍,扩 Invariants.t.sol)。
3. **跨仓位隔离**:双币路径只动本仓两笔债(对标 G3/G6)。
4. **清算不超扣(F2)**:两资产下 keeper 净得仍封顶应得,超额回冲。
5. **重入/捐赠**:nonReentrant + 基线感知 refundDust(E6)保持。
6. **坏账按腿可观测**:每腿残债各 emit BadDebt。
7. **健康中性**:rebalance 不因换区间恶化健康(除滑点)。

## 8. 测试计划(TDD)

- 双储备集成:两储备 initReserve、两批出借人存 WETH/USDG、金库两储备授信。
- open:双币借款零 swap 铸仓、两笔债上账、健康校验;自带两腿则少借。
- close:三价况(平/涨/跌)缺口结算——匹配还债、exactOutput 缺口互补、maxSwapIn 保险丝、双币出金、两腿榨干才坏账。
- rebalance:换区间成功、两债恒等、健康中性、minSwapOut/minLiquidity 兜底、非持有人 revert。
- addMargin:单侧 WETH/单侧 USDG/双侧三分支;封顶退超;第三方代还;不健康时可补且补后健康改善;双债为零整笔退。
- liquidate(重做):两资产按比例清算、in-kind 付 keeper、F2 封顶、超额回冲、两腿坏账;**Exploit/Exploit2/Exploit3/Exploit4 全套按双资产重写重跑**。
- Invariants:handler 加双币 open/close/rebalance + 两资产清算,20 万次调用复测。

## 9. 落地顺序

1. LendingPool 加 WETH 储备 + 金库双储备接线(改 InitParams、Position、部署脚本、DEPLOY-CHECKLIST)。
2. 健康度/估值泛化(两资产合并计价)。
3. open/close 双币零 zap。
4. **liquidate 两资产重做 + 全套红队重跑**(最重、最高风险)。
5. rebalance(delta swap)。
6. keeper 侧净额与借款比例计算工具(TS)。

> review 关注点:①Position 双 debtId 与 InitParams 双储备的最终字段命名;②清算按比例 k 同时还两腿 vs 允许 keeper 指定单腿(v1 建议按比例,最简、最难被套利);③协议费在两 token 上怎么扣(按价值折算 vs 各扣各的);④open 零头只退不补 swap 是否可接受(v1 建议可)。确认后进 TDD,从"双储备集成测试"红灯起步。
