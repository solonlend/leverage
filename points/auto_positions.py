#!/usr/bin/env python3
"""

DEPLOY PREREQUISITE (equity pools, SPEC §5 v1.7): cost basis below prices deposits
via strategy.price() into TOKEN1 units — valid only for stableLeg=1 vaults. Before a
stableLeg=0 vault (NVDA/GLD/SGOV) deploys, parameterize the fold direction to the
stable leg, mirroring apps/lite auto-quote.ts.
Auto LP per-user cost basis (Beefy-dashboard style "At Deposit" value).

Replays the vault's Deposit/Withdraw events from the deploy block and prices each event
with the strategy's own price() at that historical block (archive eth_call), producing a
per-user USD cost basis: deposits add value at entry price; withdrawals reduce the basis
proportionally to the share fraction burned. Publish the JSON into the web root's data/
dir (same pattern as auto-pools.json); the frontend renders At deposit / Yield from it.

Sepolia rehearsal config baked in; the RH mainnet entry goes live with the deploy.
"""
import json, os, time, urllib.request

H = {"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"}
HERE = os.path.dirname(os.path.abspath(__file__))

CHAINS = [
    {
        "chainId": 11155111,
        # logs RPC need not be archive; price RPC must serve historical eth_call (1rpc does)
        # Two independent endpoints, results UNIONED by (tx, logIndex): public replicas have
        # been caught serving inconsistent getLogs (2026-09-11 — a whole user's history
        # vanished between runs). One endpoint missing an event must never lose it.
        "rpc_logs": "https://gateway.tenderly.co/public/sepolia",  # publicnode caught dropping a whole 20k-block range (2026-09-11)
        "rpc_logs_b": "https://ethereum-sepolia-rpc.publicnode.com",
        "rpc_archive": "https://1rpc.io/sepolia",
        "vault": "0x7C0cCcCB2C41e3DE01b4cB0Ba7d0EbdA11bb3701",
        "strategy": "0x8352d9Df9006c21Cfc4dCaeBA8ec91Dae4Af8F4F",
        "deploy_block": 11650000,
        "d0": 18,
        "d1": 6,
    },
    {
        "chainId": 4663,
        "rpc_logs": "https://rpc.mainnet.chain.robinhood.com/rpc",
        "rpc_logs_b": "https://robinhood-rpc.publicnode.com",
        "rpc_archive": "https://rpc.mainnet.chain.robinhood.com/rpc",  # young chain, full state serves recent blocks; price fallback handles gaps
        "vault": "0xfd7Ab6A724f28cE958Ee29E7A9DfAE7b9efC6B91",
        "strategy": "0x6F7343369d9AaFFC45d790b64E9543A8c804E844",
        "deploy_block": 60_232_400,
        "d0": 18,
        "d1": 6,
    },
]

# event Deposit(address indexed user, uint256 shares, uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1)
T_DEPOSIT = "0x1cd1a41553e51a76d6c31eee52a1c4c8dbb2ec6383326a4eaf8b0edb8d3f5f0e"
# event Withdraw(address indexed user, uint256 shares, uint256 amount0, uint256 amount1)
T_WITHDRAW = "0x02f25270a4d87bea75db541cdfe559334a275b4a233520ed6c0a2429667cca94"
SEL_PRICE = "0xa035b1fe"


def rpc(url, method, params, tries=7):
    err = ""
    for i in range(tries):
        try:
            req = urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(), H)
            r = json.load(urllib.request.urlopen(req, timeout=25))
            if "result" in r:
                return r["result"]
            err = str(r.get("error", ""))[:120]
        except Exception as e:
            err = str(e)[:120]
        time.sleep(min(20, 1.5 * 2 ** i))  # 1rpc 免费档限速,429 用指数退避
    raise RuntimeError(f"rpc {method} failed: {err}")


def topics_sig_check(cfg):
    # Derive topic0 from logs actually present rather than trusting hardcoded hashes:
    # fetch all logs of the vault and bucket by topic0 arity (Deposit has 6 words, Withdraw 3).
    q = [{"address": cfg["vault"], "fromBlock": hex(cfg["deploy_block"]), "toBlock": "latest"}]
    logs = rpc(cfg["rpc_logs"], "eth_getLogs", q)
    seen = {(lg["transactionHash"], lg["logIndex"]) for lg in logs}
    try:
        extra = [lg for lg in rpc(cfg["rpc_logs_b"], "eth_getLogs", q)
                 if (lg["transactionHash"], lg["logIndex"]) not in seen]
    except Exception as exc:
        extra = []
        print(f"  WARN second log endpoint failed ({exc}) — single-source scan")
    if extra:
        print(f"  WARN primary endpoint dropped {len(extra)} log(s) — recovered from second source")
        logs = logs + extra
    dep, wd = {}, {}
    for lg in logs:
        words = (len(lg["data"]) - 2) // 64
        t0 = lg["topics"][0]
        if words == 5:
            dep[t0] = dep.get(t0, 0) + 1
        elif words == 3:
            wd[t0] = wd.get(t0, 0) + 1
    dep_t = max(dep, key=dep.get) if dep else T_DEPOSIT
    wd_t = max(wd, key=wd.get) if wd else T_WITHDRAW
    return logs, dep_t, wd_t


def price_at(cfg, block, cache={}):
    key = (cfg["chainId"], block)
    if key not in cache:
        try:
            raw = int(rpc(cfg["rpc_archive"], "eth_call", [{"to": cfg["strategy"], "data": SEL_PRICE}, hex(block)]), 16)
        except Exception:
            # archive fallback — public archive endpoints flake independently
            raw = int(rpc(cfg["rpc_logs"], "eth_call", [{"to": cfg["strategy"], "data": SEL_PRICE}, hex(block)]), 16)
        cache[key] = raw / 1e36 * 10 ** (cfg["d0"] - cfg["d1"])
    return cache[key]


def run(cfg):
    logs, dep_t, wd_t = topics_sig_check(cfg)
    events = []
    for lg in logs:
        t0 = lg["topics"][0]
        if t0 not in (dep_t, wd_t):
            continue
        user = "0x" + lg["topics"][1][-40:]
        data = lg["data"][2:]
        words = [int(data[i * 64:(i + 1) * 64], 16) for i in range(len(data) // 64)]
        events.append({
            "kind": "dep" if t0 == dep_t else "wd",
            "user": user.lower(),
            "block": int(lg["blockNumber"], 16),
            "idx": int(lg["logIndex"], 16),
            "shares": words[0],
            "amount0": words[1],
            "amount1": words[2],
        })
    events.sort(key=lambda e: (e["block"], e["idx"]))

    pos = {}
    for e in events:
        p = price_at(cfg, e["block"])
        u = pos.setdefault(e["user"], {"shares": 0, "costBasisUsd": 0.0, "deposits": 0, "withdrawals": 0,
                                        "lifetimeInUsd": 0.0, "lifetimeOutUsd": 0.0})
        value = e["amount0"] / 10 ** cfg["d0"] * p + e["amount1"] / 10 ** cfg["d1"]
        if e["kind"] == "dep":
            u["costBasisUsd"] += value
            u["lifetimeInUsd"] += value
            u["shares"] += e["shares"]
            u["deposits"] += 1
        else:
            if u["shares"] > 0:
                frac = min(1.0, e["shares"] / u["shares"])
                u["costBasisUsd"] *= (1 - frac)
            u["shares"] = max(0, u["shares"] - e["shares"])
            u["lifetimeOutUsd"] += value
            u["withdrawals"] += 1

    out = {
        "chainId": cfg["chainId"],
        "vault": cfg["vault"].lower(),
        "computedAt": int(time.time()),
        "positions": {u: {**d, "shares": str(d["shares"])} for u, d in pos.items() if d["shares"] > 0 or d["withdrawals"]},
    }
    path = os.path.join(HERE, f"auto_positions_{cfg['chainId']}.json")
    with open(path, "w") as f:
        json.dump(out, f, indent=1)
    print(f"chain {cfg['chainId']}: {len(events)} events, {len(out['positions'])} users → {path}")
    for u, d in out["positions"].items():
        print(f"  {u[:10]}… basis=${d['costBasisUsd']:,.2f} dep={d['deposits']} wd={d['withdrawals']}")


if __name__ == "__main__":
    for cfg in CHAINS:
        run(cfg)
