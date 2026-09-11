#!/usr/bin/env python3
"""
Live fee-APR for the Solon farm pool (Uniswap V3 WETH/USDG fee-100 on Robinhood Chain).

RH mines ~10 blocks/s (~855k blocks/day), so client-side 24h Swap aggregation is infeasible.
Instead this samples the pool's cumulative feeGrowthGlobal per unit liquidity, and between two
samples computes realized fees = (feeGrowthGlobal_delta * activeLiquidity) / 2^128 per token,
values them in USD, annualizes by the elapsed wall-clock, and divides by pool TVL. Writes
farm_fee_apr.json (also copied to the web root so the frontend can read it same-origin).

Usage: python3 farm_fee_apr.py [--rpc URL]   (a cron/launchd runs it every ~30 min)
First run (no prior state): does a short in-run resample to emit an initial estimate.
"""
import json, os, sys, time, urllib.request

RPC = "https://rpc.mainnet.chain.robinhood.com/rpc"
POOL = "0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca"
WETH = "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73"
USDG = "0x5fc5360d0400a0fd4f2af552add042d716f1d168"
ETH_FEED = "0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9"
STATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "farm_fee_apr.json")
Q128 = 1 << 128
YEAR = 365.25 * 86400
MAX_SAMPLE_AGE = 6 * 3600  # ignore a stored sample older than this; re-bootstrap instead

if "--rpc" in sys.argv:
    RPC = sys.argv[sys.argv.index("--rpc") + 1]


def call(to, selector):
    payload = {"jsonrpc": "2.0", "id": 1, "method": "eth_call",
               "params": [{"to": to, "data": selector}, "latest"]}
    req = urllib.request.Request(RPC, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0 (Solon fee-apr indexer)"})
    with urllib.request.urlopen(req, timeout=20) as r:
        out = json.load(r)
    if "result" not in out:
        raise RuntimeError(f"rpc error for {selector}: {out.get('error')}")
    return int(out["result"], 16)


def balance_of(token, holder):
    return call(token, "0x70a08231" + holder[2:].rjust(64, "0"))


def latest_answer():
    # chainlink latestRoundData(): 2nd return (int256 answer), 8 decimals
    payload = {"jsonrpc": "2.0", "id": 1, "method": "eth_call",
               "params": [{"to": ETH_FEED, "data": "0xfeaf968c"}, "latest"]}
    req = urllib.request.Request(RPC, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0 (Solon fee-apr indexer)"})
    with urllib.request.urlopen(req, timeout=20) as r:
        res = json.load(r)["result"]
    answer = int(res[2 + 64:2 + 128], 16)
    return answer / 1e8  # USD per ETH


def sample():
    return {
        "ts": time.time(),
        "fg0": call(POOL, "0xf3058399"),  # feeGrowthGlobal0X128()
        "fg1": call(POOL, "0x46141319"),  # feeGrowthGlobal1X128()
        "liq": call(POOL, "0x1a686502"),  # liquidity()
    }


def tvl_and_price():
    eth = latest_answer()
    weth_bal = balance_of(WETH, POOL) / 1e18
    usdg_bal = balance_of(USDG, POOL) / 1e6
    tvl = weth_bal * eth + usdg_bal
    return tvl, eth, weth_bal, usdg_bal


def fee_apr(prev, cur, tvl, eth):
    dt = cur["ts"] - prev["ts"]
    if dt <= 0 or tvl <= 0:
        return None
    liq = cur["liq"]  # active liquidity proxy for the interval
    d0 = (cur["fg0"] - prev["fg0"]) & (Q128 * Q128 - 1)  # guard against wrap
    d1 = (cur["fg1"] - prev["fg1"]) & (Q128 * Q128 - 1)
    fee0 = (d0 * liq) / Q128 / 1e18       # WETH earned in interval
    fee1 = (d1 * liq) / Q128 / 1e6        # USDG earned in interval
    fees_usd = fee0 * eth + fee1
    return (fees_usd / tvl) * (YEAR / dt)


WINDOW = 24 * 3600  # target window; matches Uniswap's 24h fee-APR methodology once warmed up


def main():
    history = []
    if os.path.exists(STATE):
        try:
            history = json.load(open(STATE)).get("history", [])
        except Exception:
            history = []

    cur = sample()
    tvl, eth, weth_bal, usdg_bal = tvl_and_price()

    # Prune to a bit over the window and keep bounded.
    history = [h for h in history if cur["ts"] - h["ts"] < WINDOW + 3600][-200:]

    if not history:
        # Bootstrap: one short in-run resample so we emit an initial (noisy) estimate now.
        time.sleep(90)
        history = [cur]
        cur = sample()

    # Compare against the OLDEST sample still inside the 24h window (longest available window ≤ 24h).
    in_window = [h for h in history if cur["ts"] - h["ts"] <= WINDOW] or history
    prev = min(in_window, key=lambda h: h["ts"])

    apr = fee_apr(prev, cur, tvl, eth)
    history.append(cur)
    out = {
        "feeApr": apr,                       # fraction, e.g. 0.63
        "computedAt": int(cur["ts"]),
        "windowSeconds": round(cur["ts"] - prev["ts"]),
        "warmedUp": (cur["ts"] - prev["ts"]) >= WINDOW * 0.9,
        "poolTvlUsd": round(tvl),
        "ethUsd": round(eth, 2),
        "pool": POOL,
        "method": "feeGrowthGlobal delta x active liquidity over the trailing 24h, annualized / TVL",
        "history": history,                  # rolling samples; carried forward
    }
    json.dump(out, open(STATE, "w"), indent=1)
    wu = "warmed" if out["warmedUp"] else "warming"
    print(f"feeApr={apr*100:.2f}% tvl=${tvl:,.0f} eth=${eth:.0f} window={out['windowSeconds']}s ({wu})")


if __name__ == "__main__":
    main()
