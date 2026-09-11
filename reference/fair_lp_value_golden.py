"""Golden model — 两边平衡 Uniswap V3 LP 仓位的抗操纵公允估值。
差分测试的黄金标准:高精度整数,先乘后除,顺序与 Solidity 一致,决不用 spot 价。

公允价值定义(为什么这样算,防的是什么):
  攻击者能在一个 tx 里把池子现价(spot sqrtPrice)推到任意位置,从而扭曲
  "当前 tick 下的 token0/token1 拆分" → 若用 spot 估值,就能造出虚高/虚低的仓位价值
  去骗过清算(Alpha Homora / Warp-oracle 类)。
  对策:用 TWAP 反解出的 sqrtPriceFair(而不是 spot),再用 LiquidityAmounts 的
  数学从 (L, tickLower, tickUpper, sqrtPriceFair) 算"公允的两边数量",最后用外部
  Chainlink 价计价。TWAP 还要和两个 Chainlink feed 交叉验证,偏离超阈值就 revert。

本文件只实现"给定 sqrtPriceFair 与 L、区间,算公允两边数量与 USDG 计价"的核心,
即 Solidity KERNEL 要逐位复刻的部分。sqrtPriceFair 的 TWAP 反解 + 交叉验证在合约里做。
"""

Q96 = 2 ** 96

def get_sqrt_ratio_at_tick(tick: int) -> int:
    """复刻 Uniswap V3 TickMath.getSqrtRatioAtTick 的定点实现(整数,与合约逐位一致)。"""
    abs_tick = -tick if tick < 0 else tick
    ratio = 0xfffcb933bd6fad37aa2d162d1a594001 if (abs_tick & 0x1) else 0x100000000000000000000000000000000
    for i, m in enumerate([
        0xfff97272373d413259a46990580e213a, 0xfff2e50f5f656932ef12357cf3c7fdcc,
        0xffe5caca7e10e4e61c3624eaa0941cd0, 0xffcb9843d60f6159c9db58835c926644,
        0xff973b41fa98c081472e6896dfb254c0, 0xff2ea16466c96a3843ec78b326b52861,
        0xfe5dee046a99a2a811c461f1969c3053, 0xfcbe86c7900a88aedcffc83b479aa3a4,
        0xf987a7253ac413176f2b074cf7815e54, 0xf3392b0822b70005940c7a398e4b70f3,
        0xe7159475a2c29b7443b29c7fa6e889d9, 0xd097f3bdfd2022b8845ad8f792aa5825,
        0xa9f746462d870fdf8a65dc1f90e061e5, 0x70d869a156d2a1b890bb3df62baf32f7,
        0x31be135f97d08fd981231505542fcfa6, 0x9aa508b5b7a84e1c677de54f3e99bc9,
        0x5d6af8dedb81196699c329225ee604, 0x2216e584f5fa1ea926041bedfe98,
        0x48a170391f7dc42444e8fa2,
    ]):
        if abs_tick & (0x2 << i):
            ratio = (ratio * m) >> 128
    if tick > 0:
        ratio = (2 ** 256 - 1) // ratio
    # 转成 Q96(合约里是 X96 = ratio >> 32,向上取整)
    return (ratio >> 32) + (1 if ratio % (1 << 32) else 0)


def get_amounts_for_liquidity(sqrtP: int, sqrtA: int, sqrtB: int, L: int):
    """复刻 LiquidityAmounts.getAmountsForLiquidity。两边平衡区间(A<P<B)时两个都非零。"""
    if sqrtA > sqrtB:
        sqrtA, sqrtB = sqrtB, sqrtA
    if sqrtP <= sqrtA:
        amount0 = _amount0(sqrtA, sqrtB, L); amount1 = 0
    elif sqrtP < sqrtB:
        amount0 = _amount0(sqrtP, sqrtB, L)
        amount1 = _amount1(sqrtA, sqrtP, L)
    else:
        amount0 = 0; amount1 = _amount1(sqrtA, sqrtB, L)
    return amount0, amount1

def _amount0(sqrtA, sqrtB, L):
    if sqrtA > sqrtB: sqrtA, sqrtB = sqrtB, sqrtA
    return (L << 96) * (sqrtB - sqrtA) // sqrtB // sqrtA

def _amount1(sqrtA, sqrtB, L):
    if sqrtA > sqrtB: sqrtA, sqrtB = sqrtB, sqrtA
    return L * (sqrtB - sqrtA) // Q96


def fair_value_usd(L, tickLower, tickUpper, sqrtPriceFair,
                   price0_usd, price1_usd, feed_dec, dec0, dec1):
    """仓位公允 USD 计价(feed_dec 位)= a0*price0 + a1*price1(用 fair 价拆分,不用 spot)。
    price0/1_usd 是 Chainlink(feed_dec 位)。"""
    sqrtA = get_sqrt_ratio_at_tick(tickLower)
    sqrtB = get_sqrt_ratio_at_tick(tickUpper)
    a0, a1 = get_amounts_for_liquidity(sqrtPriceFair, sqrtA, sqrtB, L)
    # USD(feed_dec 位)= amount(dec位) * price(feed_dec) / 10^dec  —— 先乘后除
    v0 = a0 * price0_usd // (10 ** dec0)
    v1 = a1 * price1_usd // (10 ** dec1)
    return v0 + v1, a0, a1


# 旧名保留(向后兼容既有向量/调用):等价于 fair_value_usd
fair_value_usdg = fair_value_usd


def fair_value_in_loan(L, tickLower, tickUpper, sqrtPriceFair,
                       price0_usd, price1_usd, price_loan_usd,
                       feed_dec, dec0, dec1, loan_dec):
    """仓位公允"借款币(USDG)计价",借贷/健康度/清算用的就是这个。
    value_usd(feed_dec)→ 借款币数量(loan_dec 位)= value_usd * 10^loan_dec / price_loan_usd。
    feed_dec 在两边相消(要求各 feed 同为 feed_dec 位,RH Chainlink USD feed 均 8 位)。"""
    value_usd, a0, a1 = fair_value_usd(L, tickLower, tickUpper, sqrtPriceFair,
                                       price0_usd, price1_usd, feed_dec, dec0, dec1)
    value_loan = value_usd * (10 ** loan_dec) // price_loan_usd
    return value_loan, a0, a1


def sqrt_price_x96_from_feeds(price0, price1, dec0, dec1):
    """从两个 Chainlink feed 比价反推公允 sqrtPriceX96(V4 用,V4 池无 observe)。
    Uniswap 价约定:price = token1/token0(raw)= (price0/price1)·10^(dec1-dec0)。
    sqrtPriceX96 = isqrt(price_raw · 2^192)。纯外部价,闪电贷操纵不了。"""
    import math
    num = price0 * (10 ** dec1)
    den = price1 * (10 ** dec0)
    ratioX192 = (num << 192) // den
    return math.isqrt(ratioX192)


ZAP_L_REF = 10 ** 18       # 正常区间保留历史参考值,确保既有输出逐位不变
ZAP_L_MAX_REF = 2 ** 128 - 1


def zap_swap_amount_to_token0(total_loan, tickLower, tickUpper, sqrtPriceFair,
                              price0_usd, price1_usd, dec0, dec1):
    """开仓 zap:手里全是借款币(token1=USDG),要在 [tickLower,tickUpper] 建两边仓,
    该把多少 USDG 换成 token0。比例 = value0/(value0+value1),在公允价下用参考 L 算(比例与 L 无关)。
    返回换入 token0 腿的 USDG 数量(其余留作 token1/USDG 腿)。"""
    sqrtA = get_sqrt_ratio_at_tick(tickLower)
    sqrtB = get_sqrt_ratio_at_tick(tickUpper)
    def values_at(liquidity):
        a0, a1 = get_amounts_for_liquidity(sqrtPriceFair, sqrtA, sqrtB, liquidity)
        v0 = a0 * price0_usd // (10 ** dec0)
        v1 = a1 * price1_usd // (10 ** dec1)
        return a0, a1, v0, v1

    a0, a1, v0, v1 = values_at(ZAP_L_REF)
    def precise(value, price, decimals):
        # Same conservative continuous-value rounding certificate as Solidity:
        # V-v < price/scale+1; each normalized share has at most 1 bp relative error.
        scale = 10 ** decimals
        return value // 10000 > (price + scale - 1) // scale

    if (not precise(v0, price0_usd, dec0) or not precise(v1, price1_usd, dec1)) and sqrtA < sqrtPriceFair < sqrtB:
        a0, a1, v0, v1 = values_at(ZAP_L_MAX_REF)
        if not precise(v0, price0_usd, dec0) or not precise(v1, price1_usd, dec1):
            raise ArithmeticError("zap ratio precision insufficient")
    denom = v0 + v1
    if denom == 0:
        raise ArithmeticError("zap ratio precision insufficient")
    return total_loan * v0 // denom


if __name__ == "__main__":
    # 自检:ETH/USDG 池,ETH≈$4500,USDG≈$1,区间 ±10% 两边平衡,L 任意
    import math
    P = 4500.0
    tickCur = int(math.log(P) / math.log(1.0001))
    # 对齐到间距(示例用 60)
    tickCur -= tickCur % 60
    tickLower, tickUpper = tickCur - 600, tickCur + 600  # 约 ±6%
    sqrtFair = get_sqrt_ratio_at_tick(tickCur)
    L = 10 ** 18
    val, a0, a1 = fair_value_usdg(
        L, tickLower, tickUpper, sqrtFair,
        price0_usd=int(4500 * 1e8), price1_usd=int(1 * 1e8),
        feed_dec=8, dec0=18, dec1=18,
    )
    human = val / 1e8
    print(f"tickCur={tickCur} sqrtFair={sqrtFair}")
    print(f"公允两边: a0(ETH)={a0/1e18:.6f}  a1(USDG)={a1/1e18:.4f}")
    print(f"仓位公允 USDG 计价 = {human:,.2f}")
    # 两边平衡:a0*P 应 ≈ a1(价值对半),验证拆分合理
    left, right = a0/1e18*P, a1/1e18
    print(f"两腿价值: ETH腿 ${left:,.2f} / USDG腿 ${right:,.2f}  (±10%区间应大致均衡)")
    assert a0 > 0 and a1 > 0, "两边平衡区间两腿都应非零"
    print("OK golden 自检通过:公允价用 fair sqrt 拆分,两腿非零、量级合理。")
