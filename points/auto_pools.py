#!/usr/bin/env python3
"""Auto LP pool-level stats for the farm UI's coming-soon rows.

Pulls TVL / 24h volume for the configured Auto LP candidate pools from the Uniswap
interface gateway (same backend the Uniswap app reads — no on-chain reinvention) and
writes auto-pools.json keyed by pool address. The frontend uses these numbers for
vaults that are not deployed yet (pool-level, labeled as such); deployed vaults read
their own on-chain state instead.

Publish like farm_fee_apr.json: copy the output into the web root's data/ dir.
"""
import json, os, time, urllib.request

GATEWAY = "https://interface.gateway.uniswap.org/v1/graphql"
HDRS = {"Content-Type": "application/json", "Origin": "https://app.uniswap.org", "User-Agent": "Mozilla/5.0"}
RPC = "https://rpc.mainnet.chain.robinhood.com/rpc"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "auto_pools.json")

# Pool addresses tracked by apps/lite/src/lib/solon-range.ts (RH mainnet entries).
POOLS = {
    "0x52e65b17fb6e5ba00ed806f37afcd2daa50271ca",  # ETH/USDG 0.01%
    "0xd4eb21209c4d6093f80b5b84f5c45cc093ea14a3",  # NVDA/USDG 0.05%
    "0x7a6a053eccf1446a2633e05aa6d40d09381997ec",  # GLD/USDG 0.3% (first-batch 2026-09-11; replaced SPY/WETH)
    "0xfab520051f96f4d2a32c22b6a3dd7fffdf231bfe",  # SGOV/USDG 0.3% (first-batch 2026-09-11)
}

Q = """query T($chain: Chain!, $first: Int!) { topV3Pools(chain: $chain, first: $first) {
  address feeTier totalLiquidity { value }
  volume24h: cumulativeVolume(duration: DAY) { value } } }"""


def _gql(query, variables):
    req = urllib.request.Request(GATEWAY, json.dumps({"query": query, "variables": variables}).encode(), HDRS)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def _lp_fee_share(pool: str) -> float:
    """LP share of swap fees. RH runs the V3 protocol fee switch (verified 2026-09-10:
    feeProtocol=68 → 1/4 to protocol on both tokens, LPs keep 75%); read it live so a
    governance change flows through. Falls back to the known 0.75 if the read fails (never over-state APR)."""
    try:
        payload = {"jsonrpc": "2.0", "id": 1, "method": "eth_call",
                   "params": [{"to": pool, "data": "0x3850c7bd"}, "latest"]}  # slot0()
        req = urllib.request.Request(RPC, json.dumps(payload).encode(),
                                     {"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=20) as r:
            res = json.load(r)["result"]
        fee_protocol = int(res[2 + 5 * 64:2 + 6 * 64], 16)
        fp0, fp1 = fee_protocol % 16, fee_protocol // 16
        shares = [1 - (1 / fp) if fp else 1.0 for fp in (fp0, fp1)]
        return min(shares)
    except Exception:
        # Conservative fallback: RH currently runs 1/4 protocol fee on all covered pools —
        # never over-state APR just because one RPC read failed.
        return 0.75


def main():
    # The gateway rate-limits and intermittently returns thin rows — retry, keep the fullest.
    best = []
    for _ in range(5):
        try:
            rows = _gql(Q, {"chain": "ROBINHOOD", "first": 40}).get("data", {}).get("topV3Pools") or []
        except Exception:
            rows = []
        if len(rows) > len(best):
            best = rows
        if best and any((r.get("volume24h") or {}).get("value") for r in best):
            break
        time.sleep(1.5)

    pools = {}
    for p in best:
        addr = (p.get("address") or "").lower()
        if addr not in POOLS:
            continue
        tvl = (p.get("totalLiquidity") or {}).get("value") or 0
        vol = (p.get("volume24h") or {}).get("value")  # None = gateway omitted it (≠ a real 0)
        fee = (p.get("feeTier") or 0) / 1e6
        if tvl <= 0 or fee <= 0 or vol is None:
            continue  # omit rather than zero-fill: the frontend shows a dash for a missing entry
        cur = pools.get(addr)
        if cur and cur["tvlUsd"] >= tvl:  # gateway can return dupes; keep the fuller row
            continue
        lp_share = _lp_fee_share(addr)
        pools[addr] = {
            "tvlUsd": tvl,
            "volume24hUsd": vol,
            "feeTier": fee,
            "lpFeeShare": lp_share,
            # LP-earned fee APR: feeTier × volume ÷ TVL, annualized, × the LP share of fees
            # (the protocol fee switch takes its cut BEFORE fees reach LPs — matches the APR
            # the Uniswap explore page shows, unlike the naive feeTier×volume number).
            "feeAprGross": (fee * vol / tvl * 365 * lp_share) if tvl > 0 else 0,
        }

    out = {"pools": pools, "computedAt": int(time.time())}
    with open(OUT, "w") as f:
        json.dump(out, f, indent=1)
    print(f"wrote {OUT}: {len(pools)}/{len(POOLS)} pools")
    for a, s in pools.items():
        print(f"  {a[:10]}… tvl=${s['tvlUsd']:,.0f} vol24h=${s['volume24hUsd']:,.0f} aprGross={s['feeAprGross']*100:.1f}%")


if __name__ == "__main__":
    main()
