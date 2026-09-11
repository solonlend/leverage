#!/usr/bin/env python3
"""Solon farm + dual-reserve lending points — same model as the Morpho side, two new sources.

Model (identical to indexer.py: shares x seconds, so wash loops earn nothing):
  supply side  = eToken balance x seconds, per reserve, replayed from ERC20 Transfer
                 (mint from 0x0 / burn to 0x0 included).
  borrow side  = principal debt (in USDG value) x seconds, replayed from the lending
                 pool's actual Borrow / Repay amounts. Vault events map each operation to
                 its position and debt IDs. Accrued interest is deliberately NOT counted —
                 principal-days only, so a position cannot farm points by letting debt grow.

Normalisation: 1 point = 1 USDG-day. WETH amounts are converted with the vault oracle's
riskValueInLoan() read at snapshot time — documented as a snapshot conversion, not a
time-weighted price.

Scope: Robinhood Chain mainnet farm and dual-reserve points (farm_points.json).
Incomplete sources are discarded and disclosed in gaps; other sources still publish.

Usage: python3 farm_points.py [--rpc URL] [--vault 0x..] [--lending 0x..]
"""

import argparse
import json
import time
import urllib.error
import urllib.request
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent

DEFAULTS = {
    # Robinhood Chain mainnet (live 2026-09-07). Flagship dual-borrow vault + shared dual-reserve
    # lending pool. The single-borrow vault (0x9e100d524DFEa1Aa76286A7F00682e72F79aC3aE, vaultId 2)
    # shares this lending pool; its position points are NOT yet indexed here (soft-launch credit is
    # 60 USDG, so external points are ~0) — pass --vault to run it for the single vault too.
    "rpc": "https://rpc.mainnet.chain.robinhood.com/rpc",
    "vault": "0x9Db7aDa64D1E8b856E15D916d886797501F28ce0",
    "lending": "0xA4af5515A7DE8E1661C92d3246296Ff3a48791Dd",
    "oracle": "0x52b5728D1086b0B68d98DD51ee6544d87062Ef0f",
}

# reserveId -> (label, underlying decimals, leg)   1 = USDG (LOAN), 2 = WETH (RISK)
RESERVES = {1: ("USDG", 6, "loan"), 2: ("WETH", 18, "risk")}

TOPIC_TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

# keccak-256 of the vault event signatures (verify with:
#   python3 -c "from eth_hash.auto import keccak; print(keccak(b'<sig>').hex())")
TOPICS = {
    "open": "0x9488b49ac6c65855fff857bbcf71f26fa599c2e9c9630d8d1f56a1210dda4ed2",
    "increase": "0x9a7050ad8bed5bfdec0ec2f798418c7ccb67e152e4aa511c756b63b7e3089756",
    "repay2": "0x08db8f13ec448cbe6baa1b453d93cfb27a9f006abf51006472c4b89f991b8629",
    "close": "0x1c141139954e5b71abc87d6cb1e12e9715e5716972669be5f21a2d2a604f284b",
    "liq": "0x4441e550cb242fb3921af8f2e9e4a8d4b915581954036294d04faf2b9adbcab2",
    "borrow": "0xf9a33434428db5f0416c03e38307599ad0b9b9965d6c070eb08e87cc1f0ca50e",
    "repay": "0xb42c5f4d7454a3dbf5af30732b0d66efa11d73c66cef1f5732fa84b7e63cf99a",
}
VAULT_EVENT_KINDS = ("open", "increase", "repay2", "close", "liq")
SEL_RISK_VALUE = "2b9c3d9d"  # riskValueInLoan(uint256)
SEL_ETOKEN = "54018896"  # getETokenAddress(uint256)
DAY = 86400
POINT_SCALE = DAY  # 1 point = 1 USDG-day (values are already USDG units, float)

HDR = {"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"}  # RH public RPC 403s non-browser UAs


RPC_URLS = (
    "https://rpc.mainnet.chain.robinhood.com/rpc",
    "https://robinhood-rpc.publicnode.com",
    "https://rpc.mainnet.chain.robinhood.com",
)
RPC_PACE = 1.0
RPC_BUDGET = 180.0
_rpc_last_call = None
_rpc_endpoint = {}


def rpc(url, method, params):
    """Serialized caller: browser UA, pacing and up to 180s per read including retries.

    Only known RH endpoints rotate; an explicit custom RPC never switches chains.
    JSON-RPC range errors are left to the chunk scanner, not retried as throttles.
    """
    global _rpc_last_call
    endpoints = list(RPC_URLS) if url in RPC_URLS else [url]
    index = _rpc_endpoint.get(url, endpoints.index(url))
    deadline = time.monotonic() + RPC_BUDGET
    for attempt in range(8):
        wait = 0 if _rpc_last_call is None else max(0, _rpc_last_call + RPC_PACE - time.monotonic())
        if time.monotonic() + wait >= deadline:
            raise RuntimeError(f"{method}: RPC retry budget exhausted")
        time.sleep(wait)
        _rpc_last_call = time.monotonic()
        endpoint = endpoints[index]
        retry_after = 0.0
        try:
            req = urllib.request.Request(
                endpoint, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(), HDR
            )
            with urllib.request.urlopen(req, timeout=min(20, deadline - time.monotonic())) as response:
                out = json.load(response)
            if "error" in out:
                error = out["error"]
                if any(term in str(error).lower() for term in ("rate limit", "too many requests", "throttl")):
                    raise urllib.error.URLError("RPC rate limited")
                raise RuntimeError(error)
            _rpc_endpoint[url] = index
            return out["result"]
        except urllib.error.HTTPError as exc:
            if exc.code not in (403, 429, 502, 503, 504):
                raise
            try:
                retry_after = float(exc.headers.get("Retry-After", 0))
            except (TypeError, ValueError):
                pass
            exc.close()
            error = f"HTTP {exc.code}"
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            error = type(exc).__name__
        if attempt == 7:
            raise RuntimeError(f"{method}: {error}; retries exhausted")
        # Give a node two attempts, then move through all three public endpoints.
        if attempt >= 1:
            index = (index + 1) % len(endpoints)
        delay = max(min(3 * 2**attempt, 60), retry_after)
        if time.monotonic() + delay >= deadline:
            raise RuntimeError(f"{method}: {error}; RPC retry budget exhausted")
        print(f"{method}: {error}; retry {attempt + 1} in {delay:g}s", flush=True)
        time.sleep(delay)
    raise RuntimeError(f"{method}: RPC retries exhausted")


def call(url, to, data):
    return rpc(url, "eth_call", [{"to": to, "data": data}, "latest"])


LOG_CHUNK = 10_000
_log_chunks = {}
_log_history = {}
# First transaction in DeployRhDual.s.sol/4663/run-latest.json. All configured
# mainnet vault/pool/eTokens were created at or after this block (2026-09-07).
MAINNET_DEPLOY_FLOOR = 56_546_362


def log_chunks(url, address, topics, start, latest, backward=False):
    """Yield contiguous, non-overlapping chunks; never regrow a rejected range."""
    chunk = _log_chunks.get(url, LOG_CHUNK)
    while start <= latest:
        lo, hi = (max(start, latest - chunk + 1), latest) if backward else (start, min(start + chunk - 1, latest))
        try:
            part = rpc(url, "eth_getLogs", [{"address": address, "topics": topics,
                                             "fromBlock": hex(lo), "toBlock": hex(hi)}])
        except RuntimeError as exc:
            # Only explicit range/result-size errors warrant subdivision. Exhausted
            # throttles must escape to source isolation, not restart a retry storm.
            message = str(exc).lower()
            if chunk == 1 or not any(term in message for term in
                    ("block range", "range limit", "too many results", "response size", "query exceeds", "limited to")):
                raise
            chunk = max(1, chunk // 2)
            _log_chunks[url] = chunk
            continue
        yield part
        if backward:
            latest = lo - 1
        else:
            start = hi + 1


def get_logs(url, address, topics, start, latest):
    cached = _log_history.get((url, address.lower(), latest))
    if cached is not None and start >= cached[0]:
        def matches(lg):
            return start <= int(lg["blockNumber"], 16) <= latest and all(
                wanted is None or (i < len(lg["topics"]) and lg["topics"][i].lower() in
                    [value.lower() for value in (wanted if isinstance(wanted, list) else [wanted])])
                for i, wanted in enumerate(topics))
        return [lg for lg in cached[1] if matches(lg)]
    return [log for part in log_chunks(url, address, topics, start, latest) for log in part]


def deploy_block(url, address, latest, lookback, floor=None):
    """Find earliest log by scanning ALL bounded chunks down to a declared floor.

    Sparse activity/empty chunks do not prove deployment. Never stop at an empty
    chunk or query archive state. Without a known deployment floor the result is
    explicitly bounded, never advertised as an exact lifetime history.
    """
    floor = max(0, latest - lookback) if floor is None else floor
    first, history = None, []
    for part in log_chunks(url, address, [], floor, latest, backward=True):
        history.extend(part)
        for lg in part:
            block = int(lg["blockNumber"], 16)
            first = block if first is None else min(first, block)
    # Cache only after every chunk succeeded; replay never uses partial history.
    _log_history[(url, address.lower(), latest)] = (floor, history)
    if first is None:
        return floor, f"bounded:no-logs:floor={floor}"
    return first, f"bounded:firstlog:floor={floor}"


def shards_from_balance_events(events, now):
    """events: (block, logIndex, holder, delta, ts). Returns holder -> units x seconds."""
    bal, last, shards = defaultdict(float), {}, defaultdict(float)
    for _, _, holder, delta, ts in sorted(events, key=lambda e: (e[0], e[1])):
        if holder in last:
            shards[holder] += bal[holder] * (ts - last[holder])
        bal[holder] = max(0.0, bal[holder] + delta)
        last[holder] = ts
    for holder, b in bal.items():
        if b > 0:
            shards[holder] += b * (now - last[holder])
    return shards


def words(lg):
    data = lg["data"][2:]
    return [int(data[i:i + 64], 16) for i in range(0, len(data), 64)]


def topic_address(address):
    return "0x" + address.lower().removeprefix("0x").rjust(64, "0")


def delta_value(risk, loan, px):
    """Convert the two principal legs to the snapshot USDG value."""
    return risk / 1e18 * px + loan / 1e6


def pool_principal_events(raw, pool_logs, eth_px, ts_of, tolerate_missing_mappings=False):
    """Map lending-pool actuals to positions and debt IDs.

    The pool ABI does not put debtId in Borrow/Repay. Both indexed addresses are the
    calling vault, so the pool log is paired with the next terminal vault event in the
    same transaction. PositionOpened supplies debtRisk/debtLoan; reserveId then selects
    the exact debt ID and its decimal conversion.
    """
    owner_of = {}
    debt_by_pos = {}
    boundaries = defaultdict(list)

    for kind in VAULT_EVENT_KINDS:
        for lg in raw[kind]:
            pid = int(lg["topics"][1], 16)
            boundaries[lg["transactionHash"]].append((int(lg["logIndex"], 16), pid))
            if kind == "open":
                w = words(lg)
                owner_of[pid] = "0x" + lg["topics"][2][26:]
                debt_by_pos[pid] = {2: w[4], 1: w[5]}

    for tx_boundaries in boundaries.values():
        tx_boundaries.sort()

    ev_by_pos = defaultdict(list)
    skipped_positions = set()
    skipped_pool_logs = 0
    for kind, sign in (("borrow", 1), ("repay", -1)):
        for lg in pool_logs[kind]:
            log_index = int(lg["logIndex"], 16)
            candidates = [item for item in boundaries.get(lg["transactionHash"], ()) if item[0] > log_index]
            if not candidates:
                raise RuntimeError(f"unmatched lending {kind} log in tx {lg['transactionHash']}")
            _, pid = candidates[0]
            reserve_id = int(lg["topics"][1], 16)
            if pid not in debt_by_pos or reserve_id not in debt_by_pos[pid]:
                if tolerate_missing_mappings:
                    skipped_positions.add(pid)
                    skipped_pool_logs += 1
                    continue
                raise RuntimeError(f"missing debt mapping for position {pid}, reserve {reserve_id}")
            debt_id = debt_by_pos[pid][reserve_id]
            amount = int(lg["data"], 16)
            value = delta_value(amount, 0, eth_px) if reserve_id == 2 else delta_value(0, amount, eth_px)
            ev_by_pos[pid].append((
                int(lg["blockNumber"], 16), log_index, debt_id, sign * value,
                ts_of(lg["blockNumber"]),
            ))

    skipped = {
        "pool_logs": skipped_pool_logs,
        "position_count": len(skipped_positions),
        "positions": sorted(skipped_positions),
    }
    return owner_of, ev_by_pos, skipped


def clamped_owner_events(owner_of, ev_by_pos):
    """Apply debt-local clamps and emit only effective deltas to holder balances."""
    owner_events = []
    for pid, evs in ev_by_pos.items():
        holder = owner_of.get(pid, "0x" + "0" * 40)
        running_by_debt = defaultdict(float)
        for b, i, debt_id, delta, ts in sorted(evs, key=lambda event: (event[0], event[1])):
            if debt_id is None:  # ownership handover: move all live principal across
                _, _frm, to = delta
                running = sum(running_by_debt.values())
                if running > 0:
                    owner_events.append((b, i, holder, -running, ts))
                    owner_events.append((b, i, to, +running, ts))
                holder = to
                continue
            old = running_by_debt[debt_id]
            new = max(0.0, old + delta)
            effective_delta = new - old
            if effective_delta:
                owner_events.append((b, i, holder, effective_delta, ts))
            running_by_debt[debt_id] = new
    return owner_events


def main():
    ap = argparse.ArgumentParser()
    for k, v in DEFAULTS.items():
        ap.add_argument(f"--{k}", default=v)
    ap.add_argument("--out", default=str(HERE / "farm_points.json"))
    ap.add_argument("--lookback", type=int, default=1_500_000,
                    help="maximum backward discovery blocks for deployments without a known floor")
    args = ap.parse_args()
    if args.lookback < 1:
        ap.error("--lookback must be positive")
    url = args.rpc
    chain_id = int(rpc(url, "eth_chainId", []), 16)
    mainnet_sources = all(getattr(args, key).lower() == DEFAULTS[key].lower() for key in ("vault", "lending"))
    if mainnet_sources and chain_id != 4663:
        raise RuntimeError("mainnet source addresses require chainId 4663")
    latest = int(rpc(url, "eth_blockNumber", []), 16)
    floor = MAINNET_DEPLOY_FLOOR if mainnet_sources else max(0, latest - args.lookback)
    if floor > latest:
        raise RuntimeError("snapshot precedes deployment floor")
    gaps = []
    def gap(source, address, error, start=floor):
        gaps.append({"source": source, "address": address, "from_block": start,
                     "to_block": latest, "reason": str(error), "action": "source omitted"})
        print(f"SKIP {source}: {error}", flush=True)
    if not mainnet_sources and floor > 0:
        gaps.append({"source": "history", "from_block": 0, "to_block": floor - 1,
                     "reason": "outside bounded discovery window; earlier activity not verified",
                     "action": "bounded history only"})

    ts_cache = {}
    def ts_of(block_hex):
        if block_hex not in ts_cache:
            ts_cache[block_hex] = int(rpc(url, "eth_getBlockByNumber", [block_hex, False])["timestamp"], 16)
        return ts_cache[block_hex]
    # Replaying the same snapshot must accrue to the same chain timestamp.
    now = ts_of(hex(latest))
    eth_px = None
    try:
        px_raw = call(url, args.oracle, "0x" + SEL_RISK_VALUE + hex(10**18)[2:].rjust(64, "0"))
        eth_px = int(px_raw, 16) / 1e6
        print(f"oracle ETH = {eth_px:.2f} USDG", flush=True)
    except Exception as exc:
        gap("oracle", args.oracle, exc)

    supply, per_reserve = defaultdict(float), {}
    for rid, (label, dec, leg) in RESERVES.items():
        etoken = None
        per_reserve[label] = {"status": "skipped"}
        try:
            etoken = "0x" + call(url, args.lending, "0x" + SEL_ETOKEN + hex(rid)[2:].rjust(64, "0"))[-40:]
            per_reserve[label]["etoken"] = etoken
            if leg == "risk" and eth_px is None:
                raise RuntimeError("oracle unavailable")
            e_genesis, e_how = deploy_block(url, etoken, latest, args.lookback, floor=floor)
            logs = get_logs(url, etoken, [TOPIC_TRANSFER], e_genesis, latest)
            events = []
            for lg in logs:
                frm, to = ("0x" + lg["topics"][i][26:] for i in (1, 2))
                amt = int(lg["data"], 16) / 10**dec * (eth_px if leg == "risk" else 1.0)
                b, i, bh = int(lg["blockNumber"], 16), int(lg["logIndex"], 16), lg["blockNumber"]
                if int(frm, 16) != 0:
                    events.append((b, i, frm, -amt, ts_of(bh)))
                if int(to, 16) != 0:
                    events.append((b, i, to, +amt, ts_of(bh)))
            sh = shards_from_balance_events(events, now)
            per_reserve[label].update(status="complete", transfers=len(logs), holders=len(sh),
                                      genesis_block=e_genesis, genesis_resolution=e_how)
            for k, v in sh.items():
                supply[k] += v
            print(f"reserve #{rid} {label}: genesis={e_genesis}, {len(logs)} transfers, {len(sh)} holders", flush=True)
        except Exception as exc:
            gap(f"supply:{label}", etoken or args.lending, exc)

    # Vault mappings, pool Borrow/Repay and NFT handovers are ONE accounting source.
    # Never publish partially replayed borrow balances after a failed repayment scan.
    genesis, genesis_how = None, "unavailable"
    lending_genesis, lending_how = None, "unavailable"
    borrow, per_pos = {}, {}
    skipped = {"pool_logs": 0, "position_count": 0, "positions": []}
    try:
        if eth_px is None:
            raise RuntimeError("oracle unavailable")
        genesis, genesis_how = deploy_block(url, args.vault, latest, args.lookback, floor=floor)
        lending_genesis, lending_how = deploy_block(url, args.lending, latest, args.lookback, floor=floor)
        print(f"latest={latest} vault genesis={genesis} ({genesis_how})", flush=True)
        raw = {kind: get_logs(url, args.vault, [TOPICS[kind]], genesis, latest) for kind in VAULT_EVENT_KINDS}
        vault_topic = topic_address(args.vault)
        pool_logs = {kind: get_logs(url, args.lending, [TOPICS[kind], None, vault_topic, vault_topic],
                                    genesis, latest) for kind in ("borrow", "repay")}
        for kind, logs in {**raw, **pool_logs}.items():
            print(f"{kind}: {len(logs)} logs", flush=True)
        owner_of, ev_by_pos, skipped = pool_principal_events(
            raw, pool_logs, eth_px, ts_of, tolerate_missing_mappings=not mainnet_sources)
        nft = [lg for lg in get_logs(url, args.vault, [TOPIC_TRANSFER], genesis, latest) if len(lg["topics"]) == 4]
        for lg in nft:
            b, i, pid = int(lg["blockNumber"], 16), int(lg["logIndex"], 16), int(lg["topics"][3], 16)
            frm, to = "0x" + lg["topics"][1][26:], "0x" + lg["topics"][2][26:]
            ev_by_pos[pid].append((b, i, None, ("transfer", frm, to), ts_of(lg["blockNumber"])))
        borrow = shards_from_balance_events(clamped_owner_events(owner_of, ev_by_pos), now)
        per_pos = {str(pid): len(evs) for pid, evs in ev_by_pos.items()}
    except Exception as exc:
        gap("borrow", {"vault": args.vault, "lending_pool": args.lending}, exc)

    board = defaultdict(lambda: {"supply_points": 0.0, "borrow_points": 0.0})
    for a, v in supply.items():
        board[a]["supply_points"] += v / POINT_SCALE
    for a, v in borrow.items():
        if int(a, 16) != 0:
            board[a]["borrow_points"] += v / POINT_SCALE
    rows = [{"address": a, "supply_points": round(d["supply_points"], 4),
             "borrow_points": round(d["borrow_points"], 4),
             "total": round(d["supply_points"] + d["borrow_points"], 4)} for a, d in board.items()]
    rows = sorted((r for r in rows if r["total"] > 0), key=lambda r: (-r["total"], r["address"]))
    out = {
        "generated_at": int(time.time()), "snapshot_timestamp": now, "block": latest, "chain_id": chain_id,
        "complete": not gaps and not skipped["pool_logs"], "gaps": gaps,
        "params": {
            "supply_weight": 1.0, "borrow_weight": 1.0, "point_scale": "1 USDG-day",
            "sources": {"farm_vault": args.vault, "lending_pool": args.lending, "oracle": args.oracle,
                        "reserves": per_reserve, "position_events": per_pos},
            "eth_usdg_snapshot": eth_px, "genesis_block": genesis, "genesis_resolution": genesis_how,
            "lending_genesis_block": lending_genesis, "lending_genesis_resolution": lending_how,
            "scan_floor": floor,
            "scan_floor_basis": "RH mainnet deployment batch first receipt" if mainnet_sources else "lookback bound",
            "rpc_endpoints": list(RPC_URLS) if url in RPC_URLS else [url],
            "log_chunk_max": LOG_CHUNK,
            "window_truncation": {"skipped_pool_logs": skipped["pool_logs"],
                                  "skipped_position_count": skipped["position_count"],
                                  "skipped_positions": skipped["positions"]},
            "policy": "eToken balance-days; farm principal USDG-days from lending-pool Borrow/Repay actuals, "
                      "clamped per debt ID. Interest excluded. WETH uses a latest oracle conversion read during "
                      "this run, not a historical or time-weighted price. Failed sources omitted and reported.",
        },
        "leaderboard": rows,
    }
    output = Path(args.out)
    temporary = output.with_name(output.name + ".tmp")
    temporary.write_text(json.dumps(out, indent=1))
    temporary.replace(output)
    print(f"wrote {args.out}: {len(rows)} addresses, {len(gaps)} gaps", flush=True)


if __name__ == "__main__":
    main()
