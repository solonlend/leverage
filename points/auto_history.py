#!/usr/bin/env python3
"""Auto LP vault activity feed (SPEC §2.5.5 v1.9): harvest + rebalance history.

Replays strategy events into data/auto-history-<chainId>.json:
  harvest    — Harvest(fee0, fee1) [post-fee compounded amounts] + the same-tx
               ChargedFees split (caller/treasury) for the protocol-fee line.
  rebalance  — a strategy tx that emits TVL but carries NO Harvest and NO vault
               Deposit/Withdraw in the same tx (TVL fires on deposit, withdraw and
               moveTicks — elimination isolates moveTicks). New range read via an
               archive positionMain() call at that block (left empty on failure).

Log scans use TWO endpoints unioned by (tx, logIndex): public replicas have served
inconsistent getLogs (2026-09-11 — publicnode dropped a 20k-block range wholesale).
"""
import json, os, time, urllib.request

H = {"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"}
HERE = os.path.dirname(os.path.abspath(__file__))

CHAINS = [
    {
        "chainId": 11155111,
        "rpc_logs": "https://gateway.tenderly.co/public/sepolia",
        "rpc_logs_b": "https://ethereum-sepolia-rpc.publicnode.com",
        "rpc_archive": "https://1rpc.io/sepolia",
        "vault": "0x7C0cCcCB2C41e3DE01b4cB0Ba7d0EbdA11bb3701",
        "strategy": "0x8352d9Df9006c21Cfc4dCaeBA8ec91Dae4Af8F4F",
        "deploy_block": 11_650_000,
        "d0": 18,
        "d1": 6,
    },
    # RH mainnet entry goes live with the Auto deploy (fill vault/strategy/deploy_block).
    {
        "chainId": 4663,
        "rpc_logs": "https://rpc.mainnet.chain.robinhood.com/rpc",
        "rpc_logs_b": "https://robinhood-rpc.publicnode.com",
        "rpc_archive": "https://rpc.mainnet.chain.robinhood.com/rpc",
        "vault": "0xfd7Ab6A724f28cE958Ee29E7A9DfAE7b9efC6B91",
        "strategy": "0x6F7343369d9AaFFC45d790b64E9543A8c804E844",
        "deploy_block": 60_232_400,
        "d0": 18,
        "d1": 6,
    },
]

T_HARVEST = "0x6c8433a8e155f0af04dba058d4e4695f7da554578963d876bdf4a6d8d6399d9c"
T_TVL = "0x631c4f79c14099a717f4be2f25e6cef89e310b3944ef0e44ea2c0811ebb982a8"
T_CHARGED = "0x9e1e3876a8a93b5957114512cad3320495e0b9761c7599fb096a20bc9c9b0262"  # ChargedFees(uint256,uint256,uint256,uint256)
SEL_POSITION_MAIN = "0xbc415d8a"  # positionMain()


def rpc(url, method, params, tries=6):
    err = None
    for i in range(tries):
        try:
            req = urllib.request.Request(
                url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(), H)
            out = json.load(urllib.request.urlopen(req, timeout=40))
            if "result" in out and out["result"] is not None:
                return out["result"]
            err = out.get("error")
        except Exception as exc:  # noqa: BLE001
            err = exc
        time.sleep(min(20, 1.5 * 2**i))
    raise RuntimeError(f"rpc {method} failed: {err}")


def union_logs(cfg, address):
    q = [{"address": address, "fromBlock": hex(cfg["deploy_block"]), "toBlock": "latest"}]
    logs = rpc(cfg["rpc_logs"], "eth_getLogs", q)
    seen = {(lg["transactionHash"], lg["logIndex"]) for lg in logs}
    try:
        extra = [lg for lg in rpc(cfg["rpc_logs_b"], "eth_getLogs", q)
                 if (lg["transactionHash"], lg["logIndex"]) not in seen]
        if extra:
            print(f"  WARN primary dropped {len(extra)} log(s) — recovered from second source")
            logs += extra
    except Exception as exc:  # noqa: BLE001
        print(f"  WARN second endpoint failed ({exc}) — single-source scan")
    return logs


def block_ts(cfg, block, cache={}):
    if block not in cache:
        b = rpc(cfg["rpc_logs"], "eth_getBlockByNumber", [hex(block), False])
        cache[block] = int(b["timestamp"], 16)
    return cache[block]


def words(lg):
    d = lg["data"][2:]
    return [int(d[i : i + 64], 16) for i in range(0, len(d), 64)]


def main():
    for cfg in CHAINS:
        strat_logs = union_logs(cfg, cfg["strategy"])
        vault_logs = union_logs(cfg, cfg["vault"])
        vault_txs = {lg["transactionHash"] for lg in vault_logs}

        by_tx = {}
        for lg in strat_logs:
            by_tx.setdefault(lg["transactionHash"], []).append(lg)

        entries = []
        for tx, lgs in by_tx.items():
            block = int(lgs[0]["blockNumber"], 16)
            topics = {lg["topics"][0]: lg for lg in lgs}
            if T_HARVEST in topics:
                fee = words(topics[T_HARVEST])
                entry = {"tx": tx, "block": block, "ts": block_ts(cfg, block),
                         "kind": "harvest", "fee0": str(fee[0]), "fee1": str(fee[1])}
                charged = topics.get(T_CHARGED)
                if charged:
                    c = words(charged)
                    entry["call0"], entry["call1"] = str(c[0]), str(c[1])
                    entry["treasury0"], entry["treasury1"] = str(c[2]), str(c[3])
                entries.append(entry)
            elif T_TVL in topics and tx not in vault_txs:
                bal = words(topics[T_TVL])
                entry = {"tx": tx, "block": block, "ts": block_ts(cfg, block),
                         "kind": "rebalance", "bal0": str(bal[0]), "bal1": str(bal[1])}
                try:
                    raw = rpc(cfg["rpc_archive"], "eth_call",
                              [{"to": cfg["strategy"], "data": SEL_POSITION_MAIN}, hex(block)])
                except Exception:
                    try:
                        raw = rpc(cfg["rpc_logs"], "eth_call",
                                  [{"to": cfg["strategy"], "data": SEL_POSITION_MAIN}, hex(block)])
                    except Exception:
                        raw = None
                if raw and len(raw) >= 2 + 128:
                    lo = int(raw[2:66], 16)
                    hi = int(raw[66:130], 16)
                    # int24 sign-extend
                    if lo >= 2**255: lo -= 2**256
                    if hi >= 2**255: hi -= 2**256
                    entry["tickLower"], entry["tickUpper"] = lo, hi
                entries.append(entry)

        entries.sort(key=lambda e: -e["block"])
        out = {"chainId": cfg["chainId"], "vault": cfg["vault"].lower(),
               "strategy": cfg["strategy"].lower(), "computedAt": int(time.time()),
               "entries": entries}
        path = os.path.join(HERE, f"auto_history_{cfg['chainId']}.json")
        with open(path, "w") as f:
            json.dump(out, f, indent=1)
        print(f"chain {cfg['chainId']}: {len(entries)} entries → {path}")
        for e in entries[:6]:
            print(f"  {e['kind']:9s} block {e['block']} {e['tx'][:14]}")


if __name__ == "__main__":
    main()
