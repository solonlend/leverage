# CLM 移植对照表（机器 diff，2026-09-09）

上游:本目录三个原版文件（beefyfinance/beefy-zk，MIT）。我方:`src/range/`。
方法:逐函数提取→去注释/归一空白→预先中和纯改名（Beefy→Solon 字符串、beefyFeeRecipient→treasury、IERC20Upgradeable→IERC20）→比对。复核命令见 git log 本文件提交说明。

## StrategyPassiveManagerUniswap → RangeStrategyUniV3

**逐字未动:34 个函数**——含全部数学与流程:isCalm/_onlyCalmPeriods、twap、deposit、withdraw、beforeAction、_addLiquidity、_removeLiquidity、_checkAmounts、harvest×2、_harvest、moveTicks、claimEarnings、_claimEarnings、balances、balancesOfThis、balancesOfPool、lockedProfit、range、getKeys、currentTick、price、sqrtPrice、_tickDistance、uniswapV3MintCallback、_setTicks、_setMainTick、_setAltTick、setDeviation、setTwapInterval、setPositionWidth、retireVault 等。

**MODIFIED（4，全部与"砍 swapper"决议直接对应）**
| 函数 | 改动 | 性质 |
|---|---|---|
| `_chargeFees` | 删掉"fee 换 native 再分 caller/strategist/treasury"整段 swap 分支；改为 lpToken0/1 原币按 total→call/treasury 两方直转。比例算式结构与上游同构（amount×total/DIVISOR → ×call/DIVISOR） | 决议内,唯一动的核心函数 |
| `panic` | 删除 `_removeAllowances()` 一行（无 router 授权可撤） | swapper 连带 |
| `unpause` | 删除 `_giveAllowances()` 一行（同上） | swapper 连带 |
| `swapFee` | 仅去掉 `override` 关键字（接口继承布局变化），表达式一字未动 | 签名级 |
| `setDeviation` | **决议外实质改动（2026-09-09，已向用户单独报备）**:上游边界 `< tickSpacing×4` 隐含"1bp 池=稳定对"假设;RH 主池是 1bp 波动对（实测 120s TWAP 移动 median 2.7 / p90 8.9 / max 11 tick），3 tick 上限会把正常波动误拦成 NotCalm。改为绝对边界 `0 < dev ≤ 200 tick`,初值 30 | 参数边界,经济含义见设计 doc §2.1 |

**DELETED（10，全部为 swapper/quoter/proxy 配套）**:initialize（→constructor）、setUnirouter、_giveAllowances、_removeAllowances、setLpToken0/1ToNativePath、lpToken0/1ToNative、lpToken0/1ToNativePrice。

**基类替换**:StratFeeManagerInitializable → RangeStratManager（非升级版:Ownable+Pausable;keeper/treasury/fees/globalPause 改读 RangeFactory;lockedProfit/totalLocked/DURATION=1h/DIVISOR 逐字保留;删 unirouter/strategist/native/feeConfig/depositFee/withdrawFee/__gap）。

## BeefyVaultConcLiq → SolonRangeVault

**逐字未动:12 个函数**——deposit、withdraw、withdrawAll、previewDeposit、previewWithdraw、_getTokensRequired（滑动费全部数学）、balances、wants、want、isCalm、swapFee、inCaseTokensGetStuck。

**变更**:initialize → constructor(name,symbol) + 一次性 setStrategy(校验 strategy.vault()==this,ADDED);基类 OZ upgradeable → OZ v4 非升级(ERC20Permit/Ownable/ReentrancyGuard);MINIMUM_SHARES/PRECISION/BURN_ADDRESS 常量与全部事件逐字保留。

## 工厂（新组合件,非逐字移植）

RangeFactory = 上游 StrategyFactory(运营注册表部分:keeper/rebalancers/globalPause,逐字同义)+ VaultConcLiqFactory(部署部分)合并,**去 beacon**:createRangeVault 一笔交易 new 出不可升级 vault+strategy 并接线;费率两个数放工厂(totalFee 0.1e18 硬顶 0.15e18;callFee 0.05e18 硬顶 0.2e18),替代上游外部 FeeConfigurator。此合约按新代码对待,测试/红队全额覆盖。

## 测试期发现(红队待办输入)

- **RT-1(上游同源边界)**:首存若两币价值恰好精确相等,`_setAltTick` 两分支都不触发,alt 区间保持未初始化(lower==upper),`_addLiquidity` 在 V3 流动性数学里除零 revert。真实路径几乎不可达(需 wei 级精确相等)且只影响首存一笔(revert 无资金风险),上游同样存在。红队阶段决定是否加防御分支。

## 决议外 fork 改动追加(2026-09-09 红队轮,#3/#4)

| 函数 | 改动 | 依据 |
|---|---|---|
| `withdraw`(strategy) | 尾部 re-add 由无条件(经 onlyCalmPeriods 反致 NotCalm revert)改为 `if (!_isPaused() && isCalm())`——NotCalm 时跳过 re-add,取款永不被 calm 拦截,资金闲置策略内待下一个 calm 动作重新入池 | Codex C-1(MED):上游 zk 硬化把取款一起锁死,风暴期用户被困;与产品承诺"取款永远放行"冲突 |
| `_setAltTick` | 末分支 `else if (bal1 < amount0)` → `else`:两币价值精确相等时确定走 token0 侧,alt 区间必被初始化 | RT-1/Codex C-4:上游平衡态除零可被故意构造阻塞首存 |
