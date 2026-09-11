#!/usr/bin/env python3
"""Solon points indexer — replayable by anyone, no server trust required.

Model (matches DESIGN-v1 and Morpho's public shards approach):
  points accrue per (market, address) as  shares x seconds  ("shards"),
  on BOTH sides: supply (lender) and borrow (borrower).
  Shares — not assets — make wash loops pointless: moving in/out earns nothing extra,
  and interest accrual is captured because borrow shares stay constant while debt grows.

  1 point = 1e12 share-units x 1 day  (USDG has 6 decimals; Morpho adds 6 virtual-share
  decimals, so 1e12 shares ~ 1 USDG). I.e. roughly "USDG-days" per side.

Scope: the curated stock/ETF -> USDG market list (solon-markets.ts is the source of truth).
Usage: python3 indexer.py            # writes points.json (and app public copy if present)
"""

import json
import re
import time
import urllib.request
from collections import defaultdict
from pathlib import Path

RPC = "https://rpc.mainnet.chain.robinhood.com/rpc"
HDR = {"Content-Type": "application/json", "User-Agent": "solon-points/1.0"}
CORE = "0x9d53d5e3bd5e8d4cbfa6db1ca238aea02e651010"

TOPIC_SUPPLY = "0xedf8870433c83823eb071d3df1caa8d008f12f6440918c20d75a3602cda30fe0"
TOPIC_WITHDRAW = "0xa56fc0ad5702ec05ce63666221f796fb62437c32db1aa1aa075fc6484cf58fbf"
TOPIC_BORROW = "0x570954540bed6b1304a87dfe815a5eda4a648f7097a16240dcd85c9b5fd42a43"
TOPIC_REPAY = "0x52acb05cebbd3cd39715469f22afbf5a17496295ef3bc9bb5944056c63ccaa09"

SUPPLY_WEIGHT = 1.0
BORROW_WEIGHT = 1.0
POINT_SCALE = 10**12 * 86400  # share-units x seconds per 1 point

# Policy (2026-09-03): points only reward users who generate revenue for Solon —
# deposits into Solon vaults, and borrowing from markets those vaults fund.
# Until the first vault deploys, the published board is empty ("accrual begins at genesis").
# Run with --all-markets for the analysis-only board across every curated market.
SOLON_VAULTS: list[str] = ["0xcbb61788fb5a1969c93a222b1a12e4d1a50c6d99"]  # Solon USDG Vault (genesis 2026-09-03)
GENESIS_BLOCK = 53155111  # vault deployment block — no accrual before this
VAULT_FUNDED_MARKETS = [
    "0x3b788195cc0f5eb987e14d91d9b8875cf742c55faf9822ae25701f71a3ed7133",  # AAPL/USDG 38.5% (Solon)
    "0xf54d700dd3fe889872bfc868788de849e8a5b1adfd73bb3d983c8e264e970604",
    "0xb6befab1632196d5c55ccf320cca0e56f6331548ace2bd8ae11b5130d7db52c5",
    "0x34e22aabcc39112dafb870cd7626a3d7f6ebdfbb3436eba34c23e4f26604b783",
    "0x5aa5f8658d66626c3640fee26fa655c66116e9626fb3ebfdd83da00772161b91",
    "0x3a102899ece6ef59195b5621897486f074ad98db36e8fabbec50195b0760ab86",
    "0x29bb3cb1a28dd968ef42292f3817b702e3400f8d877e76af1c1bbadaa7021f37",
    "0x48524bc435f468489472b207d60557c7637a241d4ba971a6c9cca5468c8e5d61",
    "0x6278621c30bb6006fa661cb9354ccf3fc40261eacb30f6a9278e9e6506acb07e",
    "0x6ec35438fc89648e0d269863633189aca4426e89e05565b9111a7e69643c5b1d",
]
TOPIC_V_DEPOSIT = "0xdcbc1c05240f31ff3ad067ef1ee35ce4997762752e3a095284754544f4c709d7"   # ERC4626 Deposit
TOPIC_V_WITHDRAW = "0xfbde797d201c681b91056529119e0b02407c7bb96a4a2c75c01fc9667232c8db"  # ERC4626 Withdraw
VAULT_SHARE_SCALE = 10**18 * 86400  # vault shares are 18-dec (~1 USDG); 1 pt = 1 USDG-day supplied

HERE = Path(__file__).resolve().parent
MARKETS_TS = HERE.parent / "refs/morpho-lite-apps/apps/lite/src/lib/solon-markets.ts"
APP_PUBLIC = HERE.parent / "refs/morpho-lite-apps/apps/lite/public/points.json"


def rpc(method, params, _pace=[0.0]):
    # gentle pacing + backoff — the public RPC rate-limits (and other local daemons share it)
    wait = max(0.0, _pace[0] + 0.2 - time.time())
    if wait > 0:
        time.sleep(wait)
    for attempt in range(6):
        _pace[0] = time.time()
        try:
            req = urllib.request.Request(
                RPC, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(), HDR
            )
            out = json.load(urllib.request.urlopen(req, timeout=60))
        except urllib.error.HTTPError as e:
            if e.code in (429, 502, 503) and attempt < 5:
                time.sleep(2**attempt)
                continue
            raise
        if "error" in out:
            raise RuntimeError(out["error"])
        return out["result"]


def load_market_ids():
    text = MARKETS_TS.read_text()
    ids = re.findall(r'"(0x[0-9a-fA-F]{64})"', text)
    if not ids:
        raise SystemExit(f"no market ids found in {MARKETS_TS}")
    return [i.lower() for i in ids]


def get_logs(topic0, market_ids, latest, from_block=0):
    """Chunked fetch — the public RPC times out on unbounded queries with big topic filters."""
    logs = []
    start, chunk = from_block, 8_000_000
    while start <= latest:
        end = min(start + chunk - 1, latest)
        try:
            part = rpc(
                "eth_getLogs",
                [
                    {
                        "address": CORE,
                        "topics": [topic0, market_ids],
                        "fromBlock": hex(start),
                        "toBlock": hex(end),
                    }
                ],
            )
        except Exception:
            if chunk <= 250_000:
                raise
            chunk //= 4
            continue
        logs.extend(part)
        start = end + 1
        if chunk < 8_000_000:
            chunk *= 2
    return logs


def vault_supply_shards(latest):
    """Supply-side points: vault share balance x seconds, from ERC4626 Deposit/Withdraw events."""
    shares = defaultdict(int)
    last_ts = {}
    shards = defaultdict(int)
    events = []
    for vault in SOLON_VAULTS:
        for topic, sign in ((TOPIC_V_DEPOSIT, +1), (TOPIC_V_WITHDRAW, -1)):
            logs = []
            start, chunk = GENESIS_BLOCK, 8_000_000
            while start <= latest:
                end = min(start + chunk - 1, latest)
                try:
                    part = rpc("eth_getLogs", [{"address": vault, "topics": [topic],
                                                "fromBlock": hex(start), "toBlock": hex(end)}])
                except Exception:
                    if chunk <= 250_000:
                        raise
                    chunk //= 4
                    continue
                logs.extend(part)
                start = end + 1
            for lg in logs:
                w = [lg["data"][2:][i:i+64] for i in range(0, len(lg["data"])-2, 64)]
                # Deposit(sender idx, owner idx, assets, shares) / Withdraw(sender idx, receiver idx, owner idx, assets, shares)
                owner = "0x" + lg["topics"][2 if topic == TOPIC_V_DEPOSIT else 3][26:]
                ev_shares = int(w[1], 16)
                events.append((int(lg["blockNumber"], 16), int(lg["logIndex"], 16), owner, sign * ev_shares, lg["blockNumber"]))
    blocks = sorted({e[4] for e in events})
    ts_of = {b: int(rpc("eth_getBlockByNumber", [b, False])["timestamp"], 16) for b in blocks}
    now = int(time.time())
    events.sort(key=lambda e: (e[0], e[1]))
    for _, _, owner, d, bhex in events:
        t = ts_of[bhex]
        if owner in last_ts:
            shards[owner] += shares[owner] * (t - last_ts[owner])
        shares[owner] = max(0, shares[owner] + d)
        last_ts[owner] = t
    for owner, s_ in shares.items():
        if s_ > 0:
            shards[owner] += s_ * (now - last_ts[owner])
    return shards


def main():
    import sys
    legacy_all = "--all-markets" in sys.argv
    if not SOLON_VAULTS and not legacy_all:
        out = {
            "generated_at": int(time.time()),
            "block": None,
            "params": {
                "supply_weight": SUPPLY_WEIGHT,
                "borrow_weight": BORROW_WEIGHT,
                "point_scale": "1e12 share-units x 1 day (~1 USDG-day)",
                "markets": 0,
                "policy": "vault deposits and vault-funded borrowing earn points; genesis 2026-09-03",
            },
            "leaderboard": [],
        }
        (HERE / "points.json").write_text(json.dumps(out, indent=1))
        if APP_PUBLIC.parent.exists():
            APP_PUBLIC.write_text(json.dumps(out))
        print("no Solon vaults deployed yet -> published empty board (use --all-markets for analysis)")
        return

    if legacy_all:
        market_ids = load_market_ids()
        genesis_from = 0
    else:
        market_ids = [m.lower() for m in VAULT_FUNDED_MARKETS]
        genesis_from = GENESIS_BLOCK
    print(f"{len(market_ids)} markets in scope (genesis_from={genesis_from})")
    latest = int(rpc("eth_blockNumber", []), 16)

    # (side, market, user) -> current shares;   user -> accumulated shards per side
    shares = defaultdict(int)
    shards = {"supply": defaultdict(int), "borrow": defaultdict(int)}
    last_ts = {}  # (side, market, user) -> last event timestamp

    events = []
    for side, topic, sign in (
        ("supply", TOPIC_SUPPLY, +1),
        ("supply", TOPIC_WITHDRAW, -1),
        ("borrow", TOPIC_BORROW, +1),
        ("borrow", TOPIC_REPAY, -1),
    ):
        logs = get_logs(topic, market_ids, latest, genesis_from)
        print(f"{side} {'+' if sign > 0 else '-'} logs: {len(logs)}")
        for lg in logs:
            data = lg["data"][2:]
            words = [data[i : i + 64] for i in range(0, len(data), 64)]
            # Supply/Repay: onBehalf is topics[3]... layouts differ:
            #  Supply(id, caller idx, onBehalf idx, assets, shares)      -> onBehalf = topics[3]
            #  Withdraw(id, caller, onBehalf idx, receiver idx, ...)     -> onBehalf = topics[2]
            #  Borrow(id, caller, onBehalf idx, receiver idx, ...)      -> onBehalf = topics[2]
            #  Repay(id, caller idx, onBehalf idx, assets, shares)      -> onBehalf = topics[3]
            topics = lg["topics"]
            if topic in (TOPIC_SUPPLY, TOPIC_REPAY):
                on_behalf = "0x" + topics[3][26:]
                ev_shares = int(words[1], 16)
            else:
                on_behalf = "0x" + topics[2][26:]
                ev_shares = int(words[2] if topic != TOPIC_WITHDRAW else words[2], 16)
            # Withdraw/Borrow data = (caller, assets, shares) -> words[0]=caller? No:
            # non-indexed for Withdraw/Borrow: caller, assets, shares -> words: [caller, assets, shares]
            if topic in (TOPIC_WITHDRAW, TOPIC_BORROW):
                ev_shares = int(words[2], 16)
            events.append(
                (
                    int(lg["blockNumber"], 16),
                    int(lg["logIndex"], 16),
                    side,
                    topics[1],
                    on_behalf,
                    sign * ev_shares,
                    lg["blockNumber"],
                )
            )

    # block timestamps
    blocks = sorted({e[6] for e in events})
    ts_of = {}
    print(f"fetching {len(blocks)} block timestamps")
    for b in blocks:
        ts_of[b] = int(rpc("eth_getBlockByNumber", [b, False])["timestamp"], 16)

    now = int(time.time())
    latest_block = rpc("eth_blockNumber", [])

    events.sort(key=lambda e: (e[0], e[1]))
    for _, _, side, market, user, dshares, bhex in events:
        key = (side, market, user)
        t = ts_of[bhex]
        if key in last_ts:
            shards[side][user] += shares[key] * (t - last_ts[key])
        shares[key] += dshares
        if shares[key] < 0:
            shares[key] = 0  # share rounding dust
        last_ts[key] = t

    # accrue open positions to "now"
    for (side, market, user), s in shares.items():
        if s > 0:
            shards[side][user] += s * (now - last_ts[(side, market, user)])

    if not legacy_all:
        vshards = vault_supply_shards(latest)
        shards["supply"] = defaultdict(int)
        for u, v in vshards.items():
            shards["supply"][u] = v
        supply_scale = VAULT_SHARE_SCALE
    else:
        supply_scale = POINT_SCALE

    users = sorted(set(shards["supply"]) | set(shards["borrow"]))
    rows = []
    for u in users:
        sp = shards["supply"][u] / supply_scale * SUPPLY_WEIGHT
        bp = shards["borrow"][u] / POINT_SCALE * BORROW_WEIGHT
        if sp + bp <= 0:
            continue
        rows.append(
            {
                "address": u,
                "supply_points": round(sp, 4),
                "borrow_points": round(bp, 4),
                "total": round(sp + bp, 4),
            }
        )
    rows.sort(key=lambda r: -r["total"])

    out = {
        "generated_at": now,
        "block": int(latest_block, 16),
        "params": {
            "supply_weight": SUPPLY_WEIGHT,
            "borrow_weight": BORROW_WEIGHT,
            "point_scale": "1e12 share-units x 1 day (~1 USDG-day)",
            "markets": len(market_ids),
        },
        "leaderboard": rows,
    }
    (HERE / "points.json").write_text(json.dumps(out, indent=1))
    if APP_PUBLIC.parent.exists():
        APP_PUBLIC.write_text(json.dumps(out))
    print(f"{len(rows)} addresses with points; top: {rows[:3]}")


if __name__ == "__main__":
    main()
