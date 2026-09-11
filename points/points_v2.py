"""Solon points v2 — revenue attribution (DESIGN-points-v2.md). Replayable by anyone.

Unit: 1 point = 1 USD of realized protocol revenue attributable to the address (× global K).

Leverage-line facts (verified on RH mainnet 2026-09-11; hardened by Codex review):
  - Every harvest-fee skim transfers the cut as ERC20 Transfer(vault → GOVERNOR). The
    skim transfers are emitted BEFORE the position event of the same operation, so within
    a tx each transfer attaches to the NEXT position event in log order (segment_tx) —
    multiple operations per tx stay separated, and a liquidation segment never poisons a
    harvest segment (or vice versa).
  - close() burns the position NFT BEFORE skimming, so a block-level owner lookup would
    hit the zero address: ownership is resolved by (block, logIndex) order and always to
    the last non-zero holder before the skim (owner_before).
  - When the position owner IS the governor, harvest/close also send net proceeds
    vault → governor, which a recipient-only filter would misread as revenue (up to 10×).
    Harvested segments reconstruct the true cut from the event's NET amounts
    (cut = net·bps/(10000−bps), documented ±1 raw unit); fee-less segments (close /
    rebalance) with a governor owner are marked ambiguous, excluded from attribution and
    surfaced in the recon block instead of silently counted.
  - `Harvested(uint256 indexed id, uint256 fee0, uint256 fee1, bool compound)` fee0/fee1
    are NET of the skim. HARVEST_FEE_BPS=1000 mainnet; liquidation PROTOCOL_FEE_BPS=0 and
    liquidation segments never earn points (penalties are not rewarded).
  - reserveFeeRate = 1500 bps both reserves (15% of borrower interest → treasury). The
    reserve line is NOT wired into Stage A output: repaid−borrowed only equals realized
    interest for fully-settled, non-reused debts, and the vault reuses debt ids on
    increase — correct interest accounting needs a borrowingIndex replay (own task).

Flagship-pool scope: token0=WETH(18dp), token1=USDG(6dp), asserted on-chain at startup
(check_flagship) — never silently reused for another pool. Pure functions are offline-
testable (points/test_points_v2.py); RPC replay lives in main() only. v1 outputs are
frozen and untouched.
"""

ZERO = "0x0000000000000000000000000000000000000000"
DEAD = "0x000000000000000000000000000000000000dead"  # MINIMUM_SHARES donation sink — unclaimable
WETH_UNIT = 10**18
USDG_UNIT = 10**6


def skim_usd(cut0: int, cut1: int, eth_px: float) -> float:
    """USD value of one skim (cut0 = WETH raw 18dp, cut1 = USDG raw 6dp)."""
    return (cut0 / WETH_UNIT) * eth_px + (cut1 / USDG_UNIT)


def net_to_cut(net_amount: int, harvest_fee_bps: int) -> int:
    """Reconstruct the protocol cut from a NET (post-skim) event amount.

    cut = gross·bps/10000 (contract floors the cut), net = gross − cut. Pure net cannot
    uniquely recover gross, so this is cut ≈ net·bps/(10000−bps) with a documented error
    of at most +1 raw unit (e.g. net=9, bps=1000 → 1 while the contract floored to 0);
    at USDG 6dp that is $0.000001 — attribution noise, never claimed exact.
    """
    if harvest_fee_bps == 0:
        return 0
    if harvest_fee_bps >= 10000:
        raise ValueError("bps must be < 10000")
    return net_amount * harvest_fee_bps // (10000 - harvest_fee_bps)


def owner_before(nft_transfers, pos_id: int, block: int, log_index: int):
    """Holder of pos_id strictly before (block, log_index), skipping burns.

    nft_transfers: [{pos_id, to, block, log_index}] in any order. The close path burns
    the NFT before skimming, so the burn (to = ZERO) must never swallow attribution:
    the last NON-ZERO recipient before the skim's position in log order wins.
    """
    best_key, owner = None, None
    for t in nft_transfers:
        if t["pos_id"] != pos_id or t["to"] == ZERO:
            continue
        key = (t["block"], t["log_index"])
        if key < (block, log_index) and (best_key is None or key > best_key):
            best_key, owner = key, t["to"]
    return owner


def segment_tx(tx_items, block: int):
    """Split one tx's interleaved rows into per-operation skims.

    tx_items: [{kind_row: 'transfer'|'event', log_index, ...}] for ONE tx —
    transfers carry {token: 'weth'|'usdg', amount}; events carry {pos_id, kind} and,
    for harvested, {net0, net1}. Contract order is skim-transfers-then-event, so each
    transfer belongs to the next event at a higher log_index. Transfers with no
    following event are orphans (surfaced, never silently dropped).
    """
    items = sorted(tx_items, key=lambda x: x["log_index"])
    skims, orphans = [], []
    pending = {"cut0": 0, "cut1": 0, "first_li": None}
    for it in items:
        if it["kind_row"] == "transfer":
            pending["cut0" if it["token"] == "weth" else "cut1"] += it["amount"]
            if pending["first_li"] is None:
                pending["first_li"] = it["log_index"]
        else:
            s = {"pos_id": it["pos_id"], "kind": it["kind"], "block": block,
                 "log_index": it["log_index"], "cut0": pending["cut0"], "cut1": pending["cut1"]}
            if "net0" in it:
                s["net0"], s["net1"] = it["net0"], it["net1"]
            skims.append(s)
            pending = {"cut0": 0, "cut1": 0, "first_li": None}
    if pending["cut0"] or pending["cut1"]:
        orphans.append({"block": block, "log_index": pending["first_li"],
                        "cut0": pending["cut0"], "cut1": pending["cut1"]})
    return skims, orphans


def resolve_governor_self(skim, owner, governor, bps):
    """Correct or quarantine skims whose owner is the governor.

    Owner == governor means net proceeds ALSO landed at the governor address, so raw
    transfer sums overstate revenue. Harvested segments carry event NET amounts and the
    true cut is reconstructed from them; fee-less kinds (closed/rebalanced) cannot be
    separated and are marked ambiguous — excluded from attribution, shown in recon.
    Non-governor owners pass through unchanged.
    """
    s = dict(skim)
    if owner is None or owner.lower() != governor.lower():
        return s
    if s["kind"] == "harvested" and "net0" in s:
        s["cut0"] = net_to_cut(s["net0"], bps)
        s["cut1"] = net_to_cut(s["net1"], bps)
    else:
        s["ambiguous"] = True
    return s


def attribute_skims(skims, exclude_kinds=("liquidated",)):
    """Per-owner USD revenue points. Each skim carries its own resolved owner.

    Excluded: liquidation segments (penalties are not rewarded), ambiguous segments
    (governor-self, fee amount unrecoverable), zero/None owners (defensive: a burn must
    never mint points to the zero address).
    """
    pts = {}
    for s in skims:
        if s["kind"] in exclude_kinds or s.get("ambiguous"):
            continue
        owner = s.get("owner")
        if not owner or owner == ZERO:
            continue
        usd = skim_usd(s["cut0"], s["cut1"], s["eth_px"])
        if usd > 0:
            pts[owner] = pts.get(owner, 0.0) + usd
    return pts


def reserve_fee_points(debts, fee_rate_bps: int):
    """Borrower-attributed reserve revenue — NOT wired into Stage A output.

    Valid ONLY for fully-settled, never-reused debts: repaid−borrowed understates
    interest on partially-repaid debts and the vault reuses debt ids on increase, which
    can cancel history. Kept as the settled-debt special case; the general line needs a
    borrowingIndex replay (see plan Stage A3').
    """
    pts = {}
    for d in debts:
        interest = max(0.0, d["repaid_usd"] - d["borrowed_usd"])
        usd = interest * fee_rate_bps / 10000.0
        if usd > 0:
            pts[d["owner"]] = pts.get(d["owner"], 0.0) + usd
    return pts


def check_flagship(dec0: int, dec1: int):
    """Abort unless the pool matches the flagship WETH(18)/USDG(6) layout this module
    hard-codes. A silent decimals mismatch would mis-scale USD by up to 1e12."""
    if (dec0, dec1) != (18, 6):
        raise SystemExit(f"flagship-pool guard: token decimals {(dec0, dec1)} != (18, 6)")


def cache_key(chain_id: int, vault: str, genesis: int) -> str:
    """Scan-cache identity: same chain + vault + scan floor, address case-insensitive."""
    return f"{chain_id}:{vault.lower()}:{genesis}"


def share_balances_at(transfers, block: int):
    """CLM vault share balances at end of `block`, replayed from ERC20 Transfer logs.

    transfers: [{from, to, amount, block, log_index}]. Mint = from ZERO, burn = to ZERO.
    Zero balances are dropped so conservation checks read cleanly.
    """
    bal = {}
    for t in sorted(transfers, key=lambda x: (x["block"], x["log_index"])):
        if t["block"] > block:
            break
        if t["from"] != ZERO:
            bal[t["from"]] = bal.get(t["from"], 0) - t["amount"]
        if t["to"] != ZERO:
            bal[t["to"]] = bal.get(t["to"], 0) + t["amount"]
    return {a: v for a, v in bal.items() if v > 0}


def clm_harvest_points(harvests, balances_at, exclude=()):
    """Share-pro-rata revenue split, used by the Auto LP and lending lines.

    harvests: [{block, treasury_usd}]; balances_at(block) -> {addr: shares}.
    Excluded from credit (their slice stays unissued, denominator unchanged): the DEAD
    seed-donation sink, and any `exclude` addresses — e.g. the lending vault's own
    feeRecipient, whose accumulated fee shares are the revenue itself.
    Empty supply → nobody credited (seed-only vaults can harvest dust).
    """
    skip = {DEAD} | {a.lower() for a in exclude}
    pts = {}
    for h in harvests:
        bal = balances_at(h["block"])
        total = sum(bal.values())
        if total == 0:
            continue
        for addr, shares in bal.items():
            if addr.lower() in skip:
                continue
            usd = h["treasury_usd"] * shares / total
            if usd > 0:
                pts[addr] = pts.get(addr, 0.0) + usd
    return pts


def merge_lines(lines, k: float = 1.0):
    """Merge per-line USD attributions into the published board shape.

    lines: {line_name: {addr: usd}} → {addr_lower: {points, breakdown}} with the global
    K multiplier applied last. Addresses merge case-insensitively.
    """
    merged = {}
    for name, table in lines.items():
        for addr, usd in table.items():
            slot = merged.setdefault(addr.lower(), {"points": 0.0, "breakdown": {}})
            slot["points"] += usd * k
            slot["breakdown"][name] = slot["breakdown"].get(name, 0.0) + usd * k
    return merged


def use_proxy(trailing_30d_revenue_usd: float, threshold_usd: float = 100.0) -> bool:
    """Cold-start switch per product line."""
    return trailing_30d_revenue_usd < threshold_usd


def proxy_points(principal_usd_days: float, target_rate_annual: float) -> float:
    """Cold-start proxy accrual (v1-style principal-days × target annual fee rate)."""
    return principal_usd_days * target_rate_annual / 365.0




def _receipt(url, tx):
    """Direct eth_getTransactionReceipt — minimal dependency on fp's shared budget."""
    import json as _json
    import urllib.request as _rq
    body = _json.dumps({"jsonrpc": "2.0", "id": 1,
                        "method": "eth_getTransactionReceipt", "params": [tx]}).encode()
    req = _rq.Request(url, body, {"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"})
    with _rq.urlopen(req, timeout=30) as r:
        out = _json.load(r)
    if "result" not in out or out["result"] is None:
        raise RuntimeError(out.get("error", "no result"))
    return out["result"]

# ────────────────────────────── replay (RPC side) ──────────────────────────────
# Reuses farm_points' transport (paced RPC, chunked getLogs, RH-friendly UA).

def main():
    import argparse, json, time
    from pathlib import Path
    from points import farm_points as fp

    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc", default=fp.RPC_URLS[0])
    ap.add_argument("--chain-id", type=int, default=4663)
    ap.add_argument("--vault", default="0x9Db7aDa64D1E8b856E15D916d886797501F28ce0")
    ap.add_argument("--oracle", default="0x52b5728D1086b0B68d98DD51ee6544d87062Ef0f")  # LpShareOracleV4
    ap.add_argument("--cache", default="/tmp/points-v2-scan-cache.json")
    ap.add_argument("--out", default=str(Path(__file__).parent / "points_v2.json"))
    ap.add_argument("--genesis", type=int, default=53_955_000)  # DeployRhDual receipt 53,955,547
    ap.add_argument("--harvest-fee-bps", type=int, default=1000)
    args = ap.parse_args()
    url = args.rpc

    latest = int(fp.rpc(url, "eth_blockNumber", []), 16)
    genesis = args.genesis

    # px first — fail fast, never after a 2-hour scan. Oracle path (v1 pattern), raw
    # feed fallback with signed parse + sanity bounds.
    px_source = "oracle:riskValueInLoan"
    try:
        px = int(fp.call(url, args.oracle, "0x" + fp.SEL_RISK_VALUE + hex(10**18)[2:].zfill(64)), 16) / 1e6
    except Exception:
        raw = int(fp.call(url, "0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9", "0x50d25bcd"), 16)  # latestAnswer()
        if raw >= 2**255:
            raw -= 2**256
        px = raw / 1e8
        px_source = "feed:latestAnswer(staleness-unchecked)"
    if not (10.0 < px < 1_000_000.0):
        raise SystemExit(f"ETH px sanity failed: {px} ({px_source})")

    gov = "0x" + fp.call(url, args.vault, "0x6dc0ae22")[-40:]     # GOVERNOR()
    token0 = "0x" + fp.call(url, args.vault, "0x443ec74d")[-40:]  # TOKEN0()
    token1 = "0x" + fp.call(url, args.vault, "0x5ee04d78")[-40:]  # TOKEN1()
    dec0 = int(fp.call(url, token0, "0x313ce567"), 16)            # decimals()
    dec1 = int(fp.call(url, token1, "0x313ce567"), 16)
    check_flagship(dec0, dec1)

    ident = cache_key(args.chain_id, args.vault, genesis)
    cache = Path(args.cache)
    rows, scan_from = {"transfers": [], "events": [], "nft": []}, genesis
    if cache.exists():
        try:
            c = json.loads(cache.read_text())
            if c.get("ident") == ident:
                rows = c["rows"]
                scan_from = c["scanned_to"] + 1  # incremental top-up, never a stale full reuse
                print(f"cache hit: rows to block {c['scanned_to']}, topping up to {latest}", flush=True)
        except Exception:
            rows, scan_from = {"transfers": [], "events": [], "nft": []}, genesis

    TOPICS2 = dict(fp.TOPICS)
    TOPICS2["harvested"] = "0x86a8f2155e7540dea670f5cf05573f44b20291cc10f493f305c35a1454e7250e"
    TOPICS2["rebalanced"] = "0x6de6d47ae0c39d5a1bcf78d0c7eee86e4b614a12d55da1bcf47e26898bdaee57"
    KIND = {"harvested": "harvested", "close": "closed", "liq": "liquidated", "rebalanced": "rebalanced"}

    if scan_from <= latest:
        vt, gt = fp.topic_address(args.vault), fp.topic_address(gov)
        for tok, name in ((token0, "weth"), (token1, "usdg")):
            for lg in fp.get_logs(url, tok, [fp.TOPIC_TRANSFER, vt, gt], scan_from, latest):
                rows["transfers"].append({"tx": lg["transactionHash"], "token": name,
                                          "amount": int(lg["data"], 16),
                                          "block": int(lg["blockNumber"], 16),
                                          "log_index": int(lg["logIndex"], 16)})
        for k in ("harvested", "close", "liq", "rebalanced", "open", "increase"):
            for lg in fp.get_logs(url, args.vault, [TOPICS2[k]], scan_from, latest):
                ev = {"tx": lg["transactionHash"], "pos_id": int(lg["topics"][1], 16),
                      "kind": KIND[k], "block": int(lg["blockNumber"], 16),
                      "log_index": int(lg["logIndex"], 16)}
                if k == "harvested":
                    data = lg["data"][2:]
                    ev["net0"], ev["net1"] = int(data[0:64], 16), int(data[64:128], 16)
                rows["events"].append(ev)
        for lg in fp.get_logs(url, args.vault, [fp.TOPIC_TRANSFER], scan_from, latest):
            if len(lg["topics"]) == 4:
                rows["nft"].append({"pos_id": int(lg["topics"][3], 16),
                                    "to": "0x" + lg["topics"][2][-40:],
                                    "block": int(lg["blockNumber"], 16),
                                    "log_index": int(lg["logIndex"], 16)})
        cache.write_text(json.dumps({"ident": ident, "scanned_to": latest,
                                     "t": time.time(), "rows": rows}))

    # Per-tx interleave → segments → owner (pre-burn, log-ordered) → governor-self fix.
    by_tx = {}
    for t in rows["transfers"]:
        by_tx.setdefault(t["tx"], {"block": t["block"], "items": []})["items"].append(
            {"kind_row": "transfer", "log_index": t["log_index"], "token": t["token"], "amount": t["amount"]})
    for e in rows["events"]:
        slot = by_tx.setdefault(e["tx"], {"block": e["block"], "items": []})
        item = {"kind_row": "event", "log_index": e["log_index"], "pos_id": e["pos_id"], "kind": e["kind"]}
        if "net0" in e:
            item["net0"], item["net1"] = e["net0"], e["net1"]
        slot["items"].append(item)

    skims, orphans = [], []
    for tx, blob in by_tx.items():
        segs, orph = segment_tx(blob["items"], blob["block"])
        for o in orph:
            o["tx"] = tx
        orphans.extend(orph)
        for s in segs:
            if s["cut0"] == 0 and s["cut1"] == 0:
                continue  # event with no fee transfers (e.g. plain rebalance) — nothing to attribute
            s["owner"] = owner_before(rows["nft"], s["pos_id"], s["block"], s["log_index"])
            s = resolve_governor_self(s, s["owner"], gov, args.harvest_fee_bps)
            s["eth_px"] = px
            skims.append(s)

    pts = attribute_skims(skims)
    total = sum(skim_usd(s["cut0"], s["cut1"], px) for s in skims)
    excluded_liq = sum(skim_usd(s["cut0"], s["cut1"], px) for s in skims if s["kind"] == "liquidated")
    excluded_amb = sum(skim_usd(s["cut0"], s["cut1"], px) for s in skims if s.get("ambiguous"))
    orphan_usd = sum(skim_usd(o["cut0"], o["cut1"], px) for o in orphans)

    out = {
        "meta": {
            "version": 2, "unit": "1 point = 1 USD realized protocol revenue (K=1)",
            "generated_at": int(time.time()), "block": latest, "scanned_to": latest,
            "chain_id": args.chain_id, "vault": args.vault, "governor": gov,
            "harvest_fee_bps": args.harvest_fee_bps,
            "px": {"value": px, "source": px_source, "policy":
                   "current-price revaluation of historical WETH cuts; per-skim historical "
                   "pricing is a listed refinement — error = Σ cutWETH×(px_now − px_then)"},
            "recon": {"total_skim_usd": total, "attributed_usd": sum(pts.values()),
                      "liquidation_excluded_usd": excluded_liq,
                      "governor_ambiguous_excluded_usd": excluded_amb,
                      "orphan_usd": orphan_usd, "orphans": orphans},
        },
        "lines": {"leverage_harvest": pts},
    }
    Path(args.out).write_text(json.dumps(out, indent=1))
    print(f"block {latest}  skims {len(skims)}  total ${total:,.2f}  attributed ${sum(pts.values()):,.2f}  "
          f"liq-excl ${excluded_liq:,.2f}  gov-ambig ${excluded_amb:,.2f}  orphans {len(orphans)} (${orphan_usd:,.2f})")


def clm_main(argv):
    """Auto LP (CLM) line — Sepolia rehearsal first; mainnet address swap at deploy.

    Revenue = token Transfers strategy → factory.treasury() inside strategy Harvest txs
    (the caller slice goes to tx.origin separately and earns no points). Split pro-rata
    by vault share balances at the harvest block (share_balances_at).
    """
    import argparse, json, time
    from pathlib import Path
    from points import farm_points as fp

    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc", default="https://ethereum-sepolia-rpc.publicnode.com")
    ap.add_argument("--chain-id", type=int, default=11155111)
    ap.add_argument("--vault", default="0x7C0cCcCB2C41e3DE01b4cB0Ba7d0EbdA11bb3701")
    ap.add_argument("--strategy", default="0x8352d9Df9006c21Cfc4dCaeBA8ec91Dae4Af8F4F")
    ap.add_argument("--genesis", type=int, default=11_650_000)  # Sepolia deployBlock floor
    ap.add_argument("--out", default=str(Path(__file__).parent / "points_v2_clm.json"))
    args = ap.parse_args(argv)
    url = args.rpc

    latest = int(fp.rpc(url, "eth_blockNumber", []), 16)
    factory = "0x" + fp.call(url, args.strategy, "0xc45a0155")[-40:]   # factory()
    treasury = "0x" + fp.call(url, factory, "0x61d027b3")[-40:]        # treasury()
    t0 = "0x" + fp.call(url, args.strategy, "0x5ee167c0")[-40:]        # lpToken0()
    t1 = "0x" + fp.call(url, args.strategy, "0x877562b6")[-40:]        # lpToken1()
    dec0 = int(fp.call(url, t0, "0x313ce567"), 16)
    dec1 = int(fp.call(url, t1, "0x313ce567"), 16)
    check_flagship(dec0, dec1)
    # price: strategy.price() raw → human via decimals correction (guide formula)
    px = int(fp.call(url, args.strategy, "0xa035b1fe"), 16) / 1e36 * 10 ** (dec0 - dec1)

    HARVEST = "0x6c8433a8e155f0af04dba058d4e4695f7da554578963d876bdf4a6d8d6399d9c"
    harvest_blocks = {}
    for lg in fp.get_logs(url, args.strategy, [HARVEST], args.genesis, latest):
        harvest_blocks[lg["transactionHash"]] = int(lg["blockNumber"], 16)

    st, tt = fp.topic_address(args.strategy), fp.topic_address(treasury)
    fee_by_tx = {}
    for tok, name in ((t0, "weth"), (t1, "usdg")):
        for lg in fp.get_logs(url, tok, [fp.TOPIC_TRANSFER, st, tt], args.genesis, latest):
            tx = lg["transactionHash"]
            f = fee_by_tx.setdefault(tx, {"cut0": 0, "cut1": 0})
            f["cut0" if name == "weth" else "cut1"] += int(lg["data"], 16)

    share_xfers = []
    for lg in fp.get_logs(url, args.vault, [fp.TOPIC_TRANSFER], args.genesis, latest):
        if len(lg["topics"]) == 3:
            share_xfers.append({"from": "0x" + lg["topics"][1][-40:], "to": "0x" + lg["topics"][2][-40:],
                                "amount": int(lg["data"], 16), "block": int(lg["blockNumber"], 16),
                                "log_index": int(lg["logIndex"], 16)})

    harvests, stray = [], []
    for tx, f in fee_by_tx.items():
        usd = skim_usd(f["cut0"], f["cut1"], px)
        if tx in harvest_blocks:
            harvests.append({"tx": tx, "block": harvest_blocks[tx], "treasury_usd": usd})
            continue
        # Receipt rescue: log scans on public RPCs can silently drop events (replica
        # inconsistency, seen live on Sepolia 2026-09-11) — the per-tx receipt is the
        # reliable path. A treasury transfer whose receipt carries the Harvest event IS
        # a harvest; only receipt-confirmed non-harvests stay stray.
        rcpt, rescue_err = None, None
        for attempt in range(3):  # independent retries — never classify on a swallowed failure
            try:
                rcpt = _receipt(url, tx)
                break
            except Exception as exc:
                rescue_err = str(exc)[:120]
                time.sleep(2 * (attempt + 1))
        if rcpt is not None and any(l["address"].lower() == args.strategy.lower()
                                    and l["topics"][0].lower() == HARVEST for l in rcpt["logs"]):
            harvests.append({"tx": tx, "block": int(rcpt["blockNumber"], 16),
                             "treasury_usd": usd, "rescued": True})
        elif rcpt is not None:
            stray.append({"tx": tx, "usd": usd, "receipt_checked": True})
        else:
            stray.append({"tx": tx, "usd": usd, "receipt_checked": False, "rescue_error": rescue_err})

    pts = clm_harvest_points(harvests, lambda blk: share_balances_at(share_xfers, blk))
    total = sum(h["treasury_usd"] for h in harvests)
    out = {"meta": {"version": 2, "line": "auto_lp_clm", "chain_id": args.chain_id,
                    "vault": args.vault, "strategy": args.strategy, "treasury": treasury,
                    "generated_at": int(time.time()), "block": latest,
                    "px": {"value": px, "source": "strategy.price() decimals-corrected"},
                    "recon": {"treasury_usd_total": total, "attributed_usd": sum(pts.values()),
                              "harvests": harvests, "stray_treasury_transfers": stray}},
           "lines": {"auto_lp_clm": pts}}
    Path(args.out).write_text(json.dumps(out, indent=1))
    print(f"block {latest}  harvests {len(harvests)}  treasury ${total:,.6f}  "
          f"attributed ${sum(pts.values()):,.6f}  stray {len(stray)}")
    for h in harvests:
        print("  harvest", h["tx"][:18], f"${h['treasury_usd']:,.6f}")


def lending_main(argv):
    """Lending line — solUSDG (Morpho Vault v2) performance fee attribution.

    Revenue realization = fee SHARES minted to performanceFeeRecipient at each accrual
    (Transfer ZERO → recipient on the vault share token). USD value = shares × current
    share price (convertToAssets — same current-price policy as the other lines, with
    the same meta disclosure). Split pro-rata across depositor share balances at the
    mint block, excluding the feeRecipient's own accumulated fee shares.
    """
    import argparse, json, time
    from pathlib import Path
    from points import farm_points as fp

    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc", default=fp.RPC_URLS[0])
    ap.add_argument("--chain-id", type=int, default=4663)
    ap.add_argument("--vault", default="0xCBB61788fB5A1969C93A222B1a12E4D1A50c6d99")  # solUSDG
    ap.add_argument("--genesis", type=int, default=53_100_000)  # live since 2026-09-03
    ap.add_argument("--out", default=str(Path(__file__).parent / "points_v2_lending.json"))
    args = ap.parse_args(argv)
    url = args.rpc

    latest = int(fp.rpc(url, "eth_blockNumber", []), 16)
    fee_rcpt = "0x" + fp.call(url, args.vault, "0xed27f7c9")[-40:]  # performanceFeeRecipient()
    # share px in USD: convertToAssets(1e6) / 1e6 (USDG 6dp ≈ USD)
    share_px = int(fp.call(url, args.vault, "0x07a2d13a" + hex(10**6)[2:].zfill(64)), 16) / 1e6

    xfers, fee_mints = [], []
    for lg in fp.get_logs(url, args.vault, [fp.TOPIC_TRANSFER], args.genesis, latest):
        if len(lg["topics"]) != 3:
            continue
        row = {"from": "0x" + lg["topics"][1][-40:], "to": "0x" + lg["topics"][2][-40:],
               "amount": int(lg["data"], 16), "block": int(lg["blockNumber"], 16),
               "log_index": int(lg["logIndex"], 16)}
        xfers.append(row)
        if row["from"] == ZERO and row["to"].lower() == fee_rcpt.lower():
            fee_mints.append({"block": row["block"],
                              "treasury_usd": row["amount"] / 1e6 * share_px,
                              "shares": row["amount"]})

    pts = clm_harvest_points(fee_mints, lambda blk: share_balances_at(xfers, blk),
                             exclude=(fee_rcpt,))
    total = sum(m["treasury_usd"] for m in fee_mints)
    out = {"meta": {"version": 2, "line": "lending_solusdg", "chain_id": args.chain_id,
                    "vault": args.vault, "fee_recipient": fee_rcpt,
                    "generated_at": int(time.time()), "block": latest,
                    "px": {"share_px": share_px, "policy":
                           "current share price revalues historical fee mints; per-mint "
                           "historical pricing is a listed refinement"},
                    "recon": {"fee_mints": len(fee_mints), "revenue_usd_total": total,
                              "attributed_usd": sum(pts.values())}},
           "lines": {"lending_solusdg": pts}}
    Path(args.out).write_text(json.dumps(out, indent=1))
    print(f"block {latest}  fee-mints {len(fee_mints)}  revenue ${total:,.6f}  "
          f"attributed ${sum(pts.values()):,.6f}")


def publish_main(argv):
    """Assemble the published v2 board: real attributed lines where a line has switched,
    cold-start proxy accrual elsewhere (DESIGN §3/§3.5).

    Launch reality (2026-09-11): attributable external revenue is $0 on every line, so
    all lines start in proxy mode; the structure (not the magnitudes) is what ships.
    Proxy rates are disclosed estimates in meta and get re-derived when any line nears
    the switch threshold.
    """
    import argparse, json, time
    from pathlib import Path
    from points import farm_points as fp

    HERE = Path(__file__).parent
    APP_PUB = HERE.parent / "refs/morpho-lite-apps/apps/lite/public"

    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc", default=fp.RPC_URLS[0])
    ap.add_argument("--k", type=float, default=1.0)
    ap.add_argument("--threshold-usd", type=float, default=100.0)
    ap.add_argument("--out", default=str(HERE / "points-v2-board.json"))
    ap.add_argument("--app-out", default=str(APP_PUB / "data/points-v2.json"))
    args = ap.parse_args(argv)

    activation_block = int(fp.rpc(args.rpc, "eth_blockNumber", []), 16)

    v1_lending = json.loads((APP_PUB / "points.json").read_text())
    v1_farm = json.loads((HERE / "farm_points.json").read_text())

    def load(name):
        try:
            return json.loads((HERE / name).read_text())
        except Exception:
            return None

    v2_lev = load("points_v2.json")
    v2_lend = load("points_v2_lending.json")

    # Line modes: real only when trailing attributable (post-exclusion) revenue ≥ T.
    attributed = {
        "leverage_harvest": (v2_lev or {}).get("meta", {}).get("recon", {}).get("attributed_usd", 0.0),
        "lending_solusdg": (v2_lend or {}).get("meta", {}).get("recon", {}).get("attributed_usd", 0.0),
        "auto_lp_clm": 0.0,  # mainnet not deployed
    }
    modes = {k: ("real" if not use_proxy(v, args.threshold_usd) else "proxy")
             for k, v in attributed.items()}

    # Disclosed proxy rate estimates (annual, on the v1 usd-day bases named below).
    RATES = {
        "leverage_harvest": 0.054,   # flagship pool gross fee APR ~54% × 10% protocol cut, on debt-principal days (≈LP value proxy)
        "reserve_interest": 0.0075,  # ~5%/yr borrow rate × 15% reserveFeeRate, on debt-principal days
        "lending_solusdg": 0.0012,   # ~0.77% supply APY × 15% performance fee, on supply days
    }

    # Governor/team addresses never earn points — real mode excludes them as ambiguous,
    # proxy mode must be consistent (no self-dealing accrual on the team's own activity).
    governor = ((v2_lev or {}).get("meta", {}).get("governor") or "").lower()
    lines = {}
    farm_borrow = {r["address"]: r.get("borrow_points", 0.0) for r in v1_farm.get("leaderboard", [])
                   if r["address"].lower() != governor}
    lend_supply = {r["address"]: r.get("supply_points", 0.0) for r in v1_lending.get("leaderboard", [])
                   if r["address"].lower() != governor}
    if modes["leverage_harvest"] == "proxy":
        lines["leverage_harvest"] = {a: proxy_points(d, RATES["leverage_harvest"])
                                     for a, d in farm_borrow.items() if d > 0}
        lines["reserve_interest"] = {a: proxy_points(d, RATES["reserve_interest"])
                                     for a, d in farm_borrow.items() if d > 0}
    else:
        lines["leverage_harvest"] = (v2_lev or {}).get("lines", {}).get("leverage_harvest", {})
    if modes["lending_solusdg"] == "proxy":
        lines["lending_solusdg"] = {a: proxy_points(d, RATES["lending_solusdg"])
                                    for a, d in lend_supply.items() if d > 0}
    else:
        lines["lending_solusdg"] = (v2_lend or {}).get("lines", {}).get("lending_solusdg", {})
    # auto_lp_clm: mainnet undeployed → no basis, no proxy (nothing to hold shares of).

    board = merge_lines(lines, k=args.k)

    out = {
        "meta": {
            "version": 2, "unit": "1 point = 1 USD realized protocol revenue (K applied)",
            "k": args.k, "activation_block": activation_block,
            "generated_at": int(time.time()),
            "v1_freeze_block": activation_block,
            "modes": modes, "proxy_rates_annual": RATES,
            "proxy_bases": {"leverage_harvest": "farm borrow principal-days (v1)",
                            "reserve_interest": "farm borrow principal-days (v1)",
                            "lending_solusdg": "lending supply principal-days (v1)"},
            "attributable_revenue_usd": attributed,
            "threshold_usd": args.threshold_usd,
            "notes": ["all lines start in proxy mode: attributable external revenue is $0 at activation",
                      "governor-owned/ambiguous and liquidation flows never earn points",
                      "v1 boards frozen at v1_freeze_block; published board shows v1+v2 combined in the app"],
        },
        "byAddress": board,
    }
    Path(args.out).write_text(json.dumps(out, indent=1))
    Path(args.app_out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.app_out).write_text(json.dumps(out, indent=1))
    print(f"activation_block {activation_block}  addresses {len(board)}  "
          f"total v2 pts {sum(v['points'] for v in board.values()):.6f}")
    for a, v in sorted(board.items(), key=lambda x: -x[1]["points"])[:5]:
        print(" ", a[:14], round(v["points"], 6), v["breakdown"])


def basis_main(argv):
    """Leverage-line lifetime basis (SPEC §4 v1.10 gap ②): per-owner invested vs returned.

    Replays PositionOpened / PositionIncreased / MarginAdded / PositionClosed and prices
    the WETH leg of every event with the Chainlink ETH/USD feed's HISTORICAL ROUNDS
    matched by event timestamp — RH has no free archive node, but feed rounds are plain
    current-state reads. Round granularity (heartbeat/deviation) is the disclosed price
    error. Owner = the opening event's owner; NFT-transferred positions keep the opener
    (known limitation, noted in meta).
    Completeness check: every NFT mint in the shared scan cache must have an open event.
    """
    import argparse, json, time
    from pathlib import Path
    from points import farm_points as fp

    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc", default=fp.RPC_URLS[0])
    ap.add_argument("--vault", default="0x9Db7aDa64D1E8b856E15D916d886797501F28ce0")
    ap.add_argument("--feed", default="0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9")  # ETH/USD
    ap.add_argument("--genesis", type=int, default=53_955_000)
    ap.add_argument("--out", default=str(Path(__file__).parent / "farm-basis-4663.json"))
    args = ap.parse_args(argv)
    url = args.rpc

    latest = int(fp.rpc(url, "eth_blockNumber", []), 16)
    T = dict(fp.TOPICS)  # open / increase / close; repay2 == MarginAdded
    KINDS = {"open": T["open"], "increase": T["increase"], "margin": T["repay2"], "close": T["close"]}

    events = []
    for kind, topic in KINDS.items():
        for lg in fp.get_logs(url, args.vault, [topic], args.genesis, latest):
            w = [int(lg["data"][2 + i * 64 : 2 + (i + 1) * 64], 16) for i in range((len(lg["data"]) - 2) // 64)]
            events.append({"kind": kind, "pos_id": int(lg["topics"][1], 16),
                           "owner": ("0x" + lg["topics"][2][-40:]) if len(lg["topics"]) > 2 else None,
                           "block": int(lg["blockNumber"], 16), "w": w})

    # block → timestamp (few events; one call per unique block)
    ts_cache = {}
    for e in events:
        b = e["block"]
        if b not in ts_cache:
            ts_cache[b] = int(fp.rpc(url, "eth_getBlockByNumber", [hex(b), False])["timestamp"], 16)
        e["ts"] = ts_cache[b]

    # Chainlink round history: walk back from latestRound until we cover the earliest event.
    def round_data(rid):
        data = "0x9a6fc8f5" + hex(rid)[2:].zfill(64)  # getRoundData(uint80)
        raw = fp.call(url, args.feed, data)
        ans = int(raw[2 + 64 : 2 + 128], 16)
        upd = int(raw[2 + 192 : 2 + 256], 16)
        return ans / 1e8, upd

    lrd = fp.call(url, args.feed, "0xfeaf968c")  # latestRoundData()
    rid = int(lrd[2 : 2 + 64], 16)
    rounds = []
    earliest = min((e["ts"] for e in events), default=int(time.time()))
    guard = 0
    while rid > 0 and guard < 5000:
        try:
            px, upd = round_data(rid)
        except Exception:
            break
        if upd > 0:
            rounds.append((upd, px))
            if upd < earliest:
                break
        rid -= 1
        guard += 1
    rounds.sort()

    def px_at(ts):
        best = rounds[0][1] if rounds else 0.0
        for upd, px in rounds:
            if upd <= ts:
                best = px
            else:
                break
        return best

    # Completeness: every minted position id must have an open event (shared cache truth).
    cache = Path("/tmp/points-v2-scan-cache.json")
    missing = []
    if cache.exists():
        try:
            nft = json.loads(cache.read_text())["rows"]["nft"]
            minted = {r["pos_id"] for r in nft if r["to"] != ZERO}
            opened = {e["pos_id"] for e in events if e["kind"] == "open"}
            missing = sorted(minted - opened)
            if missing:
                print(f"WARN: {len(missing)} minted position(s) missing an open event: {missing}")
        except Exception:
            pass

    owner_of = {e["pos_id"]: e["owner"] for e in events if e["kind"] == "open" and e["owner"]}
    by_owner = {}
    for e in sorted(events, key=lambda x: x["block"]):
        owner = owner_of.get(e["pos_id"])
        if not owner:
            continue
        px = px_at(e["ts"])
        slot = by_owner.setdefault(owner, {"lifetimeInUsd": 0.0, "lifetimeOutUsd": 0.0})
        w = e["w"]
        if e["kind"] == "open":
            # investRisk, investLoan are the user's own capital (borrow legs are debt, not basis)
            slot["lifetimeInUsd"] += w[0] / 1e18 * px + w[1] / 1e6
        elif e["kind"] == "increase":
            slot["lifetimeInUsd"] += w[0] / 1e18 * px + w[1] / 1e6
        elif e["kind"] == "margin":
            slot["lifetimeInUsd"] += w[0] / 1e18 * px + w[1] / 1e6
        elif e["kind"] == "close":
            # PositionClosed(id, percentBps, repaidRisk, repaidLoan, outRisk, outLoan, full)
            slot["lifetimeOutUsd"] += w[3] / 1e18 * px + w[4] / 1e6

    out = {"meta": {"vault": args.vault.lower(), "chain_id": 4663, "generated_at": int(time.time()),
                    "block": latest, "px_source": "chainlink ETH/USD rounds matched by event timestamp",
                    "rounds_covered": len(rounds), "events": len(events),
                    "missing_open_for_minted": missing,
                    "notes": ["owner = opening event; NFT-transferred positions keep the opener",
                              "basis counts own capital only (invest/margin), never borrowed legs"]},
           "byOwner": by_owner}
    Path(args.out).write_text(json.dumps(out, indent=1))
    print(f"block {latest}  events {len(events)}  owners {len(by_owner)}  rounds {len(rounds)}")
    for a, v in by_owner.items():
        print(f"  {a[:12]} in ${v['lifetimeInUsd']:,.2f} out ${v['lifetimeOutUsd']:,.2f}")


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "clm":
        clm_main(sys.argv[2:])
    elif len(sys.argv) > 1 and sys.argv[1] == "lending":
        lending_main(sys.argv[2:])
    elif len(sys.argv) > 1 and sys.argv[1] == "publish":
        publish_main(sys.argv[2:])
    elif len(sys.argv) > 1 and sys.argv[1] == "basis":
        basis_main(sys.argv[2:])
    else:
        main()
