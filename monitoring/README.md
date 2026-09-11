# Leverage 只读监控

Node.js ≥22，直接通过 `createRequire` 复用 `../keeper/node_modules/viem`（keeper 已锁定 2.56.3），无需安装新依赖或创建链接。只读 RPC，不加载 keeper 配置/私钥，不签名、不暂停合约。

## 判定来源

以 [OPS-RUNBOOK §2](../docs/OPS-RUNBOOK.md) 和 `src/UniV3DualVault.sol` 为准：

| 项目 | 实现与边界 |
|---|---|
| Feed 时效 | `latestRoundData` 的 `updatedAt`；ETH **>4500s**、USDG **>90000s** 为 critical，提示停新增借款；恰好阈值允许。无效 round、非正价格、零/未来时戳、读取失败均 critical。ETH 硬闸实际 **3h**，USDG **26h**，不是两者都 26h。 |
| USDG feed 脱锚 | 用 `decimals` 和 BigInt 交叉乘法比较，双向 **≥20bps warn、≥30bps critical**；critical 提示 `STOP_NEW_BORROW`；严格超出 ±50bps 标注硬闸，恰好 ±50bps 不标注。 |
| Keeper | 读取 JSON `{ "updatedAt": 整数Unix秒 }`；最后成功扫描 **≥60s warn、≥300s critical**，遵循手册比任务默认值更早的响应要求。缺失/非法文件 critical。 |
| BadDebt | 按真实 ABI `BadDebt(uint256 indexed id,uint256 indexed debtId,uint256 residualDebt)` 分块 `getLogs`，逐事件 critical，含区块/交易/仓位/债务腿/残债原始单位。 |
| 可选仓位巡检 | `ownerOf` 零地址跳过已销毁仓；`positionValue` 与 `totalDebtInLoan` 在同一区块读取。`debt / floor(value*LLTV/1e18) >90%` 为临近清算；有债零估值计入。数量 **≥NEAR_COUNT** 告警；默认 5 是本监控的可调运维初值，非 runbook 阈值。读取失败/超扫描上限整项 critical，绝不报正常计数。 |

**范围区别：** 本任务实现的是 USDG **feed** 检测；runbook 的 20/30bps 正式停借信号来自至少两路独立 USD 市价。feed 的日级更新可能漏掉实时脱锚，本程序不能替代独立报价采集器，也未覆盖资金/授权、paused read-back 等手册其它检查。告警建议由值班人员执行，不自动发送交易。

## 环境和启动

从仓库根目录执行。以下变量由部署环境/密钥管理服务预先注入，不要把真实 RPC 凭据、bot token、私钥写入命令历史或文件：

```bash
mkdir -p monitoring/runtime
# 必填：RPC_URL、VAULT、START_BLOCK（部署区块或明确的历史扫描起点）
# 按部署记录填写，不默认使用测试网金库。
node monitoring/index.mjs --once </dev/null
```

常驻进程由 systemd/launchd 等 supervisor 以 `node /绝对路径/leverage/monitoring/index.mjs` 启动，关闭 stdin、自动重启；不要每分钟重复启动常驻模式。SIGINT/SIGTERM 等待当前检查完成后退出。`--once` 仅跑一轮，业务告警经 notify 输出，退出码 0 不代表没有风险；配置/启动失败退出 1，交给 supervisor 报警。

| 环境变量 | 默认 / 说明 |
|---|---|
| `RPC_URL`, `VAULT`, `START_BLOCK` | 必填，HTTP(S) RPC、金库地址、十进制扫描起点 |
| `CHAIN_ID` | 4663；启动核对 RPC chainId |
| `ETH_FEED`, `USDG_FEED` | runbook §1 RH 地址；其它链必须同时覆盖 |
| `POLL_MS` | 60000；每项独立防重调度，慢项只跳过自身下一轮并发 slow 告警，不阻断喂价/心跳等其它项 |
| `RPC_TIMEOUT_MS`, `RPC_RETRIES`, `RPC_RETRY_DELAY_MS` | 5000 / 2 / 250; transport has an independent 180-second budget (below); group retries never restart an exhausted transport budget; viem retries disabled |
| `COOLDOWN_MS` | 300000；同项同级/降级在窗口内不重复，升级立即发，恢复清除状态 |
| `BLOCK_BATCH`, `CONFIRMATIONS` | 1000 / 0; total range per cycle, split into requests of at most 1000 blocks and halved on explicit range rejection; backlog reported |
| `HEARTBEAT_FILE` | `monitoring/runtime/keeper-heartbeat.json`；monitor 配置的相对路径以 monitoring 为基准 |
| `MONITOR_LOG`, `STATE_FILE` | `runtime/alerts.jsonl` / `runtime/events.json`；相对 monitoring，输出限制在 monitoring 内 |
| `HEALTH_ENABLED`, `MAX_POSITIONS`, `NEAR_COUNT` | false / 1000 / 5；扫描 ID 从 1 到 nextPositionId−1，超过上限告警，不静默截断 |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | 可选，必须同时设置；缺省只 stdout+文件 |

输出目录应为普通本地目录，勿配置指向仓外的符号链接。日志按 JSONL 追加，新建权限 0600；使用主机日志轮转管理磁盘占用。

## Keeper 心跳接线（不改 keeper/）

由 supervisor 管理下面的非交互管道，并设置两端的进程组生命周期：

```bash
set -o pipefail
export HEARTBEAT_FILE="$PWD/monitoring/runtime/keeper-heartbeat.json"
node keeper/index.mjs </dev/null | node monitoring/heartbeat.mjs
```

凭证通过 keeper 原有环境独立注入；监控进程不需要 `KEEPER_PRIVATE_KEY`。sidecar 只解析完整的
`ISO时间 heartbeat scanned=N active=N unhealthy=N failed=0`，不转发其它 stdout；源时间超过 60s、未来、格式错误或 `failed>0` 都不刷新。临时文件 + rename 原子写入，文件失败退出 1，不能用定时 touch/ping 替代成功扫描。

现有 keeper 在 `finally` 打印 heartbeat，停机中途退出循环也可能 `failed=0`。sidecar 在启动、输入 EOF/错误、收到 SIGINT/SIGTERM 或自身失败时使心跳失效，从而撤销退出时不完整扫描的最后记录；必须由 supervisor 同时管理管道两端，不能只留写端或共享同一心跳文件。SIGKILL 无法清理，仍由监控的 60/300 秒年龄边界发现失联。严格成功扫描遥测也可由 keeper 在**完整成功扫描**后原子写同一 JSON；因本任务禁止改 keeper/，未修改该行为。不要回放旧日志冒充心跳；运维机需 NTP。sidecar 吃掉 stdout，keeper 其它日志如需留存应由可信日志管线分别采集，避免原始日志流入告警通道。

## 告警与 Telegram 适配器

`createNotifier(...)` 返回 `async notify(level, msg)`，level 为 info/warn/critical。默认 stdout + JSONL，配置环境变量后追加 Telegram Bot API `sendMessage`（出站 HTTPS webhook 风格适配器，不要求公网入站 webhook）。bot 需在目标聊天中有发消息权限。不要粘贴真实 token 到 README、测试或日志。

每次 Telegram 请求 10 秒超时；日志与 Telegram 分别尝试，失败只记录固定脱敏提示，不打印异常对象、RPC URL、响应正文。任一启用渠道失败返回 false，不进入冷却，下轮重试。通知函数可注入其它渠道。冷却在内存，重启时活动告警会重新发送；恢复清除状态，下一次复发立即发。不同 BadDebt 事件不合并，可能在坏账集中发生时产生多条严重通知。

## 游标与故障恢复

事件查询、通知成功后才原子保存下一扫描区块；通知或 RPC 失败不推进，重启续扫。语义为**至少一次**：在发出告警后、游标保存前崩溃可能重复通知，不能保证恰好一次。启动必须提供 START_BLOCK，防止默认从最新块启动漏掉停机历史。调整 START_BLOCK 会改变游标 scope，旧文件不会被静默复用。

每个游标记录 chainId/金库/起点和已扫区块 hash；检查点重组或游标损坏会使 events 单项 critical，保留原游标，其它检查继续。告警为通用 `events check failed`，值班检查游标与链。恢复时停止该实例，备份 `runtime/events.json`，确认链和金库，然后以重组之前/部署区块作为 START_BLOCK 并使用新的 STATE_FILE 重扫；可能重复但不能跳过事故区间。

同一 STATE_FILE 的 `.lock` 阻止双实例；强杀可能留下锁，必须先确认对应进程已停止再移走锁文件。不要给同一监控启动不同 STATE_FILE 来绕锁。游标不会记录私钥/token。

## 离线验证

```bash
node --test monitoring/test/*.test.mjs
for file in monitoring/*.mjs monitoring/test/*.mjs; do node --check "$file" || exit 1; done
```

测试使用注入 RPC/通知、真实本地临时文件、viem ABI 编解码，无外部请求，不需要任何真实凭证。覆盖双向脱锚阈值、时间边界、坏 round、心跳格式与侧车、重试、失败隔离、事件续扫/重组、仓位阈值、冷却升级和通知失败。

RPC hardening verification: **113/113 tests passed**, **17/17 syntax checks passed**.

## Public RPC and dry verification

On chainId 4663, the configured RPC is followed by these fallback endpoints:
`https://rpc.mainnet.chain.robinhood.com/rpc`, `https://robinhood-rpc.publicnode.com`,
`https://rpc.mainnet.chain.robinhood.com`. Other chains do not receive RH fallbacks.
All requests carry a browser User-Agent and share a serialized queue with at least
1 second between requests. HTTP 403/429 and transient failures rotate endpoints
with exponential cooldowns of 2/4/8/16/32/45/45 seconds, at most 8 attempts within
a 180-second per-request budget. This transport budget replaces the short group
retry behavior for transport exhaustion; it cannot multiply through `retryRead`.

Each `getLogs` request covers at most 1,000 blocks. Explicit range rejections halve
the chunk; throttle exhaustion is an error, never an empty result. A failed later
chunk prevents advancement of the entire cycle's cursor. `BLOCK_BATCH` still
controls the total work per cycle and backlog is reported until caught up.

From the stocklend workspace root, run exactly one read-only cycle:

```bash
RPC_URL=https://rpc.mainnet.chain.robinhood.com/rpc VAULT=0x9Db7aDa64D1E8b856E15D916d886797501F28ce0 START_BLOCK=56546827 node leverage/monitoring/index.mjs --once --dry-run
```

`--dry-run` requires `--once`: it never creates a notifier or writes logs, locks,
or durable cursors, even if notification credentials exist in the environment.
It starts an in-memory cursor at START_BLOCK and prints JSON with check statuses,
the event range, and simulated alerts. Event-check failure exits 1. An unavailable
keeper heartbeat is reported honestly, never replaced by a fabricated heartbeat.
`config.mjs` requires VAULT/START_BLOCK from the environment and has no lending
address: this monitor reads the vault and feeds. Those address settings are unchanged.

2026-09-07 live dry result: chainId **4663**, head **56668092**, events successfully
scanned **56546827–56547826 (1,000 blocks)**, **0 BadDebt logs**, ETH/USDG reads passed.
The unavailable local heartbeat and remaining event backlog were reported in the
dry JSON only. A single cycle is not a full catch-up to the head. No real alerts,
persistent process, or scheduled job were enabled or tested.
