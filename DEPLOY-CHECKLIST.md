# Solon 杠杆 LP — 正式部署逐项 Check 清单 (RH V3 首发)

> **2026-09-04 更新:部署目标切换为 Dual-Borrow(`UniV3DualVault` + 双储备,脚本 `DeployRhDual.s.sol`)。**
> 本清单所有阶段照走,叠加以下 Dual 专属项:
> - [ ] D.1 双储备:initReserve(USDG)=1、initReserve(WETH)=2;金库在**两个**储备上 enableVaultToBorrow + setCredits(阶段 2 read-back 双份)
> - [ ] D.2 **两个储备都种子存款**(SEED_USDG≥1000e6 + SEED_WETH≥0.5e18;捐赠压零 DoS 对每储备独立成立,缺一不可)
> - [ ] D.3 金库 read-back 增补:RESERVE_RISK==2、RESERVE_LOAN==1、ORACLE.riskValueInLoan(1e18) 落在 ETH 现价合理区间
> - [ ] D.4 SwapExecutor 增补:exactOutput 可用(fork 演练 F-B 已证;真链烟测再验一笔小额)
> - [ ] D.5 keeper 用 `pnpm start:dual`,EOA 备 **WETH+USDG 两币垫款**,先 DRY_RUN 数日
> - [ ] D.6 ETH 出借人渠道就绪(WETH 储备要有真实供给,不能只有种子)
> - [ ] D.7 烟测(阶段 5)按 dual 流程:双币借款开仓→addMargin→rebalance→带缺口平仓(previewClose 先看缺口)

> 用法:从上到下**一项一项打勾**,每项都在链上/代码里核实无误才继续。任一项存疑就停,不许"应该没问题"。
> 目标网络:Robinhood Chain (chainId **4663**)。首发池:WETH/USDG fee100。
> 五轮红队报告见 `RED-TEAM-2026-09-04.md`;本清单把其中的部署硬前置逐条落地。

---

## 阶段 0 — 部署前置(链上核实外部地址,别信文档信链上)

这些是**别人的**合约,部署脚本里写死的 constant。逐个在链上 read 核对,错一个整套废掉。

| # | 项目 | 期望值 | 怎么核实 |
|---|---|---|---|
| 0.1 | chainId | 4663 | `cast chain-id` |
| 0.2 | USDG 代币 | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | `VerifyDeployment` 核地址/decimals；人工确认 symbol=USDG |
| 0.3 | WETH 代币 | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | `VerifyDeployment` 核地址/decimals；人工确认 symbol=WETH |
| 0.4 | 币序 | WETH < USDG(地址大小) | 必须成立 → token0=WETH(risk), token1=USDG(loan), **loanIsC0=false**。不成立则全盘参数要翻 |
| 0.5 | V3 池 POOL | `0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca` | `VerifyDeployment` 一次核对 pool 地址、token0/token1、fee、tickSpacing 及全部金库接线 |
| 0.6 | 池深度 | 足够 | `pool.liquidity()` 与两腿余额:确认是活跃深池,不是空壳。首发规模不应超过池深的合理比例 |
| 0.7 | V3 NFPM | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` | 是 NonfungiblePositionManager;`factory()` 指向 RH V3 factory |
| 0.8 | swapRouter02 ROUTER | `0xCaf681a66D020601342297493863E78C959E5cb2` | 能对 WETH/USDG fee100 成功 quote/swap(fork 上已验证) |
| 0.9 | **ETH/USD feed** | `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` | `VerifyDeployment` 核地址/description/decimals；另人工确认 `latestRoundData()` 新鲜、答案 >0 |
| 0.10 | **USDG/USD feed** | `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` | `VerifyDeployment` 核地址/description/decimals；另人工确认 `latestRoundData()` 新鲜、答案 >0 |
| 0.11 | 两条独立 feed 心跳 | 记录各自 heartbeat | 分别决定 1.10 的风险腿/稳定币腿时效阈值。`feed1` 与 `loanFeed` 在首发配置是同一条 USDG/USD feed，不得重复当成两条心跳数据 |

> ⚠️ 0.9/0.10 是资金命门:feed 认错=估值/清算全错。必须 `description()` 亲眼确认,不能凭地址猜。

---

## 阶段 1 — 关键参数确认(部署脚本入参,逐个签字)

| # | 参数 | 计划值 | 含义 / 复核要点 |
|---|---|---|---|
| 1.1 | `lltv` / 必填 `LLTV` (1e18) | **已确认 `0.77e18` (77%)**；首发以授信额度将实际敞口压至 ~70% 水平（授信见 1.15），跑顺后经 governor 放开 | 采用 Morpho Blue 九档中的 77% 档；同业单币抵押 LTV 为 75%~82.5%，本项目 LP 有双边暴露、无常损失和区间非线性，应低于同业单币档。依据 `docs/PARAM-BENCHMARK-2026-09-05.md` |
| 1.2 | `closeFactorBps` | `5000` (50%) | 单次清算最多还一半债务。标准 |
| 1.3 | `liqBonusBps` / 必填 `LIQ_BONUS_BPS` | **已确认 `700` (7%)**（2026-09-06） | 清算奖励。同业实测 4.5%~7%（Aave WETH 5%、Aave USDC 4.5%、Compound WETH 折价 7%）。建议取上沿：同业对标的是「卖掉一个币」，本项目清算人需先拆 LP、可能跨两腿兑换，成本与滑点更高；给低了无人清算，坏账转嫁协议。依据 `docs/PARAM-BENCHMARK-2026-09-05.md` §2 |
| 1.4 | `protocolFeeBps` / 必填 `PROTOCOL_FEE_BPS` | **已确认首发 `0` (0%)**（2026-09-06） | 首发阶段清算 bonus 全额让给 keeper，优先保证清算发生（固定成本下 $262 以下小仓无人清算，留存越高该线越高）。该参数可调，清算生态成熟后再升至 10~15%（同业储备金率区间） |
| 1.5 | `harvestFeeBps` | `1000` (10%) | LP 手续费的协议抽成 |
| 1.6 | `borrowFeeBps` | N/A | Dual-Borrow 金库 ABI 无此参数；不要沿用单币版部署入参 |
| 1.7 | `fee` | `100` | 池子费率档,**必须 == POOL.fee()** (见 0.5) |
| 1.8 | `minWidthTicks` | `10` | 最小区间宽度(fee100 spacing=1)。防超窄区间 |
| 1.9 | oracle `dec0/dec1/loanDec` | `18 / 6 / 6` | WETH18 / USDG6 / USDG6,**必须 == 链上 token.decimals()** (0.2/0.3) |
| 1.10 | oracle 分腿时效 + USDG 脱锚带 | **已确认**<br>`RISK_MAX_STALENESS_SECONDS=93600` (26h)<br>`STABLE_MAX_STALENESS_SECONDS=93600` (26h)<br>`STABLE_DEPEG_BPS=50` (±0.5%) | 2026-09-05 RH 主网回溯 9 轮实测：ETH/USD 间隔 30–3451s（兜底心跳约 1h），风险腿取 26h:实测 RH ETH feed 偏差触发(±0.5%)+长心跳,平静期 gap 可达 24h,取 26h 覆盖心跳避免误 fail-closed;波动期由偏差触发保新鲜(越危险越新鲜)。见 FINDING-rh-eth-feed-staleness-2026-09-06.md；USDG/USD 间隔 86403–86426s（几乎精确 24h 纯心跳），稳定币腿取 26h 覆盖日级心跳抖动。脱锚带取 ±0.5%：USDG 现价 1.00007，正常噪声在万分之几量级，±1% 要跌到 $0.99 才触发、已属明显脱锚。同业对照见 `docs/PARAM-BENCHMARK-2026-09-05.md` §2b：Aave V3 与 Morpho Blue 均不检查过期，Euler v2 检查且上界 72h；本项目两条腿阈值均落在 Euler 已采用的范围内。合约护栏：风险腿 3600–172800s（1h–48h，2026-09-06 放宽），稳定币腿 90000–172800s，脱锚带 10–500 bps |
| 1.11 | SwapExecutor `defaultFee` | `100` | 空 zapPath 时的单跳费率档,== 首发池 |
| 1.12 | `reserveLoan / reserveRisk` | `1 / 2` | 依次 initReserve(USDG/WETH)；完成后核对 `nextReserveId()==3` 与两 id 的 underlying |
| 1.13 | `SEED_USDG / SEED_WETH` | **已确认 `1000e6 / 0.5e18`**（2026-09-06） | 两储备种子存款，防捐赠压零汇率 DoS；脚本余额不足或低于下限会直接停止 |
| 1.14 | 利率曲线 (`setBorrowingRateConfig`) | **已确认**（2026-09-06）端点：0% 利用率 0% APR、90% 处 4% APR、100% 处 204% APR | 五参数全部必填：`UTILIZATION_A_BPS`、`BORROWING_RATE_A_BPS`、`UTILIZATION_B_BPS`、`BORROWING_RATE_B_BPS`、`MAX_BORROWING_RATE_BPS`；输入是利用率/APR 端点，换算见下，不是斜率。最终值由部署人确认 |
| 1.15 | `RISK_RESERVE_CAPACITY / LOAN_RESERVE_CAPACITY` | **已确认**（2026-09-06）capacity = 1000 USDG / 0.5 WETH；金库授信合计 ≤ 800 USDG / 0.4 WETH | 合约默认**无限**容量（`src/lending/lendingpool/LendingPool.sol:75-103`），首发必须显式设上限。硬结论：Aave（WETH borrowCap 240 万 / supplyCap 270 万；USDC 22.5 亿 / 25 亿）与 Compound 均设有限上限，**无一家使用无限容量**。首发按本行已确认值设置；后续扩容需 governor 另行确认 |

三个脚本 `DeployRhDual`、`DeployRhV3`、`DeploySepoliaDual` 在广播前以 `vm.envUint` 读取上述 **8 个必填变量，无默认值，任一缺失即 revert**。`LLTV` 用 1e18 定点数（77% = `770000000000000000`）；奖励、协议留存、五个利率参数均以 bps 输入（1% = 100）。零奖励/零利率允许显式填写，不能用缺省表达零。`PROTOCOL_FEE_BPS` 是清算奖励中的留存比例，与储备利息费 `reserveFeeRate` 分开。

Dual 部署脚本 `DeployRhDual`、`DeploySepoliaDual` 另有 **4 个必填、无默认** 的软启动环境变量（原始代币单位，均为 uint256）：

| 环境变量 | 首发已确认值 / 上限 | 对应储备 |
|---|---|---|
| `LOAN_RESERVE_CAPACITY` | `1000000000`（1e9，1000 USDG） | USDG，reserve 1 |
| `RISK_RESERVE_CAPACITY` | `500000000000000000`（5e17，0.5 WETH） | WETH，reserve 2 |
| `LOAN_CREDIT` | ≤ `800000000`（8e8，800 USDG） | USDG，reserve 1 |
| `RISK_CREDIT` | ≤ `400000000000000000`（4e17，0.4 WETH） | WETH，reserve 2 |

部署人必须显式传入这四项，脚本不硬编码上述容量/授信数值。两脚本均在广播前读取并校验 `LOAN_RESERVE_CAPACITY >= SEED_USDG`、`RISK_RESERVE_CAPACITY >= SEED_WETH`，在种子存款前调用 `setReserveCapacity`。Sepolia 同样使用 `SEED_USDG` / `SEED_WETH`，默认及最低值与 RH 一致（1000e6 / 0.5e18）；不得沿用旧的 500000 USDG / 200 WETH 种子量搭配首发容量。

利率函数按 `(0,0) → (uA,rA) → (uB,rB) → (100%,rMax)` 分段线性插值，要求 `uA < uB < 100%`、APR 单调不降，五项均须能容纳于 uint16。目标“90% 利用率处 4% APR、100% 处 204% APR”可表示为 `(uA,rA,uB,rB,rMax) = (0,0,9000,400,20400)`：前段 `APR(u)=4%×u/90%`，后段 `APR(u)=4%+200%×(u−90%)/10%`。这里 **200% 是后段 APR 增量，204% 才是最大 APR 端点**；不能把 `20000` 当最大端点，也不能把斜率直接填进 rateA/rateB。这只是换算示例，不是已批准部署值。三个脚本在每个储备初始化后、seed/授信/交权前调用 `setBorrowingRateConfig`，Dual 两储备应用同一组显式输入。

---

## 阶段 2 — 部署与接线(按序执行,每步 read-back 核实)

部署顺序 = 依赖顺序。首发脚本 `DeployRhDual.s.sol` 已按此写。逐步核实:

| # | 动作 | 部署后 read-back 核实 |
|---|---|---|
| 2.1 | 部署 `LpShareOracleV4(ETH_FEED, USDG_FEED, USDG_FEED, 18, 6, 6, riskMaxStaleness, stableMaxStaleness, stableDepegBps)` | 1.10 的三个环境变量必须显式导出；部署后由 `VerifyDeployment` 全量 read-back |
| 2.2 | 部署 `SwapExecutorV3(ROUTER, 100)` | `VerifyDeployment` 核对 ROUTER 与 DEFAULT_FEE |
| 2.3 | 部署 `AddressRegistry(WETH)`;`setAddress(TREASURY, governor)` | `VerifyDeployment` 核对 owner、WETH9、TREASURY、VAULT_FACTORY |
| 2.4 | 部署 `LendingPool(registry, WETH)`;依次 `initReserve(USDG)`、`initReserve(WETH)` 并分别设置五参数利率及显式容量上限 | `VerifyDeployment` 核对双储备 id/underlying/decimals/capacity/flags、eToken/staking 与 nextReserveId |
| 2.5 | 部署 `SolonVaultRegistry`;`registry.setAddress(VAULT_FACTORY, vaultReg)` | `VerifyDeployment` 核对 registry 接线与两步 ownership 的 current/pending 状态 |
| 2.6 | 部署 `UniV3DualVault(InitParams{reserveRisk:2,reserveLoan:1,...})` | 见阶段 3 统一 read-back |
| 2.7 | 分别种子存款 `SEED_USDG` / `SEED_WETH` | 两个 eToken `totalSupply()` 均 > MINIMUM_ETOKEN_AMOUNT(1000)；两腿完成后才开放借款接线 |
| 2.8 | `vaultReg.setVault(1, vault)` | `VerifyDeployment` 核对每个已部署金库的 vaultId 映射 |
| 2.9 | `lending.enableVaultToBorrow(1)` | `VerifyDeployment` 核对每个金库白名单为 true |
| 2.10 | 对 reserve 1/2 分别 `lending.setCreditsOfVault(1, reserveId, LOAN_CREDIT/RISK_CREDIT)` | `VerifyDeployment` 打印并断言每个金库所需储备授信 > 0；人工对照 1.15 的额度上限 |
| 2.11 | `vault.setLiquidator(keeper, true)` | `vault.liquidators(keeper)`==true |
| 2.12 | owner 交接：StakingRewards → AddressRegistry → VaultRegistry 发起 transfer → LendingPool 最后转移 | 多签完成 `acceptOwnership()` 后运行 `VerifyDeployment`；pending 非零会以 current/pending 具名报错，不得视为已移交 |

---

单币独立部署 `DeployRhV3` 仅初始化 USDG reserve 1（`nextReserveId()==2`），只需 USDG seed ≥1000e6，广播前余额/下限不足直接 revert；先 seed 后登记/白名单/授信。`GOVERNOR != deployer` 时移交一个 StakingRewards 和上述三个 registry/pool 的权限；治理人另行完成 VaultRegistry `acceptOwnership()` 与 `vault.setLiquidator(keeper,true)`，未完成不得上线。

## 阶段 3 — 统一只读 read-back（一条命令）

新增 `script/VerifyDeployment.s.sol`。它只执行 view/staticcall，`run()` 标记为 `view`，没有 `vm.startBroadcast` 或任何写操作。四种金库地址均为可选，但**所有实际部署的金库都必须填入对应变量**：

```bash
export DEPLOY_SHAPE=dual # 必填 dual 或 single；单储备独立部署选 single
export GOVERNOR=<multisig>
export LENDING_POOL=<lending> ADDRESS_REGISTRY=<addressRegistry> VAULT_REGISTRY=<vaultRegistry>
export ORACLE=<oracle> SWAP_EXECUTOR=<swapExecutor> ROUTER=<router> PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3
export POOL=<v3Pool> POOL_FEE=100 POOL_TICK_SPACING=1
export TOKEN0=<poolToken0> TOKEN1=<poolToken1> RISK_TOKEN=<WETH> LOAN_TOKEN=<USDG>
export RISK_TOKEN_DECIMALS=18 LOAN_TOKEN_DECIMALS=6
export RISK_RESERVE_ID=2 LOAN_RESERVE_ID=1
export RISK_RESERVE_CAPACITY=<exactOnchainCapacity> LOAN_RESERVE_CAPACITY=<exactOnchainCapacity>
export FEED0=<token0Feed> FEED1=<token1Feed> LOAN_FEED=<USDGFeed>
export FEED0_DECIMALS=8 FEED1_DECIMALS=8 LOAN_FEED_DECIMALS=8
export FEED0_DESCRIPTION='ETH / USD' FEED1_DESCRIPTION='USDG / USD' LOAN_FEED_DESCRIPTION='USDG / USD'
export RISK_MAX_STALENESS_SECONDS=<confirmedValue> STABLE_MAX_STALENESS_SECONDS=<confirmedValue> STABLE_DEPEG_BPS=<confirmedValue>
export LLTV=770000000000000000
# 按实际部署填写 1~4 组；未部署的组保持 unset，禁止漏填已经部署的金库：
export V3_VAULT=<address> V3_VAULT_ID=<id>
export V4_VAULT=<address> V4_VAULT_ID=<id>
export V3_DUAL_VAULT=<address> V3_DUAL_VAULT_ID=<id>
export V4_DUAL_VAULT=<address> V4_DUAL_VAULT_ID=<id>

~/.foundry/bin/forge script script/VerifyDeployment.s.sol:VerifyDeployment --rpc-url "$RPC_URL"
```

`single` 不要求 `RISK_RESERVE_ID`、`RISK_TOKEN_DECIMALS`、`RISK_RESERVE_CAPACITY`，但仍检查两种 LP 代币及两腿喂价；禁止配置 Dual 金库，且 `nextReserveId` 必须与单储备相符。`dual` 保持双储备检查，可包含共享借贷池的 Single 金库。仅配置 V3 金库时可不填 `PERMIT2`；配置任何 V4 金库则必须填写并核代码。Sepolia mock 的三个 description 预期均填 `Solon testnet mock / USD`。

脚本一次核对：owners/governors 与 VaultRegistry pending 状态、所选模式的储备完整配置、三条 feed 接线/decimals/description/阈值、V3 pool 与 V4 poolId 接线、V4 所需 Permit2 代码、逐金库 Registry/白名单/授信，以及所有读到的合约 runtime size ≤ 24,576B。任一不符会返回带项目名和 expected/actual 的 custom error。

脚本未覆盖、仍须人工完成：chainId 与 token symbol 身份确认；池深/首发规模判断；feed 最新轮答案与历史 heartbeat 判断；`MIN_WIDTH_TICKS`、清算/协议/harvest/closeFactor 等尚未纳入统一脚本的参数复核；逐储备读取 `reserves(id).borrowingRateConfig`，将五个 bps 输入各乘 `1e14` 与链上值对照（链上为 1e18 定点），确认未遗留 initReserve 默认曲线。

本地非 fork 回归：`~/.foundry/bin/forge test --offline --threads 1 --no-match-path 'test/fork/*'`。环境变量回归用例通过 `vm.setEnv` 修改进程环境，每个用例须自行重置输入，并串行执行以避免串扰。fork 和真实部署 read-back 另行带网验证。

---

## 阶段 4 — 权限移交与运维前置(上线前最后一关)

| # | 项目 | 要求 |
|---|---|---|
| 4.1 | **所有 owner/governor 移交多签** | 多签完成 VaultRegistry 第二步 accept 后，`VerifyDeployment` 必须通过；脚本同时核 AddressRegistry、LendingPool、已配置金库、所选模式对应的 StakingRewards，且确认 Oracle 无 owner/governor 面；SwapExecutorV3 有且仅有一个 **immutable owner 应急闸**（=部署者，仅能 `revokeRouterApproval` 归零 router 授权，不能动钱/换 router/移交）——`VerifyDeployment` 以 `SWAP_EXECUTOR_OWNER`（默认=GOVERNOR）断言其归属。注意该闸**永久留在部署者钥匙上**，引入多签后也不随治理移交，应急预案须写明 |
| 4.2 | keeper 冗余 | ≥2 个独立 keeper EOA 都 `setLiquidator(true)`,各持 WETH+USDG 垫款,都上告警。单 keeper = 单点故障 |
| 4.3 | keeper 双币垫款 | 每个 keeper EOA 的 WETH/USDG 余额分别 ≥ closeFactor × 预估最大单仓对应腿债务 |
| 4.4 | keeper 先 dry-run | `DRY_RUN=true` 空跑数日,确认 would-liquidate 与预期一致,再实弹 |
| 4.5 | 前端滑点默认值 | open 的 `amount0Min/amount1Min/minLiquidity`、close 的 `maxSwapIn/minOutRisk/minOutLoan` 必须有非零/非无限保护；keeper 的 `minSeizeValue` 同理 |
| 4.6 | 监控 `BadDebt` 事件 | 坏账一发生就告警,人工评估储备偿付 |
| 4.7 | 借款利率曲线 | 必须使用阶段 1.14 人工确认的五个环境变量，部署脚本显式覆盖 initReserve 默认曲线；每个储备 read-back 对照。储备利息费仍为独立参数（当前默认 15%），不要与清算奖励留存混淆 |
| 4.8 | 首发规模上限 | 与池深(0.6)匹配,设一个保守的储备容量 `reserveCapacity`,别一上来放开无限 |
| 4.9 | StakingRewards | v1 **不启用**代币激励;若启用先按 Extra 官方 Code Fix 核对已知坑 |
| 4.10 | 应急预案 | 明确谁能 `freezeReserve`/`deActivateReserve`,以及触发条件 |

---

## 阶段 5 — 上线烟测(小额真钱,确认闭环)

- [ ] 用小额 WETH+USDG 双腿 invest/borrow 真实 open → 链上确认两 debtId、两 eToken 与仓位变动
- [ ] harvest 一次(即使 fee≈0)确认不 revert
- [ ] 部分 close + 全平 close,确认还款、出金、NFT 销毁、无坏账事件
- [ ] keeper 对一个人为不健康小仓做一次真实清算(可控环境),确认 bonus/协议费/借款人退款分账正确
- [ ] 正常流程每笔结束后 `vault` 两币余额归零；若有历史直接捐赠，余额只能保持基线、不得被仓位带走

---

## 一句话红线

**别信文档、别信"上次是对的"、别信我——每次部署都用 `VerifyDeployment` 从链上统一 read-back，并亲眼复核脚本未覆盖的人工项。真钱上线前,再买一轮外部审计。这份清单是给审计和运维打底,不替代审计。**

### D.8 V4 金库专项(Permit2 + 体积,2026-09-04 新增)
- [ ] `VerifyDeployment` 已确认目标链 canonical Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3` codesize ≠ 0(无代码时 _armPermit2 静默跳过,真 PM 开仓必失败)
- [ ] PositionManager 地址与官方 v4-periphery 部署表逐字核对(Permit2 额度的收款方,错了=万能额度授给未知合约;审计 F1)
- [ ] LpMathExt external 库地址记录在案(forge 自动链接部署,金库 delegatecall 依赖)
- [ ] 两个 Dual 金库新增 LiquidationSurplus external 库,记录部署地址并核验链接字节码;带网 fork 重验清算跨腿兑换(5% 下限)、失败留存和两债清零后退款。监控 SurplusRetained;留存款本版无自动回收/再偿债入口。
- [ ] 部署后 `VerifyDeployment` 核 runtime size ≤ 24,576B；本地另跑 `~/.foundry/bin/forge build --sizes --no-lint` 核四金库构建余量；开一笔最小仓验证 SETTLE_PAIR 走通
- [ ] 紧急预案演练:governor 调 revokePermit2(token) 后下一笔 mint 自动重上膛
