import { test } from 'node:test';
import assert from 'node:assert/strict';
import { feedAlerts, heartbeatAlert, nearLiquidation } from '../rules.mjs';
const now = 200000;
const round = (age, answer = 100000000n) => [1n, answer, 0n, BigInt(now-age), 1n];
for (const [name, limit] of [['ETH',4500],['USDG',90000]]) {
  for (const delta of [-1,0,1]) test(`${name} age ${limit+delta}`, () => {
    assert.equal(feedAlerts(name, round(limit+delta), 8, now).some(a=>a.key.endsWith('stale')), delta>0);
  });
}
for (const sign of [-1n,1n]) for (const [offset,level] of [[199999n,null],[200000n,'warn'],[200001n,'warn'],[299999n,'warn'],[300000n,'critical'],[300001n,'critical']]) {
  test(`peg ${sign*offset}`,()=>assert.equal(feedAlerts('USDG',round(0,100000000n+sign*offset),8,now).find(a=>a.key==='USDG:peg')?.level??null,level));
}
for (const [age,level] of [[59,null],[60,'warn'],[61,'warn'],[299,'warn'],[300,'critical'],[301,'critical']]) test(`heartbeat ${age}`,()=>assert.equal(heartbeatAlert({updatedAt:now-age},now)?.level??null,level));
for (const bad of [[0n,1n,0n,1n,1n],[2n,1n,0n,1n,1n],round(-1),round(0,0n),round(0,-1n),[1n,1n,0n,0n,1n]]) test(`invalid round ${bad}`,()=>assert.equal(feedAlerts('ETH',bad,8,now)[0].level,'critical'));
for (const bad of [null,{}, {updatedAt:now+1}, {updatedAt:0}, {updatedAt:'oops'}]) test(`bad heartbeat ${JSON.stringify(bad)}`,()=>assert.equal(heartbeatAlert(bad,now).level,'critical'));
for(const [debt,want] of [[89n,false],[90n,false],[91n,true]]) test(`utilization ${debt}`,()=>assert.equal(nearLiquidation(100n,debt,10n**18n),want));
test('zero value with debt is dangerous',()=>assert.equal(nearLiquidation(0n,1n,10n**18n),true));
