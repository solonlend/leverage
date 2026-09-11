# Solon indexers — replayable by anyone

Every number on the Points board and the Auto LP pages comes from one of these
single-file, dependency-free (Python 3 stdlib) indexers. No server trust required:
run them yourself against public RPCs and diff the JSON against what the site serves.

| File | Produces | Feeds |
|---|---|---|
| `indexer.py` | points.json | Points v1 — Morpho lending shards (shares × seconds) |
| `farm_points.py` | farm_points.json | Points v1 — farm/lending principal-days |
| `points_v2.py` | points_v2*.json, farm-basis | Points v2 — revenue attribution (`clm` / `lending` / `basis` / `publish` subcommands) |
| `auto_pools.py` | auto-pools.json | Auto LP pre-launch pool stats (Uniswap gateway) |
| `auto_positions.py` | auto-positions-*.json | Auto LP per-user cost basis (entry-priced) |
| `auto_history.py` | auto-history-*.json | Auto LP harvest/rebalance activity |
| `farm_fee_apr.py` | farm-fee-apr.json | Live fee APR (feeGrowth rolling window) |

Hard-won operational notes are inline: public RPC replicas have been caught serving
inconsistent `eth_getLogs` (dual-endpoint unions + per-tx receipt rescue throughout),
and points v2's attribution edge cases (owner-before-burn, same-tx segmentation,
governor self-dealing exclusion) each carry offline unit tests.

Tests: `python3 -m unittest test_farm_points test_points_v2` (run from the parent dir
as package `points.*`, or adjust imports).
