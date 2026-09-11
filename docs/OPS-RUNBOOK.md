# 杠杆 LP 金库运维手册（WETH / USDG）

适用：RH chainId 4663，UniV3DualVault + LendingPool 双储备（USDG=1、WETH=2），2026-09-06。
依据：[部署清单](../DEPLOY-CHECKLIST.md) §0/1/2/4、用户确认的经济终审阈值、当前合约。
[设计稿](DESIGN-dual-borrow-v1.md) 为历史背景；[红队报告](../RED-TEAM-2026-09-04.md) 的旧脱锚清算实测不能代表新增硬闸后的行为。

## 0. 值班责任与上线前置

| 角色 | 谁在什么时候做什么 |
|---|---|
| 值班运维（主/备，排班表实名） | 每分钟检查；告警即建事故单，记录 UTC、区块、原始读数、触发项，通知风控与 owner 签名人 |
| LendingPool owner 签名人 | 命中停借条件立即执行暂停；目标告警后 5 分钟内确认上链，未确认每分钟升级至备用签名人 |
| 风控负责人（事故指挥） | 持续脱锚及任何硬闸触发时立即决策；决定保持暂停、清算节奏、补资、恢复及迁移提案 |
| Vault GOVERNOR 签名人 | 设置/撤销 keeper 白名单；与 LendingPool owner 是不同权限，必须分别核地址 |
| keeper 主/备运维 | 1 分钟失联即响应，自最后成功扫描起 5 分钟内切备并验证扫描/模拟；每笔清算后复核双币资金 |

- [ ] 排班表填写上述真人、备用联系人、签名设备及事故通知渠道；不得只填团队名。
- [ ] owner/GOVERNOR 的真实控制人具备上述响应时效；若为多签/时间锁，预先演练执行路径，无法满足则不得上线。
- [ ] 两 keeper 用不同 EOA、主机、RPC 和独立凭据，均已白名单；备用常驻扫描，切换只启用其执行角色。
- [ ] 每个 EOA 各备 **400 USDG / 0.2 WETH**，另备原生 gas 币（WETH 不能直接付 gas）。
- [ ] 同时满足清单 §4.3：每腿余额 ≥ closeFactor × 最大待清算单仓对应腿债务；400/0.2 是首发底线，不保证大仓足额。
- [ ] 独立市价采集与 keeper 成功扫描遥测已接通；本手册定义接口，仓库中未提供这些采集器/自动签名器。

## 1. 命令环境（只读、无交互）

在运维机 Bash 中复制；RPC、主网部署地址、两个 EOA 从签字部署记录填入环境变量，不能用测试网地址。
下面所有 `cast call` 都是只读或模拟；calldata 交给既有多签流程签署，本文不含广播脚本。

```bash
set -euo pipefail
export CAST="$HOME/.foundry/bin/cast"
export FORGE="$HOME/.foundry/bin/forge"
: "${RPC_URL:?设置 RH RPC}" "${LENDING_POOL:?设置 LendingPool 地址}"
: "${VAULT:?设置 UniV3DualVault 地址}" "${KEEPER_A:?设置主 EOA}" "${KEEPER_B:?设置备 EOA}"
export ETH_FEED=0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9
export USDG_FEED=0x61B7e5650328764B076A108EFF5fa7282a1B9aD2
export USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
export WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
# 每次命令最多 15 秒；stdin 关闭，适合 cron。不要使用 REPL。
bounded() { python3 -c 'import subprocess,sys; p=subprocess.run(sys.argv[1:],stdin=subprocess.DEVNULL,timeout=15); sys.exit(p.returncode)' "$@"; }
cc() { bounded "$CAST" call --rpc-url "$RPC_URL" --rpc-timeout 10 "$@"; }
test "$(bounded "$CAST" chain-id --rpc-url "$RPC_URL" --rpc-timeout 10)" = 4663
export ORACLE="$(cc "$VAULT" 'ORACLE()(address)')"
export POOL_OWNER="$(cc "$LENDING_POOL" 'owner()(address)')"
cc "$VAULT" 'LENDING_POOL()(address)' # 必须等于 LENDING_POOL
cc "$VAULT" 'GOVERNOR()(address)'    # 与签名排班核对
cc "$LENDING_POOL" 'paused()(bool)'
cc "$ORACLE" 'RISK_FEED()(address)' # 必须等于 ETH_FEED
cc "$ORACLE" 'LOAN_FEED()(address)' # 必须等于 USDG_FEED
cc "$ORACLE" 'RISK_MAX_STALENESS()(uint256)'   # 10800
cc "$ORACLE" 'STABLE_MAX_STALENESS()(uint256)' # 93600
cc "$ORACLE" 'STABLE_DEPEG_BPS()(uint256)'     # 50
cc "$ETH_FEED" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)'
cc "$USDG_FEED" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)'
# 五项依次 roundId / answer / startedAt / updatedAt / answeredInRound
cc "$ETH_FEED" 'decimals()(uint8)'
cc "$USDG_FEED" 'decimals()(uint8)'
cc "$ORACLE" 'riskValueInLoan(uint256)(uint256)' 1000000000000000000
```

最后一条以非零 WETH 读两条 feed，revert 必须告警，禁止把失败/空值当 0 或健康。
cron 使用绝对路径并显式注入上述环境；每分钟启动一次，单实例防重，非零退出交给监控通知渠道。

## 2. 阈值、依据、即时动作

| 检查（每分钟） | 阈值与依据 | 谁立即做什么 |
|---|---|---|
| ETH feed 年龄 | **>4500s（75min）**；兜底心跳约 1h，留 15min 抖动，领先 3h 硬闸 105min | 值班告警；owner 执行 §4 暂停，停新增借款；不等 3h |
| USDG feed 年龄 | **>90000s（25h）**；24h 心跳加 1h 容差，领先 26h 硬闸 1h | 同上；FEED1/LOAN_FEED 是同一条，不算双源 |
| 独立 USDG/USD 市价 | `abs(price−1)×10000 ≥20 bps`（0.2%） | 值班告警，交叉核价/深度，风控关注；正常噪声为万分之几，20bps 提前发现脱锚 |
| 独立 USDG/USD 市价 | **≥30 bps（0.3%）** | owner 暂停 LendingPool；30→50bps 为执行提前量，不等 feed 的日级更新 |
| feed 硬闸 | ETH 年龄 **>10800s**、USDG 年龄 **>93600s**，或 USDG feed **超出 ±50bps** | 合约在估值调用时 fail-closed；值班立即升级事故，owner 保持/补执行暂停，风控启动 §3 |
| keeper 成功扫描年龄 | **≥60s 告警、≥300s 切备逾期** | 主运维查 RPC/进程/nonce/gas；备运维在最后成功扫描后 5min 内接管 |
| keeper 资金/权限 | 每个 EOA USDG **<400e6**、WETH **<0.2e18** 或授权不足/白名单 false | keeper 运维立即补资/恢复权限；可用 keeper 为零或 5min 切备失败时 owner 暂停 |
| paused 与事故状态不符 | 已要求暂停却仍 false；或未经恢复批准变 false | 值班每分钟重复升级，owner 查回执/链/地址并重走执行流程，不能以提交成功代替执行成功 |

边界：链上允许 USDG feed 恰好 **0.995 / 1.005**，仅 `<0.995` 或 `>1.005` revert；年龄恰好 3h/26h 也允许。
硬闸不是自动写入 `paused=true`，且只看 Chainlink feed；独立市价越界不保证链上同步触发。
依据：`src/LpShareOracleV4.sol::_readFeed`，边界测试 `test/LpShareOracleV4.t.sol`。
无效 round、非正价格、未来时间戳、RPC/采集缺失同样立刻告警；不能核实估值安全时按停借处理。

### 单次检查器（阈值均可执行）

运维采集器原子写入 `$OPS_SNAPSHOT` JSON：`market` 数组至少两条独立来源，每条含
`source`（不同来源名）、`price`（USDG 的真实 USD 价格字符串）、`ts`（报价 Unix 秒）；
`keepers` 映射以小写 EOA 为 key，value 为最后一次**完整成功扫描**的 Unix 秒。
不能用本池 spot 或同一 Chainlink feed 冒充独立源；USDT 计价需先独立换算美元。
普通进程存活/启动时间不算扫描成功。来源或采集器缺失必须告警，不能手工刷新 ts 掩盖故障。
两来源任一个越线即告警/停借，交叉核价用于调查，不延迟停借；报价年龄上限 60s 是本手册采集要求。

```bash
: "${OPS_SNAPSHOT:?设置采集器 JSON 绝对路径}"
export OPS_SNAPSHOT
python3 - <<'PY'
import json, os, subprocess, time, signal
from decimal import Decimal
signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError("total timeout")))
signal.alarm(50)
level = 0
def alert(n, message):
    global level
    level = max(level, n)
    print(message, flush=True)
def call(addr, sig, *args):
    p = subprocess.run([os.environ['CAST'], 'call', addr, sig, *args,
        '--rpc-url', os.environ['RPC_URL'], '--rpc-timeout', '5', '--json'],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=7, check=True)
    return json.loads(p.stdout)
def number(v):
    return int(str(v).split()[0])
try:
    now = int(time.time()) # 运维机需 NTP；硬闸实际使用 block.timestamp
    for name, soft, hard in [('ETH_FEED', 4500, 10800), ('USDG_FEED', 90000, 93600)]:
        r = call(os.environ[name], 'latestRoundData()(uint80,int256,uint256,uint256,uint80)')
        rid, ans, _, updated, answered = map(number, r)
        age = now - updated
        print(name, 'updatedAt=', updated, 'age_seconds=', age, flush=True)
        if rid == 0 or updated == 0 or answered < rid or ans <= 0 or age < 0:
            alert(2, name + ' INVALID: STOP_NEW_BORROW')
        if age > soft: alert(2, name + ' STALE: STOP_NEW_BORROW')
        if age > hard: alert(2, name + ' HARD_AGE_EXCEEDED')
        if name == 'USDG_FEED':
            dec = number(call(os.environ[name], 'decimals()(uint8)')[0])
            peg = 10 ** dec
            if ans < peg * 9950 // 10000 or ans > peg * 10050 // 10000:
                alert(2, 'FEED_DEPEG: LIQUIDATION_BLOCKED')
    data = json.load(open(os.environ['OPS_SNAPSHOT']))
    quotes = data['market']
    if len({q['source'] for q in quotes}) < 2: raise ValueError('need two independent sources')
    for q in quotes:
        price = Decimal(q['price'])
        if not price.is_finite() or price <= 0 or not 0 <= now-int(q['ts']) < 60:
            raise ValueError('invalid/stale market quote')
        bps = abs(price - 1) * 10000
        print(q['source'], 'deviation_bps=', bps, flush=True)
        if bps >= 30: alert(2, 'MARKET_DEPEG: STOP_NEW_BORROW')
        elif bps >= 20: alert(1, 'MARKET_DEPEG: WARN')
    for key in ['KEEPER_A', 'KEEPER_B']:
        addr = os.environ[key]
        age = now - int(data['keepers'][addr.lower()])
        if age < 0: raise ValueError('future keeper heartbeat')
        if age >= 300: alert(2, key + ' SWITCH_DEADLINE: verify backup; pause if no coverage')
        elif age >= 60: alert(1, key + ' HEARTBEAT: switch within 5min of last scan')
        allowed = call(os.environ['VAULT'], 'liquidators(address)(bool)', addr)[0]
        if str(allowed).lower() != 'true': alert(1, key + ' NOT_ALLOWLISTED')
        for token, minimum in [('USDG', 400000000), ('WETH', 200000000000000000)]:
            bal = number(call(os.environ[token], 'balanceOf(address)(uint256)', addr)[0])
            allowance = number(call(os.environ[token], 'allowance(address,address)(uint256)', addr, os.environ['VAULT'])[0])
            if min(bal, allowance) < minimum: alert(1, key + ' REFILL/APPROVE ' + token)
    paused = call(os.environ['LENDING_POOL'], 'paused()(bool)')[0]
    print('paused=', paused, flush=True)
    if os.environ.get('EXPECT_PAUSED') == 'true' and str(paused).lower() != 'true':
        alert(2, 'PAUSE_NOT_EFFECTIVE: page owner')
    call(os.environ['ORACLE'], 'riskValueInLoan(uint256)(uint256)', '1000000000000000000')
except Exception as e:
    alert(2, 'CHECK_FAILED: investigate/stop new borrow; ' + str(e))
raise SystemExit(level) # 0 正常，1 告警，2 紧急人工处置；不自动签名
PY
```

## 3. 持续脱锚 / feed 停摆预案

1. 任一次 ≥0.3% 或 feed 提前阈值命中即停借；“持续”仅用于升级：连续两次分钟采样 ≥0.3%，或任一次硬闸失败，风控立即接管，每 5min 复评，不设自动放行倒计时。
2. owner 先暂停，保留还款/清算；风控核独立价格、feed 时戳、兑换深度与可变现价值，记录两腿债务和预计缺口。不能把美元价值与 USDG 面值等同。
3. **放清算顺序**：feed 有效且仍在硬带内 → 保持 LendingPool 暂停，keeper 按白名单/资金/滑点限制模拟后清算；无需 unPauseAll。报价明显不可信时不强行执行。
4. **硬闸后清算同时停摆**：`liquidate` 依赖估值，暂停开关无法绕过硬闸。停止反复发送必败交易，保留只读探测；联系 feed 运维核实更新/故障，不能伪造价格或把 stale 结果缓存成当前价。
5. 引导仓主 `addMargin` 两腿原币还债；任何人可代还。干净全平需实际清偿两腿，优先先补/还，再由持有人模拟 close；有缺口、残留 WETH 粉尘需估值、部分平仓等仍可能被硬闸挡住，不能承诺全部可退出。
6. 风控决定是否以已批准应急资金通过 `addMargin` 代偿（先登记仓位、两腿金额、授权预算）；跟踪 BadDebt/SurplusRetained。当前没有 writeOff/socialize，也没有本手册可用的留存盈余提取接口。
7. **参数调整最后讨论**：先暂停 → 在可信报价下继续可执行清算/还款 → 收紧授信/capacity 或冻结/禁借。暂停中只允许同值/降低授信和容量，不能升额或调利率。
8. 预言机时效/脱锚带、Vault ORACLE/LLTV/bonus/closeFactor/费率均为 immutable；没有现场放宽硬闸的 setter。旧清单“协议费可调”不代表当前 ABI 支持。持续硬闸只能等真实数据恢复，或另走审查、部署、迁移方案，旧仓不会自动换 oracle；不得为“放清算”擅自扩大 ±0.5%。

keeper 中断损失参考（用户确认的经济假设推演，**不是实测、不是安全承诺**）：急跌行情下，
每 **$10,000 仓位**，掉线 **3h 内缺口≈$0；6h≈$507；24h≈$4,882**。
该曲线依赖价格路径、仓位区间、债务结构/杠杆与执行假设，原始模型未随本任务提供，不能线性外推或据此等 3h；1min/5min 响应目标用于避免进入长时间无人清算窗口。

## 4. 暂停操作与路径矩阵

判断：§2 feed 提前阈值、独立脱锚 ≥0.3%、硬闸/不可信估值、无可用 keeper/切备超时、已确认合约异常或权限异常 → owner 立即暂停；仅 ≥0.2% 告警或单 keeper 失联且备用已覆盖时，先响应排查。
暂停作用于**整个 LendingPool**（所有接入金库/储备）；它不是“所有资金路径停止”。

```bash
cc "$LENDING_POOL" 'emergencyPauseAll()' --from "$POOL_OWNER" # 只读模拟权限/执行
bounded "$CAST" calldata 'emergencyPauseAll()' # owner 多签目标=LENDING_POOL，value=0，提交该 data
# 多签真实执行并取得成功回执后，独立 RPC read-back：
cc "$LENDING_POOL" 'paused()(bool)' # 必须 true；事故监控设置 EXPECT_PAUSED=true
```

| 路径 | 仅 LendingPool 暂停时 | 预言机硬闸叠加时 |
|---|---|---|
| 存款 deposit/depositAndStake、赎回 redeem/unStakeAndWithdraw | 被挡；赎回指储备出借人提取 | 同左 |
| newDebtPosition/borrow/open/increase（包括自筹零借款 increase） | 被挡 | 同左 |
| repay / addMargin | 活着；repay 仅 debt owner（金库）可调，公众经 addMargin 代还 | 仍可原币还债 |
| close（LP 平仓，区别于储备赎回） | 活着，仍受持有人/偿付/滑点等检查 | 干净全平可能可行；部分平仓和依赖估值的缺口/残债处理可能失败 |
| liquidate | 活着，仍需白名单、非健康仓、垫款与 minSeizeValue | 估值失败即被挡 |
| harvest / rebalance | 无 pool 暂停闸；仍执行各自检查 | 两者末尾检查健康度；harvest 即使不复投也依赖估值，硬闸会阻塞 |
| disableVaultToBorrow、freezeReserve、disableBorrowing | 活着，owner 操作 | 同左；保留清偿路径 |
| setCreditsOfVault / setReserveCapacity | 仅同值或降低可执行 | 同左 |
| 启用白名单/借款、解冻、增额、initReserve、activate/deActivateReserve、利率/储备费率配置 | 被挡 | 同左；不要用 deActivate 代替暂停 |

依据：`src/lending/lendingpool/LendingPool.sol` 暂停修饰符与管理函数、`src/UniV3DualVault.sol` 各入口；回归 `test/PauseLifecycle.t.sol`。
授信会随 repay 自动回补；**仅设 credit=0 不能作为持久停借开关**。用 paused/disableBorrowing/freeze 或撤借款白名单维持停借。

## 5. keeper 切换与恢复前清单

失联 t=60s：主值班告警，备用确认独立 RPC、白名单、两币余额/allowance、原生 gas、pending nonce。
只读检查原生余额/待处理 nonce：`bounded "$CAST" balance "$KEEPER_B" --rpc-url "$RPC_URL" --rpc-timeout 10`、`bounded "$CAST" nonce "$KEEPER_B" --block pending --rpc-url "$RPC_URL" --rpc-timeout 10`（主 EOA 同查）。
t≤300s：停止/隔离旧主执行租约，备用取得唯一执行权，完成新扫描和候选清算模拟；核回执后更新事故单。
无待清算仓时以成功扫描/只读探测证活，不制造清算。旧主未退出时按仓位去重，防双发；切换失败按 §4 暂停。
每次垫款回收的是双币，可能偏离目标比例；运维每笔后补足两腿，不能只看合计美元余额。

恢复由风控负责人书面批准、owner 执行、另一值班 read-back；建议恢复观察窗为连续 30min，属于本手册流程要求，非合约参数。

- [ ] 根因已排除；独立两源市价连续 30min 偏离 <0.2%，报价每次 <60s；无读失败/未来时间戳。
- [ ] ETH feed 年龄 ≤75min、USDG ≤25h，round 有效、价格为正；故障腿出现事故后的有效新 round；不要求日级 USDG 在 30min 内反复更新。
- [ ] 两 keeper 扫描年龄均 <60s，已完成切换验证，余额/授权满足 400 USDG/0.2 WETH 与实际最大待清算债务要求，gas/nonce 正常。
- [ ] `riskValueInLoan(1e18)` 成功；逐仓核 positionValue/totalDebtInLoan/isHealthy、清算积压与两腿 BadDebt；缺口有已批准处置预算。
- [ ] 核储备现金、利息/利用率、白名单、freeze/borrowingEnabled、授信/capacity 与事故前快照；暂停期间利息继续累积。
- [ ] 暂停下先模拟还款/平仓/清算所需调用；确认下列分阶段恢复计划与有限额度，不直接恢复无限授信。

```bash
# 保持双腿禁借后再解总暂停；以下仅生成 data，各笔由 owner 执行并确认后才进入下一步。
bounded "$CAST" calldata 'disableBorrowing(uint256)' 1
bounded "$CAST" calldata 'disableBorrowing(uint256)' 2
cc "$LENDING_POOL" 'unPauseAll()' --from "$POOL_OWNER" # 只读模拟
bounded "$CAST" calldata 'unPauseAll()'
cc "$LENDING_POOL" 'paused()(bool)' # 执行后必须 false；监控改为批准的恢复状态
# 恢复前后都读；每个输出第 7 项为 capacity，最后元组为 active/frozen/borrowingEnabled。
for RID in 1 2; do
  cc "$LENDING_POOL" 'reserves(uint256)(uint256,uint256,uint256,address,address,address,uint256,(uint128,uint128,uint128,uint128,uint128),uint256,uint128,uint16,(bool,bool,bool))' "$RID"
  cc "$LENDING_POOL" 'credits(uint256,address)(uint256)' "$RID" "$VAULT"
done
cc "$LENDING_POOL" 'borrowingWhiteList(address)(bool)' "$VAULT"
```

先恢复还款/清算与储备出入金观察，再按批准额度逐项恢复冻结/白名单/授信，最后 `enableBorrowing(1/2)`。
`unPauseAll` **不会**重置冻结、禁借、白名单、授信或 capacity；按上述 `reserves/credits/borrowingWhiteList` 逐项读回并登记执行回执。
经批准的小额开仓/increase/平仓烟测均需逐笔成功回执与债务读回；任一告警复发立即回 §4。
