import json
from pathlib import Path
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

from test_collect import c

WALLET = "prl1" + "x" * 59


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
            result = c.fetch_pearl({"walletAddress": WALLET}, Path(root))
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["pearl"]["priceUSD"], 1.1)
        self.assertNotIn("hashrate", result["pearl"])
        self.assertNotIn("coinsPerDay", result["pearl"])

    def test_price_failure_preserves_pool_hashrate_and_token_yield_without_local_requests(self):
        def response(url):
            return {"results": [pool_worker()]} if "/workers/" in url else {"ticker": "prl", "estimated_profit_day": 2e-14, "fee": .02}
        with tempfile.TemporaryDirectory() as root, patch.object(c, "pearl_price", side_effect=c.SourceError("Price unavailable.")), \
                patch.object(c, "local_json") as local, patch.object(c, "request_json", side_effect=response):
            result = c.fetch_pearl({"walletAddress": WALLET, "minerURL": "http://retired.local", "minerFeePercent": 2}, Path(root))
            local.assert_not_called()
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["pearl"]["hashrate"], 300e12)
        self.assertNotIn("priceUSD", result["pearl"])
        self.assertAlmostEqual(result["pearl"]["coinsPerDay"], 5.88)

    def test_non_pps_workers_keep_hashrate_without_pps_projections(self):
        workers = c.parse_pool_workers({"results": [pool_worker(scheme="solo")]}, WALLET)
        with tempfile.TemporaryDirectory() as root, patch.object(c, "pearl_price", return_value={"priceUSD": 1.1, "updatedAt": 1000}), \
                patch.object(c, "pearl_workers", return_value=workers):
            result = c.fetch_pearl({"walletAddress": WALLET}, Path(root))
        self.assertEqual(result["pearl"]["hashrate"], 300e12)
        self.assertNotIn("coinsPerDay", result["pearl"])
        self.assertIn("PPS+", result["error"])

    def test_selected_average_drives_headline_and_yield_with_week_as_default(self):
        for window, expected in ((None, 300e12), ("30m", 400e12), ("3h", 290e12), ("24h", 280e12), ("7d", 300e12)):
            with self.subTest(window=window), tempfile.TemporaryDirectory() as root, \
                    patch.object(c, "pearl_price", return_value={"priceUSD": 1, "updatedAt": 1000}), \
                    patch.object(c, "pearl_workers", return_value=c.parse_pool_workers(
                        {"results": [pool_worker(avg_hashrate_30m=400e12)]}, WALLET)):
                config = {"walletAddress": WALLET}
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
                result = c.fetch_pearl({"walletAddress": WALLET, "averageWindow": window}, Path(root))
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
            result = c.fetch_pearl({"walletAddress": WALLET}, Path(root))
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
            cached["configKey"] = cached["configKey"].replace("kryptex-average-v2:", "kryptex-wallet-v1:")
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
            result = c.fetch_pearl({"walletAddress": WALLET}, Path(root))
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
            result = c.fetch_pearl({"walletAddress": WALLET}, Path(root))
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
