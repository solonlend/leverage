"""Emit differential-test vectors from the golden model → test/vectors/fair_lp.json.
Foundry reads them and asserts FairLpMath.sol matches bit-for-bit. Covers all three
branches (price below / inside / above range) + extremes, not just the two-sided case.
"""
import json, os, random, math
from fair_lp_value_golden import (
    get_sqrt_ratio_at_tick, get_amounts_for_liquidity, fair_value_usdg, fair_value_in_loan,
    zap_swap_amount_to_token0, sqrt_price_x96_from_feeds,
)

MIN_SQRT_RATIO = 4295128739
MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342

random.seed(0xC0FFEE)  # deterministic → reproducible vectors

MIN_TICK, MAX_TICK = -887272, 887272
SPACING = 60

def aligned(t):
    return t - (t % SPACING)

def one_case(kind):
    # random current tick in a sane band (avoid extremes for realism, plus a few extremes below)
    tick_cur = aligned(random.randint(-200000, 200000))
    width = random.choice([120, 600, 1200, 6000, 60000])
    lo, hi = tick_cur - width, tick_cur + width
    lo = max(aligned(lo), MIN_TICK + SPACING)
    hi = min(aligned(hi), MAX_TICK - SPACING)
    if lo >= hi:
        lo, hi = -600, 600

    # place fair price below / inside / above the range to exercise all branches
    if kind == "below":
        sqrt_fair = get_sqrt_ratio_at_tick(lo - SPACING)
    elif kind == "above":
        sqrt_fair = get_sqrt_ratio_at_tick(hi + SPACING)
    else:
        sqrt_fair = get_sqrt_ratio_at_tick(tick_cur)

    L = random.choice([10**12, 10**15, 10**18, 3 * 10**20, 10**23])
    dec0 = random.choice([6, 8, 18])
    dec1 = random.choice([6, 8, 18])
    feed_dec = 8
    price0 = random.randint(1, 500000) * 10**(feed_dec - 2)  # $0.01 .. $5000
    price1 = random.randint(1, 500000) * 10**(feed_dec - 2)
    price_loan = random.randint(90, 110) * 10**(feed_dec - 2)  # USDG≈$0.90..$1.10 (depeg range)
    loan_dec = random.choice([6, 18])

    total_loan = random.choice([100, 1000, 50000]) * 10**loan_dec  # 开仓本金+杠杆

    value, a0, a1 = fair_value_usdg(L, lo, hi, sqrt_fair, price0, price1, feed_dec, dec0, dec1)
    value_loan, _, _ = fair_value_in_loan(L, lo, hi, sqrt_fair, price0, price1, price_loan,
                                          feed_dec, dec0, dec1, loan_dec)
    zap = zap_swap_amount_to_token0(total_loan, lo, hi, sqrt_fair, price0, price1, dec0, dec1)
    return dict(liquidity=str(L), tickLower=lo, tickUpper=hi, sqrtFair=str(sqrt_fair),
               price0=str(price0), price1=str(price1), dec0=dec0, dec1=dec1,
               priceLoan=str(price_loan), loanDec=loan_dec, totalLoan=str(total_loan),
               expA0=str(a0), expA1=str(a1), expValue=str(value), expValueLoan=str(value_loan),
               expZap=str(zap))

def main():
    cases = []
    # explicit self-check case from the golden (must reproduce the doc'd numbers)
    P = 4500.0
    tc = aligned(int(math.log(P) / math.log(1.0001)))
    lo, hi = tc - 600, tc + 600
    sf = get_sqrt_ratio_at_tick(tc)
    v, a0, a1 = fair_value_usdg(10**18, lo, hi, sf, int(4500e8), int(1e8), 8, 18, 18)
    vloan, _, _ = fair_value_in_loan(10**18, lo, hi, sf, int(4500e8), int(1e8), int(1e8), 8, 18, 18, 18)
    zp = zap_swap_amount_to_token0(1000 * 10**18, lo, hi, sf, int(4500e8), int(1e8), 18, 18)
    cases.append(dict(liquidity=str(10**18), tickLower=lo, tickUpper=hi, sqrtFair=str(sf),
                      price0=str(int(4500e8)), price1=str(int(1e8)), dec0=18, dec1=18,
                      priceLoan=str(int(1e8)), loanDec=18, totalLoan=str(1000 * 10**18),
                      expA0=str(a0), expA1=str(a1), expValue=str(v), expValueLoan=str(vloan),
                      expZap=str(zp)))
    for _ in range(120):
        cases.append(one_case("inside"))
    for _ in range(40):
        cases.append(one_case("below"))
    for _ in range(40):
        cases.append(one_case("above"))

    # flatten to typed arrays (clean for Foundry parseJson*Array)
    out = {k: [c[k] for c in cases] for k in cases[0]}
    out["n"] = len(cases)

    dst = os.path.join(os.path.dirname(__file__), "..", "test", "vectors", "fair_lp.json")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w") as f:
        json.dump(out, f)
    print(f"wrote {len(cases)} vectors -> {os.path.normpath(dst)}")

    # ── V4 feed-derived sqrtPriceX96 vectors (controlled to valid tick range) ──
    fp0, fp1, fd0, fd1, fexp = [], [], [], [], []
    # explicit anchors: 1:1 same-dec → 2^96 ; ETH/USDG ~$4500
    for p0, p1, d0, d1 in [
        (10**8, 10**8, 18, 18),
        (int(4500e8), int(1e8), 18, 18),
        (int(4500e8), int(1e8), 18, 6),
        (10**8, 10**8, 6, 18),
        (340250000000000000000000000000000000000, 1, 0, 0),
        (1, 340250000000000000000000000000000000000, 0, 0),
    ]:
        s = sqrt_price_x96_from_feeds(p0, p1, d0, d1)
        if MIN_SQRT_RATIO <= s < MAX_SQRT_RATIO:
            fp0.append(str(p0)); fp1.append(str(p1)); fd0.append(d0); fd1.append(d1); fexp.append(str(s))
    random.seed(0xFEED)
    tries = 0
    while len(fp0) < 180 and tries < 20000:
        tries += 1
        d0 = random.choice([6, 8, 18]); d1 = random.choice([6, 8, 18])
        p0 = random.randint(1, 10**12); p1 = random.randint(1, 10**12)
        s = sqrt_price_x96_from_feeds(p0, p1, d0, d1)
        if MIN_SQRT_RATIO <= s < MAX_SQRT_RATIO:
            fp0.append(str(p0)); fp1.append(str(p1)); fd0.append(d0); fd1.append(d1); fexp.append(str(s))
    feed_out = dict(fp0=fp0, fp1=fp1, fd0=fd0, fd1=fd1, fexp=fexp, n=len(fp0))
    dst2 = os.path.join(os.path.dirname(__file__), "..", "test", "vectors", "feed_sqrt.json")
    with open(dst2, "w") as f:
        json.dump(feed_out, f)
    print(f"wrote {len(fp0)} feed-sqrt vectors -> {os.path.normpath(dst2)}")
    print(f"self-check case: a0={a0} a1={a1} value={v}")

if __name__ == "__main__":
    main()
