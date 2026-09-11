"""Points v2 (revenue attribution) — offline unit tests, no RPC.

Run from stocklend/:  python3 -m unittest points.test_points_v2 -v
Covers the Codex Stage-A review findings: log-order segmentation, pre-burn ownership,
governor-self ambiguity, cache identity, decimals guard, rounding honesty.
"""
import unittest

from points import points_v2 as pv


class TestSkimUsd(unittest.TestCase):
    def test_usd_value_normalizes_both_tokens(self):
        usd = pv.skim_usd(cut0=500_000_000_000_000_000, cut1=250_000_000, eth_px=3000.0)
        self.assertAlmostEqual(usd, 1750.0, places=6)

    def test_zero_cut_is_zero_usd(self):
        self.assertEqual(pv.skim_usd(0, 0, 3000.0), 0.0)


class TestNetToCut(unittest.TestCase):
    def test_reconstructs_cut_within_one_raw_unit(self):
        # gross 10e18 at 10%: cut 1e18, net 9e18 → exact here.
        self.assertEqual(pv.net_to_cut(9 * 10**18, harvest_fee_bps=1000), 10**18)

    def test_can_overshoot_by_one_unit_when_contract_floored(self):
        # gross=9, bps=1000: contract cut=floor(0.9)=0, net=9. Reconstruction gives 1 —
        # documented +1-raw-unit ceiling, never claimed exact.
        self.assertEqual(pv.net_to_cut(9, harvest_fee_bps=1000), 1)

    def test_zero_and_full_bps_guards(self):
        self.assertEqual(pv.net_to_cut(10**18, harvest_fee_bps=0), 0)
        with self.assertRaises(ValueError):
            pv.net_to_cut(1, harvest_fee_bps=10000)


class TestOwnerBefore(unittest.TestCase):
    NFT = [
        {"pos_id": 1, "to": "0xaaa", "block": 10, "log_index": 5},   # mint
        {"pos_id": 1, "to": pv.ZERO, "block": 50, "log_index": 3},   # burn (full close)
        {"pos_id": 2, "to": "0xbbb", "block": 20, "log_index": 1},
    ]

    def test_owner_is_holder_at_block(self):
        self.assertEqual(pv.owner_before(self.NFT, 1, 30, 0), "0xaaa")

    def test_close_skim_after_burn_attributes_to_pre_burn_holder(self):
        # close path burns first (log 3), skims after (log 7 same block) — the skim
        # belongs to the pre-burn holder, never the zero address.
        self.assertEqual(pv.owner_before(self.NFT, 1, 50, 7), "0xaaa")

    def test_unknown_position_returns_none(self):
        self.assertIsNone(pv.owner_before(self.NFT, 99, 100, 0))


class TestSegmentedJoin(unittest.TestCase):
    """Transfers attach to the NEXT position event in log order (contract emits the
    event after its skim transfers), per tx — multiple ops per tx stay separated."""

    def test_two_positions_in_one_tx_are_split_correctly(self):
        tx_items = [
            {"kind_row": "transfer", "log_index": 1, "token": "weth", "amount": 100},
            {"kind_row": "event", "log_index": 2, "pos_id": 1, "kind": "harvested",
             "net0": 900, "net1": 0},
            {"kind_row": "transfer", "log_index": 3, "token": "usdg", "amount": 7},
            {"kind_row": "event", "log_index": 4, "pos_id": 2, "kind": "closed"},
        ]
        skims, orphans = pv.segment_tx(tx_items, block=100)
        self.assertEqual(len(skims), 2)
        self.assertEqual((skims[0]["pos_id"], skims[0]["cut0"], skims[0]["cut1"]), (1, 100, 0))
        self.assertEqual((skims[1]["pos_id"], skims[1]["cut0"], skims[1]["cut1"]), (2, 0, 7))
        self.assertEqual(orphans, [])

    def test_harvest_plus_liquidation_in_one_tx_only_liq_segment_excluded_later(self):
        tx_items = [
            {"kind_row": "transfer", "log_index": 1, "token": "usdg", "amount": 5},
            {"kind_row": "event", "log_index": 2, "pos_id": 1, "kind": "harvested",
             "net0": 0, "net1": 45},
            {"kind_row": "transfer", "log_index": 3, "token": "usdg", "amount": 9},
            {"kind_row": "event", "log_index": 4, "pos_id": 2, "kind": "liquidated"},
        ]
        skims, _ = pv.segment_tx(tx_items, block=100)
        kinds = {s["pos_id"]: s["kind"] for s in skims}
        self.assertEqual(kinds, {1: "harvested", 2: "liquidated"})

    def test_trailing_transfer_without_event_is_orphan(self):
        tx_items = [{"kind_row": "transfer", "log_index": 9, "token": "usdg", "amount": 1}]
        skims, orphans = pv.segment_tx(tx_items, block=1)
        self.assertEqual(skims, [])
        self.assertEqual(len(orphans), 1)


class TestGovernorSelf(unittest.TestCase):
    def test_harvested_segment_uses_event_net_when_owner_is_governor(self):
        # Owner == GOVERNOR: cut and net BOTH arrive at governor. The event's net
        # amounts reconstruct the true cut; raw transfer sum (cut+net) must not be used.
        s = {"pos_id": 1, "kind": "harvested", "cut0": 1000, "cut1": 0,
             "net0": 900, "net1": 0, "block": 1}
        fixed = pv.resolve_governor_self(s, owner="0xg", governor="0xg", bps=1000)
        self.assertEqual(fixed["cut0"], pv.net_to_cut(900, 1000))  # 100, not 1000
        self.assertFalse(fixed.get("ambiguous"))

    def test_closed_segment_with_governor_owner_is_ambiguous_and_excluded(self):
        # PositionClosed carries no fee data — a governor-owned close cannot separate
        # cut from refund; mark ambiguous, excluded from attribution, surfaced in recon.
        s = {"pos_id": 1, "kind": "closed", "cut0": 5000, "cut1": 0, "block": 1}
        fixed = pv.resolve_governor_self(s, owner="0xg", governor="0xg", bps=1000)
        self.assertTrue(fixed["ambiguous"])

    def test_non_governor_owner_passes_through(self):
        s = {"pos_id": 1, "kind": "closed", "cut0": 5000, "cut1": 0, "block": 1}
        fixed = pv.resolve_governor_self(s, owner="0xaaa", governor="0xg", bps=1000)
        self.assertEqual(fixed["cut0"], 5000)
        self.assertFalse(fixed.get("ambiguous"))


class TestAttributeSkims(unittest.TestCase):
    def test_liquidation_and_ambiguous_earn_no_points(self):
        skims = [
            {"owner": "0xaaa", "kind": "harvested", "cut0": 10**18, "cut1": 0, "eth_px": 3000.0},
            {"owner": "0xaaa", "kind": "liquidated", "cut0": 10**18, "cut1": 0, "eth_px": 3000.0},
            {"owner": "0xg", "kind": "closed", "cut0": 10**18, "cut1": 0, "eth_px": 3000.0,
             "ambiguous": True},
        ]
        pts = pv.attribute_skims(skims)
        self.assertAlmostEqual(pts["0xaaa"], 3000.0, places=6)
        self.assertNotIn("0xg", pts)

    def test_zero_or_missing_owner_is_never_credited(self):
        skims = [
            {"owner": None, "kind": "harvested", "cut0": 1, "cut1": 0, "eth_px": 1.0},
            {"owner": pv.ZERO, "kind": "harvested", "cut0": 1, "cut1": 0, "eth_px": 1.0},
        ]
        self.assertEqual(pv.attribute_skims(skims), {})


class TestGuards(unittest.TestCase):
    def test_flagship_decimals_guard(self):
        pv.check_flagship(18, 6)  # ok
        with self.assertRaises(SystemExit):
            pv.check_flagship(6, 18)

    def test_cache_identity_key(self):
        k1 = pv.cache_key(4663, "0xVault", 100)
        self.assertNotEqual(k1, pv.cache_key(4663, "0xVault", 101))
        self.assertNotEqual(k1, pv.cache_key(1, "0xVault", 100))
        self.assertEqual(k1, pv.cache_key(4663, "0xvault", 100))  # case-insensitive addr


class TestShareBalancesAt(unittest.TestCase):
    """B1: CLM vault share balances replayed from ERC20 Transfer logs."""

    XFERS = [
        {"from": pv.ZERO, "to": "0xaaa", "amount": 700, "block": 10, "log_index": 1},  # mint
        {"from": pv.ZERO, "to": "0xbbb", "amount": 300, "block": 20, "log_index": 1},  # mint
        {"from": "0xaaa", "to": "0xccc", "amount": 200, "block": 30, "log_index": 1},  # transfer
        {"from": "0xbbb", "to": pv.ZERO, "amount": 100, "block": 40, "log_index": 1},  # burn
    ]

    def test_balances_at_block_respect_history(self):
        bal = pv.share_balances_at(self.XFERS, block=25)
        self.assertEqual(bal, {"0xaaa": 700, "0xbbb": 300})

    def test_transfer_and_burn_move_balances(self):
        bal = pv.share_balances_at(self.XFERS, block=100)
        self.assertEqual(bal, {"0xaaa": 500, "0xbbb": 200, "0xccc": 200})

    def test_total_supply_conservation(self):
        bal = pv.share_balances_at(self.XFERS, block=100)
        self.assertEqual(sum(bal.values()), 700 + 300 - 100)


class TestClmHarvestPoints(unittest.TestCase):
    """B2: treasury-net harvest fee split pro-rata by share balances at the block."""

    def test_pro_rata_split_sums_to_treasury_take(self):
        balances = {"0xaaa": 700, "0xbbb": 300}
        pts = pv.clm_harvest_points(
            [{"block": 50, "treasury_usd": 100.0}], lambda blk: balances)
        self.assertAlmostEqual(pts["0xaaa"], 70.0, places=9)
        self.assertAlmostEqual(pts["0xbbb"], 30.0, places=9)
        self.assertAlmostEqual(sum(pts.values()), 100.0, places=9)

    def test_multiple_harvests_use_their_own_snapshots(self):
        snaps = {50: {"0xaaa": 1000}, 60: {"0xaaa": 500, "0xbbb": 500}}
        pts = pv.clm_harvest_points(
            [{"block": 50, "treasury_usd": 10.0}, {"block": 60, "treasury_usd": 10.0}],
            lambda blk: snaps[blk])
        self.assertAlmostEqual(pts["0xaaa"], 15.0, places=9)
        self.assertAlmostEqual(pts["0xbbb"], 5.0, places=9)

    def test_dead_share_donation_is_never_credited(self):
        # First depositor donates MINIMUM_SHARES to 0xdead — unclaimable, no points.
        balances = {"0x000000000000000000000000000000000000dead": 10, "0xaaa": 990}
        pts = pv.clm_harvest_points([{"block": 1, "treasury_usd": 100.0}], lambda blk: balances)
        self.assertNotIn("0x000000000000000000000000000000000000dead", pts)
        self.assertAlmostEqual(pts["0xaaa"], 99.0, places=9)  # dead slice stays unissued

    def test_exclude_list_removes_fee_recipient_from_split(self):
        # Lending line: the vault's own feeRecipient accrues fee shares over time —
        # those shares are the revenue itself and must not earn points on later accruals.
        balances = {"0xfee": 100, "0xaaa": 450, "0xbbb": 450}
        pts = pv.clm_harvest_points([{"block": 1, "treasury_usd": 90.0}],
                                    lambda blk: balances, exclude=("0xfee",))
        self.assertNotIn("0xfee", pts)
        # Denominator unchanged (DEAD precedent): the excluded 10% slice stays unissued.
        self.assertAlmostEqual(pts["0xaaa"], 40.5, places=9)
        self.assertAlmostEqual(pts["0xbbb"], 40.5, places=9)

    def test_empty_supply_harvest_earns_nobody_points(self):
        pts = pv.clm_harvest_points([{"block": 50, "treasury_usd": 10.0}], lambda blk: {})
        self.assertEqual(pts, {})


class TestMergeLines(unittest.TestCase):
    def test_merges_lines_with_breakdown_and_global_k(self):
        lines = {"leverage_harvest": {"0xAAA": 100.0},
                 "auto_lp_clm": {"0xaaa": 50.0, "0xbbb": 10.0}}
        merged = pv.merge_lines(lines, k=2.0)
        # case-insensitive address merge, K applied at the end
        self.assertAlmostEqual(merged["0xaaa"]["points"], 300.0, places=9)
        self.assertAlmostEqual(merged["0xaaa"]["breakdown"]["leverage_harvest"], 200.0, places=9)
        self.assertAlmostEqual(merged["0xaaa"]["breakdown"]["auto_lp_clm"], 100.0, places=9)
        self.assertAlmostEqual(merged["0xbbb"]["points"], 20.0, places=9)

    def test_empty_lines_merge_to_empty(self):
        self.assertEqual(pv.merge_lines({}, k=1.0), {})


class TestColdStart(unittest.TestCase):
    def test_line_below_threshold_uses_proxy(self):
        self.assertTrue(pv.use_proxy(trailing_30d_revenue_usd=99.99, threshold_usd=100.0))

    def test_line_at_threshold_uses_real_revenue(self):
        self.assertFalse(pv.use_proxy(trailing_30d_revenue_usd=100.0, threshold_usd=100.0))

    def test_proxy_points_are_rate_times_principal_days(self):
        pts = pv.proxy_points(principal_usd_days=300_000.0, target_rate_annual=0.02)
        self.assertAlmostEqual(pts, 300_000.0 * 0.02 / 365.0, places=6)


if __name__ == "__main__":
    unittest.main()
