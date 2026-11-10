import json
from pathlib import Path
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import MagicMock, patch

from test_collect import c

WALLET = "prl1" + "x" * 59
KRYPTEX = {"pool": "kryptex", "walletAddress": WALLET}


def pool_worker(name="rtx4090", **overrides):
    return {"miner": WALLET, "worker": name, "coin": "prl", "scheme": "pps", "status": "online",
            "avg_hashrate_30m": "300000000000000", "avg_hashrate_3h": "290000000000000",
            "avg_hashrate_24h": "280000000000000", **overrides}


class MiningTests(unittest.TestCase):
    def setUp(self):
        # Mining-source tests do not make wallet/explorer requests.
        for name in ("pearl_wallet", "pearl_balance", "pearl_payouts", "pearl_paid"):
            stub = patch.object(c, name, return_value={})
            stub.start()
            self.addCleanup(stub.stop)
        for name, value in (
                ("pearl_history", {"hashrate7d": 300e12, "historyUpdatedAt": 1000}),
                ("pearl_pool", {"ticker": "prl", "estimated_profit_day": 2e-14, "fee": .02})):
            stub = patch.object(c, name, return_value=value)
            stub.start()
            self.addCleanup(stub.stop)

    def test_pool_hashrate_uses_hs_and_filters_the_selected_worker(self):
        data = {"results": [pool_worker(), pool_worker("second", avg_hashrate_30m="50000000000000")]}
        result = c.parse_pool_workers(data, WALLET, "rtx4090")
        self.assertEqual(result["hashrate"], 300e12)
        self.assertEqual(result["hashrate3h"], 290e12)
        self.assertEqual(result["hashrate24h"], 280e12)
        self.assertEqual(result["onlineWorkers"], 1)
        self.assertEqual(c.parse_pool_workers(data, WALLET)["hashrate"], 350e12)
        self.assertNotIn(WALLET, json.dumps(result))

    def test_offline_workers_have_zero_current_rate_but_keep_historical_averages(self):
        result = c.parse_pool_workers({"results": [pool_worker(status="offline")]}, WALLET)
        self.assertEqual(result["hashrate"], 0)
        self.assertEqual(result["hashrate24h"], 280e12)
        self.assertEqual(result["onlineWorkers"], 0)
        self.assertEqual(result["workerCount"], 1)

    def test_missing_workers_are_unknown_instead_of_zero(self):
        for data, worker in [({"results": []}, ""), ({"results": [pool_worker()]}, "missing")]:
            with self.subTest(worker=worker), self.assertRaises(c.SourceError):
                c.parse_pool_workers(data, WALLET, worker)

    def test_pool_rejects_invalid_rates_identity_and_incomplete_worker_lists(self):
        for value in (-1, None, True, "nan", "Infinity", []):
            with self.subTest(value=value), self.assertRaises(c.SourceError):
                c.parse_pool_workers({"results": [pool_worker(avg_hashrate_30m=value)]}, WALLET)
        for data in ({"results": None}, {"results": [None]}, {"results": [pool_worker()], "count": 2},
                     {"results": [pool_worker()], "next": "/more"},
                     {"results": [pool_worker(miner="different-wallet")]},
                     {"results": [pool_worker(coin="btc")]}, {"results": [pool_worker(status="unknown")]}):
            with self.subTest(data=data), self.assertRaises(c.SourceError):
                c.parse_pool_workers(data, WALLET)

    def test_zero_rate_is_valid_and_missing_longer_average_does_not_hide_it(self):
        result = c.parse_pool_workers({"results": [pool_worker(avg_hashrate_30m=0, avg_hashrate_24h=None)]}, WALLET)
        self.assertEqual(result["hashrate"], 0)
        self.assertIsNone(result["hashrate24h"])

    def test_projection_applies_pool_fee_without_double_charging_developer_fee(self):
        coins, fee = c.pearl_yield({"ticker": "prl", "estimated_profit_day": 2e-14, "fee": .02}, 300e12)
        self.assertAlmostEqual(coins, 5.88)
        self.assertEqual(fee, 2)
        for override in ({"ticker": "other"}, {"fee": 2}, {"estimated_profit_day": None}):
            with self.assertRaises(c.SourceError):
                c.pearl_yield({"ticker": "prl", "estimated_profit_day": 2e-14, "fee": .02, **override}, 300e12)

    def test_pool_failure_does_not_hide_price_or_invent_projection(self):
        with tempfile.TemporaryDirectory() as root, patch.object(c, "pearl_price", return_value={"priceUSD": 1.1, "updatedAt": 1000}), \
                patch.object(c, "pearl_workers", side_effect=c.SourceError("Pool unavailable.")):
            result = c.fetch_pearl({**KRYPTEX}, Path(root))
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["pearl"]["priceUSD"], 1.1)
        self.assertNotIn("hashrate", result["pearl"])
        self.assertNotIn("coinsPerDay", result["pearl"])

    def test_price_failure_preserves_pool_hashrate_and_token_yield_without_local_requests(self):
        def response(url):
            return {"results": [pool_worker()]} if "/workers/" in url else {"ticker": "prl", "estimated_profit_day": 2e-14, "fee": .02}
        with tempfile.TemporaryDirectory() as root, patch.object(c, "pearl_price", side_effect=c.SourceError("Price unavailable.")), \
                patch.object(c, "local_json") as local, patch.object(c, "request_json", side_effect=response):
            result = c.fetch_pearl({**KRYPTEX, "minerURL": "http://retired.local", "minerFeePercent": 2}, Path(root))
            local.assert_not_called()
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["pearl"]["hashrate"], 300e12)
        self.assertNotIn("priceUSD", result["pearl"])
        self.assertAlmostEqual(result["pearl"]["coinsPerDay"], 5.88)

    def test_non_pps_workers_keep_hashrate_without_pps_projections(self):
        workers = c.parse_pool_workers({"results": [pool_worker(scheme="solo")]}, WALLET)
        with tempfile.TemporaryDirectory() as root, patch.object(c, "pearl_price", return_value={"priceUSD": 1.1, "updatedAt": 1000}), \
                patch.object(c, "pearl_workers", return_value=workers):
            result = c.fetch_pearl({**KRYPTEX}, Path(root))
        self.assertEqual(result["pearl"]["hashrate"], 300e12)
        self.assertNotIn("coinsPerDay", result["pearl"])
        self.assertIn("PPS+", result["error"])

    def test_selected_average_drives_headline_and_yield_with_week_as_default(self):
        for window, expected in ((None, 300e12), ("30m", 400e12), ("3h", 290e12), ("24h", 280e12), ("7d", 300e12)):
            with self.subTest(window=window), tempfile.TemporaryDirectory() as root, \
                    patch.object(c, "pearl_price", return_value={"priceUSD": 1, "updatedAt": 1000}), \
                    patch.object(c, "pearl_workers", return_value=c.parse_pool_workers(
                        {"results": [pool_worker(avg_hashrate_30m=400e12)]}, WALLET)):
                config = dict(KRYPTEX)
                if window is not None:
                    config["averageWindow"] = window
                result = c.fetch_pearl(config, Path(root))
            self.assertNotIn("error", result)
            self.assertEqual(result["pearl"]["averageWindow"], window or "7d")
            self.assertEqual(result["pearl"]["hashrate"], expected)
            self.assertEqual(result["pearl"]["hashrate30m"], 400e12)
            self.assertAlmostEqual(result["pearl"]["coinsPerDay"], expected * 2e-14 * .98)

    def test_missing_selected_average_does_not_fall_back_or_erase_other_metrics(self):
        for window in ("7d", "3h", "30m"):
            with self.subTest(window=window), tempfile.TemporaryDirectory() as root, \
                    patch.object(c, "pearl_price", return_value={"priceUSD": 1, "updatedAt": 1000}), \
                    patch.object(c, "pearl_workers", return_value=c.parse_pool_workers(
                        {"results": [pool_worker(avg_hashrate_3h=None)]}, WALLET)), \
                    patch.object(c, "pearl_history", side_effect=c.SourceError("History unavailable.")):
                result = c.fetch_pearl({**KRYPTEX, "averageWindow": window}, Path(root))
            self.assertEqual(result["pearl"]["priceUSD"], 1)
            self.assertEqual(result["pearl"]["hashrate30m"], 300e12)
            if window == "30m":
                self.assertNotIn("error", result)
                self.assertAlmostEqual(result["pearl"]["coinsPerDay"], 5.88)
            else:
                self.assertEqual(result["status"], "partial")
                self.assertNotIn("hashrate", result["pearl"])
                self.assertNotIn("coinsPerDay", result["pearl"])

    def test_offline_worker_keeps_selected_weekly_average_and_zero_current_rate(self):
        with tempfile.TemporaryDirectory() as root, \
                patch.object(c, "pearl_price", return_value={"priceUSD": 1, "updatedAt": 1000}), \
                patch.object(c, "pearl_workers", return_value=c.parse_pool_workers(
                    {"results": [pool_worker(status="offline")]}, WALLET)):
            result = c.fetch_pearl({**KRYPTEX}, Path(root))
        self.assertEqual(result["pearl"]["hashrate"], 300e12)
        self.assertEqual(result["pearl"]["hashrate30m"], 0)
        self.assertEqual(result["pearl"]["onlineWorkers"], 0)

    def test_worker_cache_is_private_and_separate_for_each_selection(self):
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", return_value={"results": [pool_worker()]} ) as request:
            first = {"walletAddress": WALLET, "workerName": "rtx4090"}
            c.pearl_workers(first, Path(root))
            c.pearl_workers(first, Path(root))
            self.assertEqual(request.call_count, 1)
            c.pearl_workers({"walletAddress": WALLET}, Path(root))
            self.assertEqual(request.call_count, 2)
            for path in Path(root).glob("*.json"):
                self.assertNotIn(WALLET, path.read_text())
                self.assertNotIn("rtx4090", path.read_text())
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_worker_backoff_is_not_bypassed_by_refresh(self):
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=c.HTTPFailure(429, retry_after=600)) as request:
            for _ in range(2):
                with self.assertRaises(c.SourceError):
                    c.pearl_workers({"walletAddress": WALLET}, Path(root))
            self.assertEqual(request.call_count, 1)

    def test_invalid_wallet_never_makes_a_network_request(self):
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json") as request:
            for wallet in ("", "https://pool.kryptex.com/", "prl1/../../", "prl1" + "x" * 121):
                with self.assertRaises(c.SourceError):
                    c.pearl_workers({"walletAddress": wallet}, Path(root))
            request.assert_not_called()

    def test_market_price_is_for_pearl_research_and_has_a_fresh_timestamp(self):
        with tempfile.TemporaryDirectory() as root, patch.object(c.time, "time", return_value=10000), \
                patch.object(c, "request_json", return_value={"pearl-2": {"usd": 1.1, "last_updated_at": 9950}}) as request:
            self.assertEqual(c.pearl_price(Path(root))["priceUSD"], 1.1)
            c.pearl_price(Path(root))
            self.assertEqual(request.call_count, 1)
            self.assertIn("ids=pearl-2", request.call_args.args[0])
        with tempfile.TemporaryDirectory() as root, patch.object(c.time, "time", return_value=10000), \
                patch.object(c, "request_json", return_value={"pearl-2": {"usd": 1.1, "last_updated_at": 9000}}):
            with self.assertRaises(c.SourceError): c.pearl_price(Path(root))

    def test_public_price_backoff_does_not_get_bypassed_by_refreshes(self):
        with tempfile.TemporaryDirectory() as root, patch.object(c.time, "time", return_value=10000), \
                patch.object(c, "request_json", side_effect=c.HTTPFailure(429, retry_after=600)) as request:
            for _ in range(2):
                with self.assertRaises(c.SourceError): c.pearl_price(Path(root))
            self.assertEqual(request.call_count, 1)
            self.assertEqual(json.loads((Path(root) / "pearl-price.json").read_text())["nextRetryAt"], 10600)


class HashrateHistoryTests(unittest.TestCase):
    now = 1_800_000_000

    def history(self):
        return [{"timestamp": (self.now - 7 * 86400 + index * 600) * 1000,
                 "hashrate": 300e12, "avg_hashrate_30m": 999e12, "avg_hashrate_3h": 999e12}
                for index in range(1009)]

    def test_full_week_uses_raw_hashrate_and_includes_zero_intervals(self):
        data = self.history()
        for row in data[:504]:
            row["hashrate"] = 0
        # The last timestamp bounds the window; no duration is invented beyond it.
        data[-1]["hashrate"] = 999e12
        with patch.object(c.time, "time", return_value=self.now + 600):
            result = c.parse_pearl_history(list(reversed(data)))
        self.assertEqual(result, {"hashrate7d": 150e12, "historyUpdatedAt": self.now})

    def test_accepts_seconds_and_numeric_strings_and_clips_older_history(self):
        data = [{"timestamp": (self.now - 8 * 86400) * 1000, "hashrate": 999e12}] + self.history()
        for row in data:
            row["timestamp"] = str(row["timestamp"] / 1000)
            row["hashrate"] = str(row["hashrate"])
        with patch.object(c.time, "time", return_value=self.now):
            self.assertEqual(c.parse_pearl_history(data)["hashrate7d"], 300e12)

    def test_rejects_short_missing_duplicate_stale_future_and_malformed_history(self):
        data = self.history()
        for bad in ({}, [], [None], data[1:], data[:500] + data[501:], data + [data[-1]],
                    [{**row, "timestamp": row["timestamp"] - 1_800_000} for row in data],
                    [{**row, "timestamp": row["timestamp"] + 600_000} for row in data]):
            with self.subTest(case=str(bad)[:80]), patch.object(c.time, "time", return_value=self.now), \
                    self.assertRaises(c.SourceError):
                c.parse_pearl_history(bad)
        for field, values in (("hashrate", [-1, None, True, "nan", "Infinity", []]),
                              ("timestamp", [None, True, "invalid", "Infinity"])):
            for value in values:
                bad = self.history()
                bad[500][field] = value
                with self.subTest(field=field, value=value), patch.object(c.time, "time", return_value=self.now), \
                        self.assertRaises(c.SourceError):
                    c.parse_pearl_history(bad)

    def test_history_cache_separates_wallet_and_worker_and_keeps_only_private_metrics(self):
        with tempfile.TemporaryDirectory() as root, patch.object(c.time, "time", return_value=self.now), \
                patch.object(c, "request_json", return_value=self.history()) as request:
            config = {"walletAddress": WALLET, "workerName": "rig / 1"}
            c.pearl_history(config, Path(root))
            c.pearl_history({**config, "averageWindow": "30m"}, Path(root))
            self.assertEqual(request.call_count, 1)
            self.assertTrue(request.call_args.args[0].endswith("/rig%20%2F%201?days=7"))
            self.assertEqual(request.call_args.kwargs["response_type"], list)
            c.pearl_history({"walletAddress": WALLET}, Path(root))
            self.assertTrue(request.call_args.args[0].endswith(WALLET + "?days=7"))
            c.pearl_history({"walletAddress": "prl1" + "y" * 59}, Path(root))
            self.assertEqual(request.call_count, 3)
            for path in Path(root).glob("*.json"):
                self.assertNotIn(WALLET, path.read_text())
                self.assertNotIn("rig", path.read_text())
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_history_backoff_and_cached_freshness(self):
        with tempfile.TemporaryDirectory() as root, patch.object(c.time, "time", return_value=self.now), \
                patch.object(c, "request_json", side_effect=c.HTTPFailure(429, retry_after=600)) as request:
            for _ in range(2):
                with self.assertRaises(c.SourceError):
                    c.pearl_history({"walletAddress": WALLET}, Path(root))
            self.assertEqual(request.call_count, 1)
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", return_value=self.history()) as request:
            with patch.object(c.time, "time", return_value=self.now + 1700):
                c.pearl_history({"walletAddress": WALLET}, Path(root))
            with patch.object(c.time, "time", return_value=self.now + 1800), self.assertRaises(c.SourceError):
                c.pearl_history({"walletAddress": WALLET}, Path(root))
            self.assertEqual(request.call_count, 1)

    def test_window_changes_and_old_collector_cache_force_a_refresh(self):
        with tempfile.TemporaryDirectory() as root, patch.object(c.time, "time", return_value=self.now), \
                patch.object(c, "fetch_pearl", return_value={"pearl": {}}) as fetch, \
                patch.object(c, "exchange_rate", return_value=None):
            config = {"walletAddress": WALLET, "averageWindow": "7d"}
            c.collect("pearl", config=config, cache_dir=root)
            c.collect("pearl", config=config, cache_dir=root)
            self.assertEqual(fetch.call_count, 1)
            c.collect("pearl", config={**config, "averageWindow": "3h"}, cache_dir=root)
            self.assertEqual(fetch.call_count, 2)
            path = Path(root) / "pearl.json"
            cached = json.loads(path.read_text())
            cached["configKey"] = cached["configKey"].replace("pearl-pool-v1:", "kryptex-average-v2:")
            path.write_text(json.dumps(cached))
            c.collect("pearl", config={**config, "averageWindow": "3h"}, cache_dir=root)
            self.assertEqual(fetch.call_count, 3)


class WalletTests(unittest.TestCase):
    def setUp(self):
        stub = patch.object(c, "pearl_history", return_value={"hashrate7d": 300e12, "historyUpdatedAt": 1000})
        stub.start()
        self.addCleanup(stub.stop)

    def test_wallet_uses_confirmed_base_units_not_total_received(self):
        result = c.parse_pearl_wallet({"address": WALLET, "balance": "763170958", "totalReceived": "999999999"}, WALLET)
        self.assertAlmostEqual(result["walletBalance"], 7.63170958)
        self.assertEqual(c.parse_pearl_wallet({"address": WALLET, "balance": "0"}, WALLET)["walletBalance"], 0)
        for balance in (None, True, "-1", "7.63", "NaN", 763170958):
            with self.subTest(balance=balance), self.assertRaises(c.SourceError):
                c.parse_pearl_wallet({"address": WALLET, "balance": balance}, WALLET)
        with self.assertRaises(c.SourceError):
            c.parse_pearl_wallet({"address": "other-wallet", "balance": "763170958"}, WALLET)

    def test_wallet_requires_fresh_synchronized_pearl_mainnet_and_known_units(self):
        data = {"blockbook": {"coin": "Pearl", "inSync": True, "initialSync": False, "decimals": 8,
                              "lastBlockTime": 9990}, "backend": {"chain": "mainnet"}}
        with patch.object(c.time, "time", return_value=10000):
            self.assertEqual(c.parse_pearl_chain_status(data)["blockUpdatedAt"], 9990)
            for field, value in (("coin", "Bitcoin"), ("inSync", False), ("initialSync", True),
                                 ("decimals", 18), ("lastBlockTime", 8000), ("lastBlockTime", 10100)):
                with self.subTest(field=field), self.assertRaises(c.SourceError):
                    c.parse_pearl_chain_status({**data, "blockbook": {**data["blockbook"], field: value}})
            with self.assertRaises(c.SourceError):
                c.parse_pearl_chain_status({**data, "backend": {"chain": "testnet"}})

    def test_pool_rewards_keep_confirmed_maturing_and_threshold_distinct(self):
        result = c.parse_pearl_balance({"total": 2.7, "confirmed": .8, "unconfirmed": 1.9, "threshold": 1})
        self.assertEqual(result, {"poolBalance": 2.7, "poolConfirmed": .8, "poolUnconfirmed": 1.9, "payoutThreshold": 1})
        self.assertEqual(c.parse_pearl_balance({"total": 0, "confirmed": 0, "unconfirmed": 0, "threshold": 1})["poolBalance"], 0)
        for override in ({"confirmed": None}, {"total": 5}, {"unconfirmed": -1}, {"threshold": 0}):
            with self.subTest(override=override), self.assertRaises(c.SourceError):
                c.parse_pearl_balance({"total": 2.7, "confirmed": .8, "unconfirmed": 1.9, "threshold": 1, **override})

    def test_recent_payouts_use_received_amount_sort_dates_and_keep_status(self):
        rows = [{"address": WALLET, "date": str(1000 + i), "received": 1.01, "amount": "1.02",
                 "status": "FINISHED", "txid": "%064x" % i} for i in range(7)]
        rows[-1].update(status="PENDING", received=None)
        result = c.parse_pearl_payouts({"results": rows, "count": 200, "next": "page2"}, WALLET)
        self.assertEqual(result["payoutCount"], 200)
        self.assertEqual(len(result["payouts"]), 5)
        self.assertEqual(result["payouts"][0]["date"], 1006)
        self.assertEqual(result["payouts"][0]["status"], "Pending")
        self.assertEqual(result["payouts"][0]["amount"], 1.02)
        self.assertEqual(result["payouts"][1]["amount"], 1.01)
        self.assertEqual(result["payouts"][1]["status"], "Paid")
        self.assertEqual(len({row["id"] for row in result["payouts"]}), 5)
        self.assertNotIn(WALLET, json.dumps(result))

    def test_payout_links_only_use_valid_transaction_ids_and_unknown_status_stays_unknown(self):
        result = c.parse_pearl_payouts({"count": 1, "results": [{"date": 1000, "received": 1,
                                      "status": "UNRECOGNIZED", "txid": "https://bad.example"}]}, WALLET)
        self.assertIsNone(result["payouts"][0]["txid"])
        self.assertEqual(result["payouts"][0]["status"], "Unknown")

    def test_missing_history_never_means_no_payouts(self):
        self.assertEqual(c.parse_pearl_payouts({"count": 0, "results": []}, WALLET), {"payoutCount": 0, "payouts": []})
        for data in ({}, {"count": 1, "results": []}, {"count": -1, "results": []},
                     {"count": 1, "results": [{"date": 1000, "amount": 1, "status": "FINISHED"}]},
                     {"count": 1, "results": [{"date": "bad", "received": 1}]},
                     {"count": 1, "results": [{"date": 1000, "received": -1}]},
                     {"count": 1, "results": [{"address": "another-wallet", "date": 1000, "received": 1}]}):
            with self.subTest(data=data), self.assertRaises(c.SourceError):
                c.parse_pearl_payouts(data, WALLET)

    def test_all_time_paid_uses_stats_not_recent_history(self):
        self.assertEqual(c.parse_pearl_paid({"paid": "50.125", "unpaid": 2}), {"totalPaid": 50.125})
        self.assertEqual(c.parse_pearl_paid({"paid": 0}), {"totalPaid": 0})
        for value in (None, -1, "NaN", True):
            with self.assertRaises(c.SourceError):
                c.parse_pearl_paid({"paid": value})

    def test_explorer_failure_preserves_pool_balances_payouts_and_mining(self):
        with tempfile.TemporaryDirectory() as root, \
                patch.object(c, "pearl_price", return_value={"priceUSD": 1, "updatedAt": 1000}), \
                patch.object(c, "pearl_workers", return_value={"hashrate": 300e12, "supportsPPS": True}), \
                patch.object(c, "pearl_pool", return_value={"ticker": "prl", "estimated_profit_day": 2e-14, "fee": .02}), \
                patch.object(c, "pearl_wallet", side_effect=c.SourceError("Explorer unavailable.")), \
                patch.object(c, "pearl_balance", return_value={"poolBalance": 2}), \
                patch.object(c, "pearl_payouts", return_value={"payouts": [], "payoutCount": 0}), \
                patch.object(c, "pearl_paid", return_value={"totalPaid": 7}):
            result = c.fetch_pearl({**KRYPTEX}, Path(root))
        self.assertEqual(result["status"], "partial")
        self.assertNotIn("walletBalance", result["pearl"])
        self.assertEqual(result["pearl"]["poolBalance"], 2)
        self.assertEqual(result["pearl"]["totalPaid"], 7)
        self.assertAlmostEqual(result["pearl"]["coinsPerDay"], 5.88)

    def test_pool_failure_preserves_onchain_balance(self):
        with tempfile.TemporaryDirectory() as root, \
                patch.object(c, "pearl_price", return_value={"priceUSD": 1, "updatedAt": 1000}), \
                patch.object(c, "pearl_workers", side_effect=c.SourceError("Unavailable.")), \
                patch.object(c, "pearl_pool", side_effect=c.SourceError("Unavailable.")), \
                patch.object(c, "pearl_wallet", return_value={"walletBalance": 7}), \
                patch.object(c, "pearl_balance", side_effect=c.SourceError("Unavailable.")), \
                patch.object(c, "pearl_payouts", side_effect=c.SourceError("Unavailable.")), \
                patch.object(c, "pearl_paid", side_effect=c.SourceError("Unavailable.")):
            result = c.fetch_pearl({**KRYPTEX}, Path(root))
        self.assertEqual(result["pearl"]["walletBalance"], 7)
        self.assertNotIn("payouts", result["pearl"])
        self.assertNotIn("poolBalance", result["pearl"])

    def test_account_cache_is_wallet_scoped_and_does_not_cache_addresses(self):
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", return_value={"paid": 7}) as request:
            c.pearl_paid({"walletAddress": WALLET, "workerName": "one"}, Path(root))
            c.pearl_paid({"walletAddress": WALLET, "workerName": "two"}, Path(root))
            self.assertEqual(request.call_count, 1)
            c.pearl_paid({"walletAddress": "prl1" + "y" * 59}, Path(root))
            self.assertEqual(request.call_count, 2)
            for path in Path(root).glob("*.json"):
                self.assertNotIn(WALLET, path.read_text())
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_balance_backoff_is_independent_of_history(self):
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=c.HTTPFailure(429, retry_after=600)) as request:
            for _ in range(2):
                with self.assertRaises(c.SourceError): c.pearl_balance({"walletAddress": WALLET}, Path(root))
            self.assertEqual(request.call_count, 1)
            request.side_effect = None
            request.return_value = {"count": 0, "results": []}
            self.assertEqual(c.pearl_payouts({"walletAddress": WALLET}, Path(root))["payouts"], [])


NOW = 1_800_000_000  # On the hour.
SHORT = WALLET[:10] + "..." + WALLET[-8:]  # How PF Pool echoes most addresses.
PF_MODE = {"bridge_configured": True, "bridge": {"address": WALLET, "payment_mode": "pps", "pps_fee_rate": .03}}
PF_SUMMARY = {"chain": "pearl", "pool_stats": {"rolling_stats": [
    {"hours": 0, "yield": 2e-8, "theoretical_yield": 2e-8}, {"hours": 1, "yield": 9e-8, "theoretical_yield": 3e-8}]}}


def pf_shares(to=NOW, **overrides):
    rows = [{"hours": hours, "hashrate": rate, "share_statistics": {"from": to - hours * 3600, "to": to}}
            for hours, rate in ((1, 330e12), (8, 320e12), (24, 310e12))]
    return {"miner_address": SHORT, "rolling_hashrates": rows, **overrides}


def pf_connections(*stale, **overrides):
    return {"configured": True, "address": SHORT, "workers": [
        {"worker": "rtx4090", "stale": value, "reported_hashrate": 330e12} for value in stale], **overrides}


def pf_history(rates=None, end=NOW + 1800):
    """Hourly buckets as PF Pool reports them: 168 full hours plus the current partial hour."""
    first = end - end % 3600 - 168 * 3600
    rows = []
    for index in range(169):
        start = first + index * 3600
        finish = min(start + 3600, end)
        rows.append({"hour": start, "share_statistics": {
            "from": start, "to": finish, "effective_hashrate": rates[index] if rates else 300e12,
            "observed_ms": (finish - start) * 1000, "complete": True}})
    return {"miner_address": SHORT, "series": rows}


def pf_balance(**overrides):
    return {"address": WALLET, "atomic_units_per_coin": "100000000", "immature_q64": str(50_000_000 * 2 ** 64),
            "remainder_q64": str(2 ** 63), "balance_atomic": "25000000", **overrides}


def pf_payout(index, **overrides):
    return {"entry_type": "payout", "amount_atomic": str(100_000_000 + index), "status": "confirmed",
            "event_time": "2026-10-2%dT12:00:00+08:00" % index, "tx_hash": "%064x" % index,
            "to_address": SHORT, **overrides}


def pf_ledger(rows=None, total=None, paid="1234567890"):
    rows = [pf_payout(index) for index in range(7)] if rows is None else rows
    return {"miner_address": SHORT, "entries": rows, "total": len(rows) if total is None else total,
            "sum_payout_amount_atomic": paid}


def pf_router(history=None, mode=None, requested=None):
    def respond(url):
        if requested is not None:
            requested.append(url)
        routes = {"/hourly-shares?hours=24": pf_shares(NOW + 1800), "/hourly-shares?hours=168": history or pf_history(),
                  "/connections": pf_connections(False), "/address-mode": mode or PF_MODE,
                  "/pps?status=pending": pf_balance(), "/ledger?page=1&page_size=5&entry_type=payout": pf_ledger(),
                  "/summary?hours=24": PF_SUMMARY}
        for path, data in routes.items():
            if url.endswith(path):
                return {"data": data}
        raise AssertionError("Unexpected request " + url)
    return respond


class PFPoolTests(unittest.TestCase):
    def setUp(self):
        for name, value in (("pearl_price", {"priceUSD": 1.5, "updatedAt": NOW}), ("pearl_wallet", {"walletBalance": 7})):
            stub = patch.object(c, name, return_value=value)
            stub.start()
            self.addCleanup(stub.stop)

    def test_shortened_addresses_must_match_the_saved_wallet(self):
        self.assertTrue(c.pfpool_address(WALLET, WALLET))
        self.assertTrue(c.pfpool_address(SHORT, WALLET))
        other = "prl1" + "y" * 59
        for reported in (other, other[:10] + "..." + other[-8:], "prl1x..." + WALLET[-8:], SHORT[:-12] + "...xxxxx",
                         "prl1xxxxxx...", None, 7):
            with self.subTest(reported=reported):
                self.assertFalse(c.pfpool_address(reported, WALLET))

    def test_rolling_averages_cover_the_address_and_count_connected_workers(self):
        with patch.object(c.time, "time", return_value=NOW + 60):
            result = c.parse_pfpool_hashrate(pf_shares(), pf_connections(False, True), WALLET)
            self.assertEqual(result, {"hashrate1h": 330e12, "hashrate8h": 320e12, "hashrate24h": 310e12,
                                      "onlineWorkers": 1, "workerCount": 2})
            self.assertNotIn("rtx4090", json.dumps(result))
            # PF Pool lists only connected sessions; without one the current rate is zero.
            for connections in (pf_connections(), pf_connections(True), pf_connections(workers=None)):
                offline = c.parse_pfpool_hashrate(pf_shares(), connections, WALLET)
                self.assertEqual(offline["hashrate1h"], 0)
                self.assertEqual(offline["hashrate24h"], 310e12)
                self.assertEqual(offline["onlineWorkers"], 0)

    def test_hashrate_rejects_other_addresses_missing_current_rate_and_stale_data(self):
        shares = pf_shares()
        with patch.object(c.time, "time", return_value=NOW + 60):
            for bad_shares, connections in (
                    (pf_shares(miner_address="prl1yyyyyy...yyyyyyyy"), pf_connections(False)),
                    (shares, pf_connections(False, address="prl1yyyyyy...yyyyyyyy")),
                    (shares, pf_connections(False, configured=False)),
                    (shares, pf_connections(workers=[{"worker": "rtx4090"}])),
                    (pf_shares(rolling_hashrates=None), pf_connections(False)),
                    (pf_shares(rolling_hashrates=[{"hours": 1, "hashrate": 1}]), pf_connections(False)),
                    (pf_shares(rolling_hashrates=shares["rolling_hashrates"][1:]), pf_connections(False))):
                with self.subTest(shares=str(bad_shares)[:60], connections=str(connections)[:60]), \
                        self.assertRaises(c.SourceError):
                    c.parse_pfpool_hashrate(bad_shares, connections, WALLET)
            for value in (-1, None, True, "nan", "Infinity", []):
                bad = pf_shares()
                bad["rolling_hashrates"][0]["hashrate"] = value
                with self.subTest(value=value), self.assertRaises(c.SourceError):
                    c.parse_pfpool_hashrate(bad, pf_connections(False), WALLET)
            longer = pf_shares()
            longer["rolling_hashrates"][1]["hashrate"] = None
            self.assertIsNone(c.parse_pfpool_hashrate(longer, pf_connections(False), WALLET)["hashrate8h"])
        with patch.object(c.time, "time", return_value=NOW + 1800), self.assertRaises(c.SourceError):
            c.parse_pfpool_hashrate(shares, pf_connections(False), WALLET)

    def test_week_clips_the_first_hour_and_counts_hours_before_mining_as_zero(self):
        with patch.object(c.time, "time", return_value=NOW + 1860):
            self.assertEqual(c.parse_pfpool_history(pf_history(), WALLET),
                             {"hashrate7d": 300e12, "historyUpdatedAt": NOW + 1800})
            # Only the last half of the oldest hour falls inside the seven days.
            rates = [900e12] + [300e12] * 168
            self.assertAlmostEqual(c.parse_pfpool_history(pf_history(rates), WALLET)["hashrate7d"],
                                   300e12 + 600e12 * 0.5 / 168, delta=1)
            # Mining here for the last 83.5 of 168 hours.
            rates = [0] * 85 + [300e12] * 84
            self.assertAlmostEqual(c.parse_pfpool_history(pf_history(rates), WALLET)["hashrate7d"],
                                   300e12 * 83.5 / 168, delta=1)
            # An hour that has only just begun is ignored, and partly observed hours keep the pool's rate.
            data = pf_history()
            data["series"][5]["share_statistics"]["observed_ms"] = 3_593_000
            data["series"].append({"share_statistics": {"from": NOW + 1800, "to": NOW + 1800, "effective_hashrate": 0,
                                                        "observed_ms": 0}})
            self.assertEqual(c.parse_pfpool_history(data, WALLET)["hashrate7d"], 300e12)

    def test_week_rejects_gaps_overlaps_unobserved_short_stale_and_malformed_history(self):
        def changed(index, **fields):
            data = pf_history()
            data["series"][index]["share_statistics"].update(fields)
            return data
        gap = pf_history()
        del gap["series"][80]
        short = pf_history()
        del short["series"][0]
        cases = [gap, short, changed(80, to=NOW - 80 * 3600), changed(80, observed_ms=0),
                 changed(80, effective_hashrate=-1), changed(80, effective_hashrate=None),
                 changed(80, effective_hashrate=True), changed(80, effective_hashrate="nan"),
                 changed(80, **{"from": None}), changed(80, to=0), {"miner_address": SHORT, "series": None},
                 {"miner_address": SHORT, "series": [None, None]}, {**pf_history(), "miner_address": "prl1y...yyyyyy"}]
        with patch.object(c.time, "time", return_value=NOW + 1860):
            for data in cases:
                with self.subTest(case=str(data)[:80]), self.assertRaises(c.SourceError):
                    c.parse_pfpool_history(data, WALLET)
        with patch.object(c.time, "time", return_value=NOW + 3600), self.assertRaises(c.SourceError):
            c.parse_pfpool_history(pf_history(), WALLET)

    def test_yield_uses_current_theoretical_rate_and_the_address_pps_fee(self):
        self.assertEqual(c.parse_pfpool_yield(PF_SUMMARY), {"yieldPerHashDay": 2e-14})
        for data in ({**PF_SUMMARY, "chain": "nock-ai"}, {"chain": "pearl"},
                     {"chain": "pearl", "pool_stats": {"rolling_stats": [{"hours": 0, "theoretical_yield": 0}]}},
                     {"chain": "pearl", "pool_stats": {"rolling_stats": [{"hours": 1, "theoretical_yield": 2e-8}]}}):
            with self.subTest(data=data), self.assertRaises(c.SourceError):
                c.parse_pfpool_yield(data)
        self.assertEqual(c.parse_pfpool_mode(PF_MODE, WALLET), {"scheme": "pps", "fee": .03})
        for bridge in ({"address": SHORT}, {"payment_mode": "solo"}, {"pps_fee_rate": 1}, {"pps_fee_rate": None}):
            with self.subTest(bridge=bridge), self.assertRaises(c.SourceError):
                c.parse_pfpool_mode({**PF_MODE, "bridge": {**PF_MODE["bridge"], **bridge}}, WALLET)
        coins, fee = c.pfpool_coins({"yieldPerHashDay": 2e-14, "fee": .03}, 300e12)
        self.assertAlmostEqual(coins, 5.82)
        self.assertEqual(fee, 3)

    def test_balance_splits_maturing_income_from_the_payable_balance(self):
        result = c.parse_pfpool_balance(pf_balance(), WALLET)
        self.assertEqual(result["poolUnconfirmed"], .5)
        self.assertAlmostEqual(result["poolConfirmed"], .25 + .5e-8)
        self.assertAlmostEqual(result["poolBalance"], .75 + .5e-8)
        self.assertNotIn("payoutThreshold", result)
        empty = c.parse_pfpool_balance(pf_balance(immature_q64="0", remainder_q64="0", balance_atomic="0"), WALLET)
        self.assertEqual(empty["poolBalance"], 0)
        for override in ({"address": SHORT}, {"atomic_units_per_coin": "65536"}, {"immature_q64": "-1"},
                         {"balance_atomic": "0.5"}, {"balance_atomic": 25000000}, {"remainder_q64": None}):
            with self.subTest(override=override), self.assertRaises(c.SourceError):
                c.parse_pfpool_balance(pf_balance(**override), WALLET)

    def test_payouts_keep_pool_status_newest_first_with_all_time_total(self):
        rows = [pf_payout(index) for index in range(7)]
        rows[6].update(status="submitted")
        rows[5].update(status="needs_review", tx_hash="https://bad.example")
        rows[4].update(status="onchain_failed")
        result = c.parse_pfpool_payouts(pf_ledger(rows, total=40), WALLET)
        self.assertEqual(result["payoutCount"], 40)
        self.assertEqual(result["totalPaid"], 12.3456789)
        self.assertEqual([row["status"] for row in result["payouts"]], ["Sent", "Needs review", "Failed", "Paid", "Paid"])
        self.assertEqual(result["payouts"][0]["amount"], 1.00000006)
        self.assertEqual(result["payouts"][0]["txid"], "%064x" % 6)
        self.assertIsNone(result["payouts"][1]["txid"])
        self.assertEqual(result["payouts"][0]["date"], c.timestamp("2026-10-26T12:00:00+08:00"))
        self.assertEqual(len({row["id"] for row in result["payouts"]}), 5)
        self.assertNotIn("prl1", json.dumps(result))
        self.assertEqual(c.parse_pfpool_payouts({**pf_ledger([]), "entries": None}, WALLET),
                         {"payouts": [], "payoutCount": 0, "totalPaid": 12.3456789})
        self.assertEqual(c.parse_pfpool_payouts(pf_ledger([pf_payout(1, status="new")]), WALLET)["payouts"][0]["status"], "Unknown")

    def test_missing_ledger_never_means_no_payouts(self):
        for data in ({}, pf_ledger([], total=3), {**pf_ledger([], total=1), "entries": None}, pf_ledger(total=2),
                     pf_ledger(paid=None), pf_ledger(paid="-1"), pf_ledger([pf_payout(1, entry_type="credit")]),
                     pf_ledger([pf_payout(1, to_address="prl1yyyyyy...yyyyyyyy")]),
                     pf_ledger([pf_payout(1, amount_atomic="1.5")]), pf_ledger([pf_payout(1, event_time="soon")]),
                     {**pf_ledger(), "miner_address": "prl1yyyyyy...yyyyyyyy"}):
            with self.subTest(data=str(data)[:90]), self.assertRaises(c.SourceError):
                c.parse_pfpool_payouts(data, WALLET)

    def test_selected_average_drives_headline_and_pps_projection(self):
        for window, expected in ((None, 300e12), ("1h", 330e12), ("8h", 320e12), ("24h", 310e12), ("7d", 300e12)):
            requested = []
            with self.subTest(window=window), tempfile.TemporaryDirectory() as root, \
                    patch.object(c.time, "time", return_value=NOW + 1860), \
                    patch.object(c, "request_json", side_effect=pf_router(requested=requested)):
                config = {"walletAddress": WALLET, "workerName": "rtx4090"}
                if window is not None:
                    config["averageWindow"] = window
                result = c.fetch_pearl(config, Path(root))
                for path in Path(root).glob("*.json"):
                    self.assertNotIn(WALLET, path.read_text())
                    self.assertNotIn("rtx4090", path.read_text())
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertNotIn("error", result)
            pearl = result["pearl"]
            self.assertEqual((pearl["pool"], pearl["averageWindow"]), ("pfpool", window or "7d"))
            self.assertEqual(pearl["hashrate"], expected)
            self.assertEqual((pearl["hashrate1h"], pearl["hashrate7d"]), (330e12, 300e12))
            self.assertAlmostEqual(pearl["coinsPerDay"], expected * 2e-14 * .97)
            self.assertEqual(pearl["poolFeePercent"], 3)
            self.assertEqual((pearl["poolUnconfirmed"], pearl["payoutCount"], pearl["walletBalance"]), (.5, 7, 7))
            self.assertEqual(pearl["totalPaid"], 12.3456789)
            self.assertTrue(all(url.startswith("https://pearlfortune.org/api/v1/") for url in requested))
            self.assertEqual(len(requested), 7)

    def test_kryptex_averages_are_not_offered_on_pf_pool_and_unknown_pools_are_rejected(self):
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json") as request:
            for config in ({"walletAddress": WALLET, "averageWindow": "30m"}, {**KRYPTEX, "averageWindow": "8h"},
                           {"walletAddress": WALLET, "pool": "other"}):
                with self.subTest(config=config), self.assertRaises(c.SourceError):
                    c.fetch_pearl(config, Path(root))
            request.assert_not_called()

    def test_pplns_mode_keeps_hashrate_without_pps_projections(self):
        mode = {**PF_MODE, "bridge": {**PF_MODE["bridge"], "payment_mode": "pplns"}}
        with tempfile.TemporaryDirectory() as root, patch.object(c.time, "time", return_value=NOW + 1860), \
                patch.object(c, "request_json", side_effect=pf_router(mode=mode)):
            result = c.fetch_pearl({"walletAddress": WALLET, "averageWindow": "1h"}, Path(root))
        self.assertEqual(result["pearl"]["hashrate"], 330e12)
        self.assertNotIn("coinsPerDay", result["pearl"])
        self.assertIn("PPS payment mode", result["error"])

    def test_unavailable_week_only_flags_a_weekly_selection(self):
        stale = pf_history(end=NOW - 3600)
        for window in ("1h", "7d"):
            with self.subTest(window=window), tempfile.TemporaryDirectory() as root, \
                    patch.object(c.time, "time", return_value=NOW + 1860), \
                    patch.object(c, "request_json", side_effect=pf_router(history=stale)):
                result = c.fetch_pearl({"walletAddress": WALLET, "averageWindow": window}, Path(root))
            self.assertEqual(result["pearl"]["hashrate1h"], 330e12)
            self.assertNotIn("hashrate7d", result["pearl"])
            if window == "7d":
                self.assertEqual(result["status"], "partial")
                self.assertNotIn("hashrate", result["pearl"])
            else:
                self.assertNotIn("error", result)

    def test_pool_outage_preserves_price_and_wallet(self):
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=c.SourceError("Down.")):
            result = c.fetch_pearl({"walletAddress": WALLET}, Path(root))
        self.assertEqual(result["status"], "partial")
        self.assertEqual((result["pearl"]["priceUSD"], result["pearl"]["walletBalance"]), (1.5, 7))
        for key in ("hashrate", "poolBalance", "payouts", "coinsPerDay"):
            self.assertNotIn(key, result["pearl"])

    def test_unknown_address_backoff_and_shared_cache_for_every_worker(self):
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=c.HTTPFailure(400)) as request:
            for _ in range(2):
                with self.assertRaisesRegex(c.SourceError, "does not recognize"):
                    c.pfpool_hashrate({"walletAddress": WALLET}, Path(root))
            # One attempt sends the averages and connections requests together; the retry waits.
            self.assertEqual(request.call_count, 2)
        with tempfile.TemporaryDirectory() as root, patch.object(c.time, "time", return_value=NOW + 1860), \
                patch.object(c, "request_json", side_effect=pf_router()) as request:
            c.pfpool_hashrate({"walletAddress": WALLET, "workerName": "one"}, Path(root))
            c.pfpool_hashrate({"walletAddress": WALLET, "workerName": "two"}, Path(root))
            self.assertEqual(request.call_count, 2)
            self.assertIn("/miners/" + WALLET + "/connections", request.call_args.args[0])
            # The fixture answers for WALLET, so another address fails its identity check.
            with self.assertRaises(c.SourceError):
                c.pfpool_hashrate({"walletAddress": "prl1" + "y" * 59}, Path(root))
            self.assertEqual(request.call_count, 4)

    def test_paired_requests_run_side_by_side_and_invalid_addresses_make_none(self):
        # Requests made one after another would never meet at the barrier.
        barrier, router = threading.Barrier(2, timeout=5), pf_router()

        def respond(url):
            barrier.wait()
            return router(url)
        with tempfile.TemporaryDirectory() as root, patch.object(c.time, "time", return_value=NOW + 1860), \
                patch.object(c, "request_json", side_effect=respond):
            self.assertEqual(c.pfpool_hashrate({"walletAddress": WALLET}, Path(root))["onlineWorkers"], 1)
            self.assertTrue(c.pfpool_yield({"walletAddress": WALLET}, Path(root))["supportsPPS"])
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json") as request:
            for loader in (c.pfpool_hashrate, c.pfpool_history, c.pfpool_yield, c.pfpool_balance, c.pfpool_payouts):
                with self.subTest(loader=loader.__name__), self.assertRaises(c.SourceError):
                    loader({"walletAddress": "prl1/../../"}, Path(root))
            request.assert_not_called()

    def test_pool_link_follows_the_selection_and_switching_pools_refreshes(self):
        with tempfile.TemporaryDirectory() as root, patch.object(c, "exchange_rate", return_value=None), \
                patch.object(c, "fetch_pearl", return_value={"pearl": {}}) as fetch:
            result = c.collect("pearl", config={"walletAddress": WALLET}, cache_dir=root)
            self.assertEqual((result["url"], result["source"]),
                             ("https://pearlfortune.org/", "PF Pool · Pearl explorer · CoinGecko"))
            fetch.side_effect = c.SourceError("Unavailable.")
            result = c.collect("pearl", config=dict(KRYPTEX), cache_dir=root)
            self.assertEqual(fetch.call_count, 2)
            self.assertEqual(result["url"], "https://pool.kryptex.com/prl")
            self.assertTrue(result["source"].startswith("Kryptex"))

    def test_requests_to_pf_pool_are_allowed_without_credentials(self):
        opener = MagicMock()
        opener.open.return_value.__enter__.return_value.read.return_value = b'{"data": {}}'
        with patch.object(c.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(c.request_json("https://pearlfortune.org/api/v1/config"), {"data": {}})
            with self.assertRaises(c.SourceError):
                c.request_json("https://pearlfortune.org.example.com/api/v1/config")
        self.assertFalse(opener.open.call_args[0][0].has_header("Authorization"))


class PowerTests(unittest.TestCase):
    def test_homewizard_versions_zero_and_export(self):
        self.assertEqual(c.parse_homewizard({"active_power_w": 448}, "v1"), 448)
        self.assertEqual(c.parse_homewizard({"power_w": 0}, "v2"), 0)
        self.assertEqual(c.parse_homewizard({"power_w": -200}, "v2"), -200)
        for data in ({}, {"power_w": None}, {"power_w": "NaN"}, {"power_w": True}):
            with self.assertRaises(c.SourceError): c.parse_homewizard(data, "v2")

    def test_offline_meter_does_not_drop_healthy_meter(self):
        devices = [{"id": "a", "name": "Miner", "address": "a.local"}, {"id": "b", "address": "b.local"}]
        with patch.object(c, "local_json", side_effect=[{"active_power_w": 450}, c.SourceError("Offline.")]):
            result = c.fetch_power({"devices": devices}, {})
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["powerDevices"][0]["watts"], 450)
        self.assertEqual(result["powerDevices"][1]["status"], "error")
        self.assertNotIn("watts", result["powerDevices"][1])

    def test_connection_change_invalidates_cache_without_persisting_tokens_or_urls(self):
        with tempfile.TemporaryDirectory() as root, patch.object(c, "exchange_rate", return_value=None), \
                patch.object(c, "local_json", return_value={"active_power_w": 450}) as read:
            config = {"devices": [{"id": "a", "address": "192.168.1.18"}]}
            c.collect("power", cache_dir=root, config=config, device_tokens={"a": "private-token"})
            c.collect("power", cache_dir=root, config=config, device_tokens={"a": "private-token"})
            self.assertEqual(read.call_count, 1)
            config["devices"][0]["address"] = "192.168.1.19"
            c.collect("power", cache_dir=root, config=config, device_tokens={"a": "replacement-token"})
            self.assertEqual(read.call_count, 2)
            raw = (Path(root) / "power.json").read_text()
            for hidden in ("private-token", "replacement-token", "192.168.1.18", "192.168.1.19"):
                self.assertNotIn(hidden, raw)
            self.assertEqual((Path(root) / "power.json").stat().st_mode & 0o777, 0o600)

    def test_only_explicit_local_urls_without_embedded_credentials_are_accepted(self):
        for url in ("https://example.com", "file:///etc/passwd", "http://user:secret@127.0.0.1", "http://127.0.0.1/?token=secret", "http://0.0.0.0", "http://224.0.0.1"):
            with self.subTest(url=url), self.assertRaises(c.SourceError): c.local_endpoint(url)
        with self.assertRaises(c.SourceError): c.local_endpoint("http://127.0.0.1/api/measurement", "/api/measurement", "https")
        self.assertEqual(c.local_endpoint("127.0.0.1", "/api/v1/data", "http")[3], "/api/v1/data")

    def test_real_http_connection_reads_watts_and_refuses_redirect(self):
        paths = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                paths.append(self.path)
                if self.path == "/redirect":
                    self.send_response(302)
                    self.send_header("Location", "/secret")
                    self.end_headers()
                else:
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'{"active_power_w":448}')
            def log_message(self, *_): pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = "http://127.0.0.1:%d" % server.server_port
        try:
            self.assertEqual(c.local_json(url, path="/api/v1/data", version="v1"), {"active_power_w": 448})
            with self.assertRaises(c.SourceError): c.local_json(url + "/redirect")
            self.assertEqual(paths, ["/api/v1/data", "/redirect"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_v2_uses_device_identity_and_bundled_ca_before_sending_token(self):
        with patch.object(c.ssl, "create_default_context") as context, patch.object(c.http.client, "HTTPConnection") as connection:
            response = connection.return_value.getresponse.return_value
            response.status = 200
            response.read.return_value = b'{"power_w":450}'
            result = c.local_json("127.0.0.1", version="v2", path="/api/measurement", token="sample-token",
                                  certificate_name="appliance/p1dongle/aabbccddeeff")
            self.assertEqual(result["power_w"], 450)
            self.assertTrue(context.call_args.kwargs["cafile"].endswith("homewizard-ca.pem"))
            self.assertEqual(context.return_value.wrap_socket.call_args.kwargs["server_hostname"], "appliance/p1dongle/aabbccddeeff")
            self.assertEqual(connection.return_value.request.call_args.kwargs["headers"]["Authorization"], "Bearer sample-token")


if __name__ == "__main__": unittest.main()
