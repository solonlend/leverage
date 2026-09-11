# Dual vault liquidation keeper

Node.js 22+，viem v2。适配本仓 `UniV3DualVault` / `UniV4DualVault` 的三字段 `LiquidateParams`，不适用于 Single 金库。
每轮从 `1` 扫到 `nextPositionId - 1`，跳过 `ownerOf == 0`，调用 `isHealthy`。
健康度接口返回布尔值，因此 `would liquidate #3 (health false)` 中的 false 是链上返回值，不是数值 health factor。

## 安装与 DRY_RUN

在有依赖缓存或网络的环境安装（本次沙箱离线安装因缓存不完整未成功，未联网）：

```sh
cd keeper
npm install --ignore-scripts --no-audit --no-fund
```

RPC_URL、VAULT_ADDRESS 从部署输出配置；以下命令从工程根目录运行：

```sh
DRY_RUN=true node keeper/index.mjs --once
DRY_RUN=true node keeper/index.mjs
```

`--once` 只跑一轮；省略 DRY_RUN 仍默认 dry。DRY_RUN 不加载账户、不签名、不授权、不发交易。
不需要安装 viem 或连接 RPC 的离线验证：`node --test keeper/test/*.test.mjs`。

## 实弹

先由 governor 将 keeper 地址加入 `setLiquidator` 白名单，给 keeper 准备 gas、RISK 和 LOAN 两种还债资产，并由该账户分别授权两币给**金库地址**。
机器人不自动充值、不自动 approve；余额或 allowance 不足会使发送前模拟失败。
建议专用账户，同一私钥只跑一个实例；不要与其他发送者共享 nonce。

设置 `RPC_URL`、`VAULT_ADDRESS`、`KEEPER_PRIVATE_KEY`、正整数 `MIN_SEIZE_VALUE` 后，显式执行：

```sh
DRY_RUN=false node keeper/index.mjs
```

私钥只从进程环境读取。也可把环境变量保存在已忽略的 `.testnet/keeper.env`（dotenv 格式，文件权限 600），运行：

```sh
DRY_RUN=false node --env-file=.testnet/keeper.env keeper/index.mjs
```

不要在命令行写私钥字面值，不要启用 shell trace，不要提交密钥文件。

## 环境变量

| 变量 | 默认 / 约束 |
| --- | --- |
| `RPC_URL` | 必填，HTTP(S) RPC；不可把带凭证的 URL 打日志 |
| `VAULT_ADDRESS` | 必填，非零 Dual 金库地址 |
| `DRY_RUN` | `true`；只接受 `true` / `false`，只有 `false` 才能发交易 |
| `KEEPER_PRIVATE_KEY` | 仅实弹必填，0x 前缀 32 字节私钥 |
| `POLL_INTERVAL_MS` | `30000`，完成本轮后等待的毫秒数；各轮不重叠 |
| `RATIO_BPS` | `5000`；1–10000，链上还会按 CLOSE_FACTOR_BPS 封顶 |
| `MIN_SEIZE_VALUE` | dry 默认 `0`；实弹必填且 >0，uint256 原始 LOAN 单位 |
| `DEADLINE_SECONDS` | `120`，1–3600，发送前取本机当前 Unix 秒加此值 |
| `RPC_TIMEOUT_MS` | `10000`，1–60000，单次 RPC 超时 |
| `RPC_RETRIES` | `3`，0–10，读请求失败后最多重试次数 |
| `RETRY_DELAY_MS` | `1000`，1–60000；退避为此值乘重试序号 |
| `RECEIPT_TIMEOUT_MS` | `60000`，1–300000，单次回执等待上限 |

`MIN_SEIZE_VALUE` 是 keeper 最终收到资产的 LOAN 计价最低总值（已扣协议费），不是百分比，也不是最低利润。
USDG 为 6 位小数，例如 `1000000` 表示最低收到 1 USDG 价值；部署人须按仓位还款量及期望回收额设定实际阈值。
它是全局固定阈值，不会自动按每仓报价调整。保持系统时钟同步，deadline 由本机生成。

## 故障与监控

每轮（包括空轮和 RPC 失败轮）打印 ISO 时间戳、`scanned`、`active`、`unhealthy`、`failed`。
`scanned` 是尝试读取的 ID 数，包含已销毁仓位；单仓报错后继续下一仓；读请求有限重试。
实弹先 simulate，再串行发送和等回执；不盲目重试写请求。
发送返回错误且是否上链不明时，日志标记 `BROADCAST_UNCERTAIN`，本进程停止后续写入但继续扫描；需要人工核对 keeper nonce/链上记录后重启。
回执超时保留 pending hash，下次写入前先核对回执，该次尝试仅核对、不再发新交易。
重启前必须核对未确认交易（pending 状态只保存在内存）；不要通过自动重启来绕过不明广播状态。
日志不输出原始 RPC/库异常，避免泄漏 RPC 凭证或密钥；`failed` 连续增加时检查 RPC、白名单、余额、授权及滑点阈值。
SIGINT / SIGTERM 中止等待和后续扫描；正在进行的 RPC/回执调用在配置超时内结束，已发送交易不会被撤销。

沙箱验证只包含语法与 mock 行为，未运行 fork、实链 RPC 或真实清算。
