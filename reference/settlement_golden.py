"""Golden model — 标准清算(借款币/USDG 计价,整数)。
清算按行业通用做法(Aave/Morpho/Compound/Extra 同一套,KousanS 2026-09-03 拍板"大家怎么做我们怎么做"):
  清算人替借款人还债 repay → 按 repay×(1+清算奖励 bonus_bps) 扣等值抵押品,奖励整个归清算人(激励);
  协议顶多从奖励里抽一小刀 protocol_fee_bps。借款人剩余抵押品继续留仓,不没收/不销毁/不退款。
  唯一自研=抵押品"值多少"用抗操纵公允价(LpShareOracle),清算机制走标准。
费用扁平(Extra 模型,2026-09-03 定 A):收入=借款利息+清算,无高水位绩效费。
"""

BPS = 10000


def liquidation_seize(repay_amount, bonus_bps, protocol_fee_bps):
    """标准清算(全部借款币计价)。
    repay_amount     = 清算人替借款人还掉的债
    bonus_bps        = 清算奖励(如 800 = 8%),激励清算人
    protocol_fee_bps = 协议从奖励里抽的比例(如 1000 = 抽奖励的 10%)
    返回:{repay, seizeValue, protocolFee, liquidatorSeize}
      seizeValue      = 从仓位扣走的抵押品价值 = repay×(1+bonus)
      liquidatorSeize = 清算人净得(还的债 + 净奖励)
    上层再对 seizeValue 做"不超过仓位可用抵押品"的封顶(欠水时清算人少拿奖励)。"""
    seize_value = repay_amount * (BPS + bonus_bps) // BPS
    bonus = seize_value - repay_amount
    protocol_fee = bonus * protocol_fee_bps // BPS
    liquidator_seize = seize_value - protocol_fee
    return dict(repay=repay_amount, seizeValue=seize_value,
                protocolFee=protocol_fee, liquidatorSeize=liquidator_seize)


if __name__ == "__main__":
    # 标准清算自检:还债 1000,奖励 8%,协议抽奖励 10%
    #   seize=1080,bonus=80,protocolFee=8,清算人净得=1072
    s = liquidation_seize(1000, 800, 1000)
    assert s == dict(repay=1000, seizeValue=1080, protocolFee=8, liquidatorSeize=1072), s
    # 零协议费:奖励全归清算人
    s2 = liquidation_seize(1000, 800, 0)
    assert s2 == dict(repay=1000, seizeValue=1080, protocolFee=0, liquidatorSeize=1080), s2
    print("OK settlement golden 自检通过(标准清算模型)")
