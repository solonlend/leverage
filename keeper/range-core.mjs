// range keeper 的纯决策逻辑(无 IO,可单测)。
// 只在现价出主仓区间时调仓:区间内调仓不改变做市效果,只烧 gas(2026-09-14 实测 3 天 11 次定时调仓 $2.96 gas vs $0.67 手续费)。
export function decideMove({ tick, lower, upper }) {
  const inRange = tick >= lower && tick <= upper;
  return { inRange, needMove: !inRange };
}

// 估算 gas 上浮余量(默认 +30%,向上取整)。2026-09-14 gasLimit=估算值恰好 OOG 失败。
export function withGasBuffer(estimate, bufferBps = 3000n) {
  const num = estimate * (10000n + bufferBps);
  return (num + 9999n) / 10000n;
}
