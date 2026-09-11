import unittest
import io
import json
import urllib.error
import tempfile
from pathlib import Path
from unittest.mock import patch

from points import farm_points as fp


DAY = 86_400
OWNER = "0x" + "11" * 20
VAULT = "0x" + "22" * 20


def word(value):
    return hex(value)[2:].rjust(64, "0")


def topic(value):
    return "0x" + word(value)


def address_topic(address):
    return "0x" + address[2:].lower().rjust(64, "0")


def log(event_topic, tx, index, topics=(), data_words=(), block=1):
    return {
        "topics": [event_topic, *topics],
        "data": "0x" + "".join(word(value) for value in data_words),
        "blockNumber": hex(block),
        "logIndex": hex(index),
        "transactionHash": tx,
    }


class FarmPointsRegressions(unittest.TestCase):
    def test_pool_actuals_ignore_overborrow_request(self):
        tx = "0xaaa"
        opened = log(
            fp.TOPICS["open"], tx, 3,
            topics=(topic(7), address_topic(OWNER)),
            # investRisk, investLoan, requestedRisk, requestedLoan,
            # debtRisk, debtLoan, liquidity, tickLower, tickUpper
            data_words=(0, 0, 0, 1_000_000_000, 70, 71, 1, 0, 0),
        )
        pool_logs = {
            "borrow": [log(fp.TOPICS["borrow"], tx, 1,
                           topics=(topic(1), address_topic(VAULT), address_topic(VAULT)),
                           data_words=(1_000_000_000,))],
            "repay": [log(fp.TOPICS["repay"], tx, 2,
                          topics=(topic(1), address_topic(VAULT), address_topic(VAULT)),
                          data_words=(900_000_000,))],
        }
        raw = {kind: [] for kind in ("open", "increase", "repay2", "close", "liq")}
        raw["open"] = [opened]

        owner_of, events, _skipped = fp.pool_principal_events(raw, pool_logs, 2_000.0, lambda _block: 0)
        owner_events = fp.clamped_owner_events(owner_of, events)
        new_points = fp.shards_from_balance_events(owner_events, DAY)[OWNER] / fp.POINT_SCALE
        old_points = fp.shards_from_balance_events(
            [(1, 3, OWNER, 1_000.0, 0)], DAY
        )[OWNER] / fp.POINT_SCALE

        self.assertEqual((old_points, new_points), (1_000.0, 100.0))
        self.assertEqual([event[2] for event in events[7]], [71, 71])

    def test_interest_overpay_does_not_reduce_another_position(self):
        owner_of = {1: OWNER}
        events = {
            1: [
                (1, 1, 101, 100.0, 0),
                (1, 2, 201, 200.0, 0),
                (2, 1, 101, -110.0, DAY),
            ],
        }

        owner_events = fp.clamped_owner_events(owner_of, events)
        new_points = fp.shards_from_balance_events(owner_events, 2 * DAY)[OWNER] / fp.POINT_SCALE
        old_owner_events = [
            (1, 1, OWNER, 100.0, 0),
            (1, 2, OWNER, 200.0, 0),
            (2, 1, OWNER, -110.0, DAY),
        ]
        old_points = fp.shards_from_balance_events(old_owner_events, 2 * DAY)[OWNER] / fp.POINT_SCALE

        self.assertEqual((old_points, new_points), (490.0, 500.0))
        self.assertEqual(sorted(event[3] for event in owner_events), [-100.0, 100.0, 200.0])

    def test_pool_logs_pair_with_the_immediate_next_position_boundary(self):
        tx = "0xbbb"
        open_7 = log(
            fp.TOPICS["open"], tx, 2,
            topics=(topic(7), address_topic(OWNER)),
            data_words=(0, 0, 0, 0, 70, 71, 1, 0, 0),
        )
        open_8 = log(
            fp.TOPICS["open"], tx, 5,
            topics=(topic(8), address_topic(OWNER)),
            data_words=(0, 0, 0, 0, 80, 81, 1, 0, 0),
        )
        pool_logs = {
            "borrow": [
                log(fp.TOPICS["borrow"], tx, 1, topics=(topic(1),), data_words=(10_000_000,)),
                log(fp.TOPICS["borrow"], tx, 4, topics=(topic(2),), data_words=(10**18,)),
            ],
            "repay": [],
        }
        raw = {kind: [] for kind in fp.VAULT_EVENT_KINDS}
        raw["open"] = [open_7, open_8]

        _owners, events, _skipped = fp.pool_principal_events(raw, pool_logs, 2_000.0, lambda _block: 0)

        self.assertEqual([(pid, event[2]) for pid, evs in events.items() for event in evs], [(7, 71), (8, 80)])

    def test_window_truncated_position_is_skipped_and_reported(self):
        tx = "0xccc"
        raw = {kind: [] for kind in fp.VAULT_EVENT_KINDS}
        raw["increase"] = [log(fp.TOPICS["increase"], tx, 2, topics=(topic(7),))]
        pool_logs = {
            "borrow": [log(fp.TOPICS["borrow"], tx, 1, topics=(topic(1),), data_words=(10_000_000,))],
            "repay": [],
        }

        owners, events, skipped = fp.pool_principal_events(
            raw, pool_logs, 2_000.0, lambda _block: 0, tolerate_missing_mappings=True
        )

        self.assertEqual(owners, {})
        self.assertEqual(dict(events), {})
        self.assertEqual(skipped, {"pool_logs": 1, "position_count": 1, "positions": [7]})


class RpcRegressions(unittest.TestCase):
    def test_failed_reserve_and_borrow_publish_other_reserve_with_gaps(self):
        def rpc(_url, method, params):
            if method == 'eth_chainId': return '0x1237'
            if method == 'eth_blockNumber': return hex(56_660_000)
            if method == 'eth_getBlockByNumber': return {'timestamp': hex(DAY if params[0] == '0x1' else 2 * DAY)}
            raise AssertionError(method)
        def call(_url, address, data, *args):
            if address == fp.DEFAULTS['oracle']: return hex(2000 * 10**6)
            return '0x' + ('33' if data.endswith('1') else '44') * 20
        def logs(_url, address, topics, start, latest):
            if address == '0x' + '33' * 20:
                return [log(fp.TOPIC_TRANSFER, 'tx', 0, (address_topic('0x'+'00'*20), address_topic(OWNER)), (10**6,), block=1)]
            raise RuntimeError('eth_getLogs: HTTP 403; retries exhausted')
        with tempfile.TemporaryDirectory() as d, patch.object(fp, 'rpc', rpc), patch.object(fp, 'call', call), patch.object(fp, 'deploy_block', return_value=(56_546_827, 'bounded:firstlog:floor=56546362')), patch.object(fp, 'get_logs', logs), patch.object(fp.time, 'time', return_value=3*DAY), patch('sys.argv', ['farm_points.py', '--out', str(Path(d)/'points.json')]):
            fp.main()
            out = json.loads((Path(d)/'points.json').read_text())
        self.assertEqual(len(out['leaderboard']), 1)
        self.assertEqual(out['leaderboard'][0]['borrow_points'], 0)
        self.assertEqual({g['source'] for g in out['gaps']}, {'supply:WETH', 'borrow'})
        self.assertFalse(out['complete'])
        self.assertEqual(out['params']['sources']['farm_vault'], fp.DEFAULTS['vault'])

    def test_discovery_reused_for_filtered_replay_without_more_rpc(self):
        transfer = log(fp.TOPIC_TRANSFER, 'tx', 0, (address_topic(OWNER), address_topic(VAULT)), (1,), block=500)
        other = log(fp.TOPICS['borrow'], 'tx', 1, (), (1,), block=600)
        with patch.object(fp, 'rpc', return_value=[other, transfer]) as request:
            genesis, _ = fp.deploy_block('cached', VAULT, 1000, 1000)
            result = fp.get_logs('cached', VAULT, [fp.TOPIC_TRANSFER, address_topic(OWNER)], genesis, 1000)
        self.assertEqual(result, [transfer])
        self.assertEqual(request.call_count, 1)

    def test_range_error_shrinks_once_and_never_regrows(self):
        attempts = []
        def request(_url, _method, params):
            lo, hi = (int(params[0][k], 16) for k in ('fromBlock', 'toBlock'))
            attempts.append((lo, hi))
            if hi - lo + 1 > 2500:
                raise RuntimeError('block range limited to 2500')
            return [{'blockNumber': hex(lo)}]
        with patch.object(fp, 'rpc', request):
            logs = fp.get_logs('range-test', VAULT, [], 0, 9999)
        self.assertEqual([int(lg['blockNumber'],16) for lg in logs], [0, 2500, 5000, 7500])
        self.assertEqual([hi-lo+1 for lo,hi in attempts], [10000, 5000, 2500, 2500, 2500, 2500])

    def test_failed_discovery_never_caches_partial_history(self):
        with patch.object(fp, 'rpc', side_effect=[[{'blockNumber': hex(15000)}], RuntimeError('HTTP 403 exhausted')]) as request:
            with self.assertRaisesRegex(RuntimeError, '403'):
                fp.deploy_block('failed-cache', VAULT, 19999, 19999)
        self.assertNotIn(('failed-cache', VAULT.lower(), 19999), fp._log_history)
        self.assertEqual(request.call_count, 2)

    def test_429_exhaustion_stays_bounded_and_does_not_change_custom_rpc(self):
        clock, urls = [0.0], []
        def request(req, timeout):
            urls.append(req.full_url)
            raise urllib.error.HTTPError(req.full_url, 429, 'limit', {}, io.BytesIO())
        with patch.object(fp, '_rpc_last_call', None), patch.object(fp.time, 'sleep', lambda n: clock.__setitem__(0,clock[0]+n)), patch.object(fp.time, 'monotonic', lambda: clock[0]), patch.object(fp.urllib.request, 'urlopen', request):
            with self.assertRaisesRegex(RuntimeError, 'retry budget exhausted'):
                fp.rpc('https://custom.example', 'eth_getLogs', [])
        self.assertGreaterEqual(clock[0], 120)
        self.assertLessEqual(clock[0], 180)
        self.assertEqual(set(urls), {'https://custom.example'})

    def test_backward_genesis_keeps_sparse_older_logs_and_respects_floor(self):
        ranges = []
        def request(_url, method, params):
            self.assertEqual(method, 'eth_getLogs')
            lo, hi = (int(params[0][k], 16) for k in ('fromBlock', 'toBlock'))
            self.assertLessEqual(hi - lo + 1, 10_000)
            self.assertGreaterEqual(lo, 50_000)
            ranges.append((lo, hi))
            return [{'blockNumber': hex(b)} for b in (50_123, 99_999) if lo <= b <= hi]
        with patch.object(fp, 'rpc', request):
            genesis, how = fp.deploy_block('custom', VAULT, 100_000, 50_000)
        self.assertEqual(genesis, 50_123)
        self.assertIn('firstlog', how)
        self.assertEqual(ranges[0][1], 100_000)
        self.assertEqual(ranges[-1][0], 50_000)
        self.assertTrue(all(ranges[i][0] == ranges[i+1][1] + 1 for i in range(len(ranges)-1)))

    def test_persistent_throttle_recovers_with_browser_ua_and_rotation(self):
        clock = [0.0]
        urls = []
        def sleep(seconds):
            clock[0] += seconds
        def request(req, timeout):
            urls.append(req.full_url)
            self.assertIn("Mozilla", req.get_header("User-agent"))
            if clock[0] < 120:
                raise urllib.error.HTTPError(req.full_url, 403, "throttled", {}, io.BytesIO())
            return io.StringIO(json.dumps({"result": "0x1237"}))
        with patch.object(fp, '_rpc_last_call', None), patch.object(fp.time, 'sleep', sleep), patch.object(fp.time, 'monotonic', lambda: clock[0]), patch.object(fp.time, 'time', lambda: clock[0]), patch.object(fp.urllib.request, 'urlopen', request):
            self.assertEqual(fp.rpc(fp.DEFAULTS['rpc'], 'eth_chainId', []), '0x1237')
        self.assertGreaterEqual(len(set(urls)), 3)
        self.assertLessEqual(clock[0], 180)


if __name__ == "__main__":
    unittest.main()
