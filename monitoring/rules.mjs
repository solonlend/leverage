// Source: docs/OPS-RUNBOOK.md §2. ETH hard age is 3h, USDG 26h.
const alert = (key, level, msg) => ({key, level, msg});
export function feedAlerts(name, round, decimals, now) {
  const [id, answer, , updatedAt, answered] = round;
  const age = BigInt(now) - updatedAt;
  if (id <= 0n || answer <= 0n || updatedAt <= 0n || answered < id || age < 0n || !Number.isInteger(decimals) || decimals < 0 || decimals > 36)
    return [alert(`${name}:invalid`, 'critical', `${name} invalid feed: STOP_NEW_BORROW`)];
  const result = [];
  const soft = name === 'ETH' ? 4500n : 90000n;
  const hard = name === 'ETH' ? 10800n : 93600n;
  if (age > soft) result.push(alert(`${name}:stale`, 'critical', `${name} updatedAt=${updatedAt} age=${age}s: STOP_NEW_BORROW${age>hard?' HARD_AGE_EXCEEDED':''}`));
  if (name === 'USDG') {
    const peg = 10n ** BigInt(decimals);
    const deviation = (answer > peg ? answer-peg : peg-answer)*10000n;
    if (deviation >= peg*20n) result.push(alert('USDG:peg', deviation>=peg*30n?'critical':'warn',
      `USDG feed answer=${answer} decimals=${decimals} updatedAt=${updatedAt}: ${deviation>=peg*30n?'STOP_NEW_BORROW':'cross-check independent market'}${deviation>peg*50n?' HARD_DEPEG_EXCEEDED':''}`));
  }
  return result;
}
export function heartbeatAlert(data, now) {
  if (!Number.isSafeInteger(data?.updatedAt) || data.updatedAt<=0 || data.updatedAt>now)
    return alert('keeper:heartbeat','critical','Keeper successful-scan heartbeat missing/invalid; verify backup coverage');
  const age = now-data.updatedAt;
  if (age>=60) return alert('keeper:heartbeat',age>=300?'critical':'warn',`Keeper last successful scan age=${age}s${age>=300?'; SWITCH_DEADLINE: verify backup; pause if no coverage':''}`);
  return null;
}
// health here means debt utilization of liquidation capacity; >90%, not >=90%.
export function nearLiquidation(value, debt, lltv) {
  if (value<0n || debt<0n || lltv<=0n || lltv>10n**18n) throw Error('invalid health data');
  return debt*100n > ((value*lltv)/10n**18n)*90n;
}
