import email.message
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, Mock, patch
import urllib.error

spec = importlib.util.spec_from_file_location("collect", Path(__file__).parents[1] / "scripts/collect.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


def earnings(day, amount, referral=0):
    return {"day": day, "gpu_earn": amount, "sto_earn": 0, "bwu_earn": 0, "bwd_earn": 0, "referral_earn": referral, "total_earn": amount + referral}


def machine(**overrides):
    return {"id": 1, "hostname": "test-host", "gpu_name": "RTX 5090", "num_gpus": 1,
            "current_rentals_running": 1, "current_rentals_resident": 1,
            "gpu_occupancy": "D ", "listed": True, "listed_gpu_cost": 0.6, **overrides}


class SubscriptionTests(unittest.TestCase):
    def test_codex_weekly_primary_and_extra_bucket(self):
        result = c.parse_codex({"rateLimitsByLimitId": {
            "codex": {"planType": "pro", "primary": {"usedPercent": 15, "windowDurationMins": 10080, "resetsAt": 1800000000}},
            "other": {"limitName": "Additional model", "primary": {"usedPercent": 0, "windowDurationMins": 300}}}})
        self.assertEqual(result["windows"][0]["label"], "Weekly")
        self.assertEqual(result["windows"][1]["usedPercent"], 0)
        self.assertEqual(result["plan"], "Pro")

    def test_codex_legacy_response(self):
        result = c.parse_codex({"rateLimits": {"primary": {"usedPercent": 29, "windowDurationMins": 300}}})
        self.assertEqual(result["windows"][0]["label"], "5-hour")

    def test_no_codex_allowance_is_not_zero(self):
        with self.assertRaises(c.SourceError): c.parse_codex({})
        with self.assertRaises(c.SourceError): c.parse_codex({"rateLimits": {"primary": None}})

    def test_claude_iso_and_absent_optional_windows(self):
        data = {"five_hour": {"utilization": 14, "resets_at": "2026-09-09T13:10:00.094830+00:00"}, "seven_day": None}
        result = c.parse_claude(data, "max")
        self.assertEqual(len(result["windows"]), 1)
        self.assertGreater(result["windows"][0]["resetAt"], 1788000000)

    def test_claude_model_scoped_limits_are_shown_once(self):
        data = {"five_hour": {"utilization": 15, "resets_at": "2026-09-10T12:40:00+00:00"},
                "seven_day": {"utilization": 19, "resets_at": "2026-09-11T05:00:00+00:00"},
                "seven_day_sonnet": {"utilization": 3, "resets_at": None},
                "limits": [{"kind": "session", "percent": 15, "resets_at": "2026-09-10T12:40:00+00:00", "scope": None},
                           {"kind": "weekly_all", "percent": 19, "resets_at": "2026-09-11T05:00:00+00:00", "scope": None},
                           {"kind": "weekly_scoped", "percent": 36, "resets_at": "2026-09-11T05:00:00+00:00", "scope": {"model": {"display_name": "Fable", "id": None}, "surface": None}},
                           {"kind": "weekly_scoped", "percent": 8, "resets_at": None, "scope": {"model": {"display_name": "Sonnet"}, "surface": None}},
                           {"kind": "weekly_scoped", "percent": 2, "resets_at": None, "scope": {"model": None, "surface": "cowork"}},
                           {"kind": "mystery", "percent": 50}, "not-a-limit"]}
        result = c.parse_claude(data, "max")
        self.assertEqual([(w["id"], w["usedPercent"], w["main"]) for w in result["windows"]],
                         [("five_hour", 15, True), ("seven_day", 19, True), ("seven_day_sonnet", 3, True),
                          ("seven_day_fable", 36, True), ("seven_day_cowork", 2, False)])
        self.assertEqual(result["windows"][3]["label"], "Fable · weekly")
        self.assertEqual(result["windows"][3]["resetAt"], 1789102800)

    def test_cursor_two_pools_not_combined(self):
        result = c.parse_cursor({"billingCycleStart": "1797408000000", "billingCycleEnd": "1800000000000", "planUsage": {"autoPercentUsed": 7.5, "apiPercentUsed": 100, "totalPercentUsed": 22.4}}, "enterprise")
        self.assertEqual([w["usedPercent"] for w in result["windows"]], [7.5, 100])
        self.assertEqual(result["windows"][0]["resetAt"], 1800000000)
        self.assertEqual(result["billingStart"], 1797408000)
        self.assertEqual(result["billingEnd"], 1800000000)

    def test_cursor_legacy_and_no_allowance(self):
        result = c.parse_cursor({"planUsage": {"includedSpend": 1000, "limit": 2000}})
        self.assertEqual(result["windows"][0]["usedPercent"], 50)
        with self.assertRaises(c.SourceError): c.parse_cursor({"planUsage": {"limit": 0}})

    def test_zero_is_real_and_overage_is_not_clamped(self):
        self.assertEqual(c.window("x", "x", 0, None)["usedPercent"], 0)
        self.assertEqual(c.window("x", "x", 125, None)["usedPercent"], 125)
        for value in (None, -1, "nan", "Infinity", True, "invalid"):
            self.assertIsNone(c.window("x", "x", value, None))


class VastTests(unittest.TestCase):
    def test_seven_complete_days_including_idle_days(self):
        result = c.parse_earnings({"rows": [earnings(100, 500), earnings(99, 7), earnings(93, 7), earnings(92, 900)]}, 100)
        self.assertEqual(result["todayEarnings"], 500)
        self.assertEqual(result["sevenDayAverage"], 2)
        self.assertEqual(len(result["daily"]), 7)
        self.assertEqual(result["daily"][1]["amount"], 0)

    def test_referrals_excluded_storage_and_adjustments_included(self):
        row = {**earnings(99, 5, referral=999), "sto_earn": 2, "bwu_earn": 3, "bwd_earn": 4, "sla_earn": -1}
        result = c.parse_earnings({"per_day": [row]}, 100)
        self.assertEqual(result["sevenDayTotal"], 13)
        self.assertEqual(result["earningsBreakdown"], {"gpu": 5, "storage": 2, "network": 7, "adjustments": -1})
        self.assertEqual(sum(result["earningsBreakdown"].values()), result["sevenDayTotal"])

    def test_breakdown_uses_complete_days_and_excludes_today(self):
        result = c.parse_earnings({"rows": [earnings(100, 500), earnings(99, 7)]}, 100)
        self.assertEqual(result["earningsBreakdown"]["gpu"], 7)
        self.assertEqual(sum(result["earningsBreakdown"].values()), result["sevenDayTotal"])

    def test_host_details_preserve_unknown_values(self):
        result = c.parse_machines({"machines": [machine(earn_hour=0.55, earn_day=12.7, reliability2=0.995, gpu_max_cur_temp=62, cpu_name="Sample CPU")]})[0]
        self.assertEqual(result["reportedHourly"], 0.55)
        self.assertEqual(result["reportedDaily"], 12.7)
        self.assertEqual(result["reliability"], 0.995)
        self.assertEqual(result["gpuTemperature"], 62)
        self.assertEqual(result["listedHourly"], 0.6)
        result = c.parse_machines({"machines": [machine()]})[0]
        self.assertIsNone(result["reportedDaily"])
        self.assertIsNone(result["gpuTemperature"])

    def test_empty_valid_report_is_zero_unknown_schema_is_error(self):
        self.assertEqual(c.parse_earnings({"rows": []}, 100)["sevenDayAverage"], 0)
        for data in ({}, {"rows": None}, {"rows": [{"day": 99, "gpu_earn": 9}]}, {"rows": [earnings(99.5, 1)]}):
            with self.assertRaises(c.SourceError): c.parse_earnings(data, 100)

    def test_duplicate_days_not_double_counted(self):
        with self.assertRaises(c.SourceError): c.parse_earnings({"rows": [earnings(99, 5), earnings(99, 5)]}, 100)

    def test_running_rental_and_price_estimate(self):
        result = c.parse_machines({"machines": [machine()]})[0]
        self.assertEqual(result["status"], "Rented")
        self.assertEqual(result["estimatedHourly"], 0.6)

    def test_storage_only_is_not_running(self):
        result = c.parse_machines({"machines": [machine(current_rentals_running=0, gpu_occupancy="")]})[0]
        self.assertEqual(result["status"], "Stored only")
        self.assertEqual(result["estimatedHourly"], 0)

    def test_absent_running_status_is_unknown(self):
        raw = machine(); del raw["current_rentals_running"]
        result = c.parse_machines({"machines": [raw]})[0]
        self.assertEqual(result["status"], "Unknown")
        self.assertIsNone(result["estimatedHourly"])

    def test_partial_gpu_occupancy_and_unknown_prices(self):
        raw = machine(num_gpus=4, gpu_occupancy="D I _ _")
        self.assertEqual(c.parse_machines({"machines": [raw]})[0]["estimatedHourly"], 1.2)
        for raw in (machine(listed_gpu_cost=None), machine(gpu_occupancy=None), machine(gpu_occupancy="?")):
            self.assertIsNone(c.parse_machines({"machines": [raw]})[0]["estimatedHourly"])

    def test_missing_machine_list_is_not_empty(self):
        with self.assertRaises(c.SourceError): c.parse_machines({})
        self.assertEqual(c.parse_machines({"machines": []}), [])

    def test_pagination_and_legacy_fallback(self):
        with patch.object(c, "vast_request", side_effect=[{"rows": [earnings(99, 7)], "next_token": "next"}, {"rows": [earnings(98, 7)], "next_token": None}]):
            self.assertEqual(c.fetch_earnings("test-only-token", 100)["sevenDayAverage"], 2)
        with patch.object(c, "vast_request", side_effect=[c.HTTPFailure(404), {"per_day": [earnings(99, 7)]}]):
            self.assertEqual(c.fetch_earnings("test-only-token", 100)["sevenDayAverage"], 1)

    def test_machine_data_survives_earnings_failure(self):
        with patch.object(c, "vast_request", return_value={"machines": [machine()]}), patch.object(c, "fetch_earnings", side_effect=c.SourceError("Earnings unavailable")):
            result = c.fetch_vast("test-only-token")
        self.assertEqual(result["rentedCount"], 1)
        self.assertEqual(result["status"], "partial")
        self.assertNotIn("todayEarnings", result)

    def test_earnings_rate_limit_respected_with_partial_machine_data(self):
        with patch.object(c, "vast_request", return_value={"machines": [machine()]}), patch.object(c, "fetch_earnings", side_effect=c.HTTPFailure(429, 900)), patch.object(c.time, "time", return_value=1000):
            result = c.fetch_vast("test-only-token")
        self.assertEqual(result["nextRetryAt"], 1900)
        self.assertEqual(result["status"], "partial")

    def test_utilization_window_covers_today_or_previous_complete_days(self):
        now = 100 * 86400 + 6 * 3600
        self.assertEqual(c.utilization_window(0, now), (100, 100, 6.0))
        self.assertEqual(c.utilization_window(7, now), (93, 99, 168.0))
        self.assertEqual(c.utilization_window(0, 100 * 86400 + 60)[2], 1.0)

    def test_utilization_uses_documented_endpoint_then_falls_back_then_degrades(self):
        machines = {"machines": [machine(listed_gpu_cost=0.6, num_gpus=2)]}
        now = 100 * 86400 + 12 * 3600
        with patch.object(c, "fetch_earnings", return_value={}), patch.object(c.time, "time", return_value=now):
            with patch.object(c, "vast_request", side_effect=[machines, {"per_machine": [{"machine_id": 1, "gpu_earn": 100.8}]}]):
                result = c.fetch_vast("test-only-token", utilization_days=7)
            self.assertAlmostEqual(result["machines"][0]["utilization"], 0.5)
            self.assertEqual(result["utilizationDays"], 7)
            with patch.object(c, "vast_request", side_effect=[machines, c.HTTPFailure(404), {"rows": [{"machine_id": "1", "gpu_earn": 20}]}]):
                result = c.fetch_vast("test-only-token", utilization_days=0)
            self.assertEqual(result["machines"][0]["utilization"], 1.0)
            with patch.object(c, "vast_request", side_effect=[machines, c.HTTPFailure(500), c.HTTPFailure(500)]):
                result = c.fetch_vast("test-only-token", utilization_days=7)
            self.assertIsNone(result["machines"][0]["utilization"])
            self.assertIn("Utilization unavailable", result["utilizationError"])
            self.assertNotIn("status", result)
            previous = {"utilizationDays": 7, "utilizationCheckedAt": now - 100, "machines": [{"id": "1", "utilization": 0.25}]}
            with patch.object(c, "vast_request", side_effect=[machines]):
                result = c.fetch_vast("test-only-token", utilization_days=7, previous=previous)
            self.assertEqual(result["machines"][0]["utilization"], 0.25)

    def test_exchange_rate_is_cached_and_survives_outages(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            with patch.object(c, "request_json", return_value={"date": "2026-09-09", "rates": {"EUR": 0.858}}) as fetch, patch.object(c.time, "time", return_value=1000):
                self.assertEqual(c.exchange_rate(root, "EUR")["rates"]["EUR"], 0.858)
                self.assertEqual(c.exchange_rate(root, "EUR")["date"], "2026-09-09")
                fetch.assert_called_once()
            with patch.object(c, "request_json", side_effect=c.SourceError("down")), patch.object(c.time, "time", return_value=1000 + 13 * 3600):
                self.assertEqual(c.exchange_rate(root, "EUR")["rates"]["EUR"], 0.858)
                self.assertIsNone(c.exchange_rate(root, "GBP"))

    def test_exchange_rate_request_sends_no_credential(self):
        opener = MagicMock()
        opener.open.return_value.__enter__.return_value.read.return_value = b'{"rates": {"EUR": 0.9}}'
        with patch.object(c.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(c.request_json("https://api.frankfurter.dev/v1/latest?base=USD&symbols=EUR")["rates"]["EUR"], 0.9)
        self.assertFalse(opener.open.call_args[0][0].has_header("Authorization"))

    def test_malformed_earnings_page_is_normalized(self):
        with patch.object(c, "vast_request", return_value={"rows": None}):
            with self.assertRaises(c.SourceError): c.fetch_earnings("test-only-token", 100)


class ReliabilityTests(unittest.TestCase):
    def test_retry_after_supports_long_delays_and_http_dates(self):
        self.assertEqual(c.retry_after_seconds("7200"), 7200)
        with patch.object(c.time, "time", return_value=1788948000):
            self.assertEqual(c.retry_after_seconds("Wed, 09 Sep 2026 12:00:00 GMT"), 7200)
        self.assertEqual(c.retry_after_seconds("invalid"), 300)

    def test_failure_keeps_last_good_timestamp_and_sanitizes_error(self):
        with tempfile.TemporaryDirectory() as root:
            with patch.object(c, "fetch_cursor", return_value={"windows": []}), patch.object(c.time, "time", return_value=1000):
                c.collect("cursor", cache_dir=root)
            with patch.object(c, "fetch_cursor", side_effect=ValueError("secret=never-output")), patch.object(c.time, "time", return_value=1100):
                result = c.collect("cursor", cache_dir=root)
            self.assertEqual(result["status"], "stale")
            self.assertEqual(result["updatedAt"], 1000)
            self.assertNotIn("never-output", json.dumps(result))
            self.assertEqual((Path(root) / "cursor.json").stat().st_mode & 0o777, 0o600)

    def test_claude_manual_refresh_respects_minimum_interval(self):
        with tempfile.TemporaryDirectory() as root:
            with patch.object(c, "fetch_claude", return_value={"windows": []}) as fetch, patch.object(c.time, "time", return_value=1000):
                c.collect("claude", cache_dir=root)
            with patch.object(c, "fetch_claude") as fetch, patch.object(c.time, "time", return_value=1100):
                c.collect("claude", force=True, cache_dir=root)
                fetch.assert_not_called()

    def test_rate_limit_backoff_survives_manual_refresh(self):
        with tempfile.TemporaryDirectory() as root:
            with patch.object(c, "fetch_cursor", side_effect=c.HTTPFailure(429, 900)), patch.object(c.time, "time", return_value=1000):
                c.collect("cursor", cache_dir=root)
            with patch.object(c, "fetch_cursor") as fetch, patch.object(c.time, "time", return_value=1200):
                result = c.collect("cursor", force=True, cache_dir=root)
                fetch.assert_not_called()
                self.assertEqual(result["nextRetryAt"], 1900)

    def test_credentials_are_not_forwarded_through_redirects(self):
        self.assertIsNone(c.NoRedirect().redirect_request(None, None, 302, "", {}, "https://example.com"))

    def test_request_rejects_unrecognized_destination(self):
        with self.assertRaises(c.SourceError): c.request_json("https://example.com", "test-only-token")

    def test_http_backoff_honors_retry_after_and_retries_sign_in_errors_sooner(self):
        url = "https://api.anthropic.com/api/oauth/usage"
        for code, header, expected in ((401, None, 60), (403, None, 60), (500, None, 300), (429, "900", 900), (503, "invalid", 300)):
            headers = email.message.Message()
            if header:
                headers["Retry-After"] = header
            opener = Mock()
            opener.open.side_effect = urllib.error.HTTPError(url, code, "error", headers, None)
            with patch.object(c.urllib.request, "build_opener", return_value=opener):
                with self.assertRaises(c.HTTPFailure) as caught:
                    c.request_json(url, "test-only-token")
            self.assertEqual((caught.exception.status, caught.exception.retry_after), (code, expected))


if __name__ == "__main__":
    unittest.main()
