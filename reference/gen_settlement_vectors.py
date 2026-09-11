"""Emit settlement differential-test vectors → test/vectors/settlement.json."""
import json, os, random
from settlement_golden import liquidation_seize

random.seed(0x5E7712)


def main():
    rp, bb, pf = [], [], []
    e_seize, e_pfee, e_liq = [], [], []
    # golden self-check cases first, then random
    fixed = [(1000, 800, 1000), (1000, 800, 0), (10**20, 500, 1500)]
    rand = [(random.randint(0, 10**24), random.choice([500, 800, 1000]), random.choice([0, 500, 1000, 2000]))
            for _ in range(200)]
    for repay, bonus, pfee in fixed + rand:
        s = liquidation_seize(repay, bonus, pfee)
        rp.append(str(repay)); bb.append(str(bonus)); pf.append(str(pfee))
        e_seize.append(str(s["seizeValue"])); e_pfee.append(str(s["protocolFee"]))
        e_liq.append(str(s["liquidatorSeize"]))

    out = dict(
        repay=rp, bonusBps=bb, protocolFeeBps=pf,
        expSeizeValue=e_seize, expProtocolFee=e_pfee, expLiquidatorSeize=e_liq,
        nLiq=len(rp),
    )
    dst = os.path.join(os.path.dirname(__file__), "..", "test", "vectors", "settlement.json")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w") as f:
        json.dump(out, f)
    print(f"wrote {len(rp)} liq vectors -> {os.path.normpath(dst)}")


if __name__ == "__main__":
    main()
