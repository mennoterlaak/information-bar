import base64
import json
from pathlib import Path
import tempfile
import unittest
import urllib.parse
from unittest.mock import patch

from test_collect import c

KEY = "K" * 56
SECRET = base64.b64encode(bytes(range(64))).decode()
CREDENTIALS = {"apiKey": KEY, "privateKey": SECRET}

ASSETS = {
    "XXBT": {"altname": "XBT", "display_decimals": 5},
    "XETH": {"altname": "ETH", "display_decimals": 5},
    "ETH2": {"altname": "ETH2", "display_decimals": 5},
    "ETH2.S": {"altname": "ETH2.S", "display_decimals": 5},
    "DOT": {"altname": "DOT", "display_decimals": 8},
    "DOT28.S": {"altname": "DOT28.S", "display_decimals": 8},
    "ZEUR": {"altname": "EUR", "display_decimals": 2},
    "ZUSD": {"altname": "USD", "display_decimals": 2},
    "KFEE": {"altname": "FEE", "display_decimals": 2},
    "TAO": {"altname": "TAO", "display_decimals": 4},
    "USDT": {"altname": "USDT", "display_decimals": 4},
    "USDT0": {"altname": "USDT0", "display_decimals": 4},
}


def pair(base, quote, status="online"):
    names = {key: info["altname"] for key, info in ASSETS.items()}
    return {"wsname": names[base] + "/" + names[quote], "base": base, "quote": quote, "status": status}


PAIRS = {
    "XXBTZEUR": pair("XXBT", "ZEUR"),
    "XXBTZUSD": pair("XXBT", "ZUSD"),
    "XETHXXBT": pair("XETH", "XXBT"),
    "ZEURZUSD": pair("ZEUR", "ZUSD"),
    "TAOUSD": pair("TAO", "ZUSD"),
    "USDTZUSD": pair("USDT", "ZUSD"),
    "DOTEUR": pair("DOT", "ZEUR", status="cancel_only"),
}
TICKER = {
    "XXBTZEUR": {"c": ["50000.0", "0.1"], "o": "49000.0"},
    "XXBTZUSD": {"c": ["55000.0", "0.1"], "o": "54000.0"},
    "XETHXXBT": {"c": ["0.05", "1"], "o": "0.05"},
    "ZEURZUSD": {"c": ["1.10", "1"], "o": "1.10"},
    "TAOUSD": {"c": ["220.0", "1"], "o": "200.0"},
    "USDTZUSD": {"c": ["1.0", "1"], "o": "1.0"},
}
BALANCE = {
    "XXBT": "0.1000000000", "XBT.M": "0.0500000000", "XETH": "1.0", "ETH2.S": "1.0", "TAO": "10",
    "ZEUR": "100.0000", "EUR.HOLD": "50.0000", "ZUSD": "110.0000", "DOT28.S": "10", "USDT0": "5",
    "KFEE": "1000.00", "ADA": "0.00000000",
}


def ok(result):
    return {"error": [], "result": result}


def kraken(overrides=None):
    """A fake request_json serving Kraken paths, recording each call."""
    responses = {"/0/public/Assets": ok(ASSETS), "/0/public/AssetPairs": ok(PAIRS),
                 "/0/public/Ticker": ok(TICKER), "/0/private/Balance": ok(BALANCE), **(overrides or {})}
    calls = []

    def request(url, token=None, **kwargs):
        calls.append((url, kwargs))
        value = responses[urllib.parse.urlparse(url).path]
        return value(url, kwargs) if callable(value) else value
    return request, calls


def markets():
    return {"assets": {key: {"altname": info["altname"], "decimals": info["display_decimals"]} for key, info in ASSETS.items()},
            "pairs": [[key, info["base"], info["quote"], info["wsname"]] for key, info in PAIRS.items() if info["status"] == "online"]}


class KrakenTests(unittest.TestCase):
    def test_signature_matches_kraken_reference_example(self):
        secret = base64.b64decode("kQH5HW/8p1uGOVjbgWA7FunAmGO8lsSUXNsu3eow76sz84Q18fWxnyRzBHCd3pd5nE9qa99HAZtuZuj6F1huXg==")
        signature = c.kraken_signature(
            "/0/private/AddOrder", "nonce=1616492376594&ordertype=limit&pair=XBTUSD&price=37500&type=buy&volume=1.25",
            1616492376594, secret)
        self.assertEqual(signature, "4/dpxb3iT4tp/ZCVEwSnEsLxx0bqyhLpdfOpc6fn7OR8+UClSV5n9E6aSS8MPtnRfp32bAb0nmbRn6H8ndwLUQ==")

    def test_incomplete_credentials_fail_before_any_request(self):
        for credentials in ({}, {"apiKey": KEY}, {"apiKey": "bad key\n", "privateKey": SECRET},
                            {"apiKey": KEY, "privateKey": "not base64!"}, {"apiKey": KEY, "privateKey": "c2hvcnQ="}):
            with self.subTest(credentials=credentials), tempfile.TemporaryDirectory() as root, \
                    patch.object(c, "request_json") as request, self.assertRaises(c.SourceError) as caught:
                c.kraken_private("Balance", credentials, Path(root))
            request.assert_not_called()
            self.assertTrue(caught.exception.auth)

    def test_nonce_keeps_increasing_when_the_clock_goes_back(self):
        with tempfile.TemporaryDirectory() as root:
            with patch.object(c.time, "time", return_value=2000.0):
                first = c.kraken_nonce(Path(root))
            with patch.object(c.time, "time", return_value=1000.0):
                second = c.kraken_nonce(Path(root))
            self.assertEqual(first, 2_000_000)
            self.assertEqual(second, first + 1)

    def test_staked_earning_and_held_variants_fold_into_their_asset(self):
        holdings = {h["symbol"]: h for h in c.kraken_holdings(BALANCE, markets())}
        self.assertEqual(set(holdings), {"BTC", "ETH", "TAO", "EUR", "USD", "DOT", "USDT0"})
        self.assertAlmostEqual(holdings["BTC"]["amount"], 0.15)
        self.assertAlmostEqual(holdings["BTC"]["earn"], 0.05)
        self.assertEqual((holdings["ETH"]["amount"], holdings["ETH"]["earn"], holdings["ETH"]["key"]), (2.0, 1.0, "XETH"))
        self.assertEqual((holdings["DOT"]["amount"], holdings["DOT"]["earn"]), (10.0, 10.0))
        self.assertEqual((holdings["EUR"]["amount"], holdings["EUR"]["earn"]), (150.0, 0.0))
        # An asset that merely ends in a digit is not mistaken for a bonded variant.
        self.assertEqual(holdings["USDT0"]["key"], "USDT0")
        self.assertEqual(holdings["BTC"]["decimals"], 5)

    def test_routes_prefer_direct_then_inverted_then_one_bridge(self):
        holdings = c.kraken_holdings(BALANCE, markets())
        routes = c.kraken_routes(holdings, markets(), "ZEUR")
        self.assertEqual(routes["XXBT"], [("XXBTZEUR", "XBT/EUR", False)])
        self.assertEqual(routes["ZUSD"], [("ZEURZUSD", "EUR/USD", True)])
        self.assertEqual(routes["XETH"], [("XETHXXBT", "ETH/XBT", False), ("XXBTZEUR", "XBT/EUR", False)])
        self.assertEqual(routes["TAO"], [("TAOUSD", "TAO/USD", False), ("ZEURZUSD", "EUR/USD", True)])
        self.assertEqual(routes["ZEUR"], [])
        self.assertNotIn("DOT", routes)  # Its only market is cancel-only.
        self.assertNotIn("USDT0", routes)

    def test_portfolio_is_valued_in_the_selected_currency_with_a_signed_balance_request(self):
        request, calls = kraken()
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=request):
            result = c.collect("kraken", config=CREDENTIALS, cache_dir=root, currency="EUR")
            cache = (Path(root) / "kraken.json").read_text()
            files = list(Path(root).glob("*.json"))
            modes = {path.name: path.stat().st_mode & 0o777 for path in files}
        portfolio = result["kraken"]
        self.assertEqual(result["status"], "ok")
        self.assertEqual(portfolio["currency"], "EUR")
        self.assertAlmostEqual(portfolio["totalValue"], 7500 + 5000 + 2000 + 150 + 100)
        self.assertAlmostEqual(portfolio["changeValue"], 150 + 100 + (2000 - 200 / 1.1 * 10))
        self.assertEqual([a["symbol"] for a in portfolio["assets"]], ["BTC", "ETH", "TAO", "EUR", "USD", "DOT", "USDT0"])
        btc, eth, tao, eur, usd, dot = portfolio["assets"][:6]
        self.assertEqual((btc["price"], btc["openPrice"]), (50000, 49000))
        self.assertAlmostEqual(eth["price"], 2500)
        self.assertAlmostEqual(tao["price"], 200)
        self.assertEqual((eur["price"], eur["fiat"]), (1, True))
        self.assertAlmostEqual(usd["value"], 100)
        self.assertIsNone(dot["price"])
        self.assertIsNone(dot["value"])
        # Legs use the WebSocket names, so the app can stream the same markets.
        self.assertEqual(btc["route"], [{"symbol": "BTC/EUR", "invert": False}])
        self.assertEqual(eth["route"], [{"symbol": "ETH/BTC", "invert": False}, {"symbol": "BTC/EUR", "invert": False}])
        self.assertEqual(tao["route"], [{"symbol": "TAO/USD", "invert": False}, {"symbol": "EUR/USD", "invert": True}])
        self.assertEqual(usd["route"], [{"symbol": "EUR/USD", "invert": True}])
        self.assertIsNone(eur["route"])  # Cash in the portfolio currency is always 1.
        self.assertIsNone(dot["route"])

        balance = [kwargs for url, kwargs in calls if url.endswith("/0/private/Balance")]
        self.assertEqual(len(balance), 1)
        form, headers = balance[0]["form"], balance[0]["headers"]
        nonce = int(urllib.parse.parse_qs(form)["nonce"][0])
        self.assertEqual(headers["API-Key"], KEY)
        self.assertEqual(headers["API-Sign"], c.kraken_signature("/0/private/Balance", form, nonce, base64.b64decode(SECRET)))
        ticker = next(url for url, _ in calls if "/0/public/Ticker" in url)
        self.assertIn("pair=TAOUSD,XETHXXBT,XXBTZEUR,ZEURZUSD", ticker)

        for text in (json.dumps(result), cache):
            self.assertNotIn(KEY, text)
            self.assertNotIn(SECRET, text)
        self.assertTrue(all(mode == 0o600 for mode in modes.values()), modes)

    def test_usd_portfolio_uses_usd_markets(self):
        request, _ = kraken()
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=request):
            portfolio = c.fetch_kraken(CREDENTIALS, Path(root), "USD")["kraken"]
        prices = {a["symbol"]: a["price"] for a in portfolio["assets"]}
        self.assertEqual(portfolio["currency"], "USD")
        self.assertEqual((prices["BTC"], prices["USD"], prices["TAO"]), (55000, 1, 220))
        self.assertAlmostEqual(prices["EUR"], 1.1)

    def test_delisted_market_refreshes_the_market_list_once(self):
        tickers = iter([{"error": ["EQuery:Unknown asset pair"], "result": {}}, ok(TICKER)])
        request, calls = kraken({"/0/public/Ticker": lambda url, kwargs: next(tickers)})
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=request):
            result = c.fetch_kraken(CREDENTIALS, Path(root), "EUR")
        self.assertNotIn("error", result)
        self.assertEqual(sum("/0/public/AssetPairs" in url for url, _ in calls), 2)
        self.assertEqual(sum("/0/public/Ticker" in url for url, _ in calls), 2)

    def test_price_outage_keeps_balances_without_inventing_a_total(self):
        request, _ = kraken({"/0/public/Ticker": {"error": ["EService:Unavailable"], "result": {}}})
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=request):
            result = c.fetch_kraken(CREDENTIALS, Path(root), "EUR")
        self.assertEqual(result["status"], "partial")
        self.assertIn("unavailable", result["error"])
        self.assertIsNone(result["kraken"]["totalValue"])
        self.assertEqual(len(result["kraken"]["assets"]), 7)
        self.assertTrue(all(asset["price"] is None for asset in result["kraken"]["assets"]))

    def test_market_list_is_cached_and_a_stale_copy_survives_an_outage(self):
        request, calls = kraken()
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=request):
            first = c.kraken_markets(Path(root))
            c.kraken_markets(Path(root))
            self.assertEqual(sum("/0/public/Assets" in url for url, _ in calls), 1)
            with patch.object(c, "kraken_request", side_effect=c.SourceError("down")), \
                    patch.object(c.time, "time", return_value=first["checkedAt"] + 2 * 86400):
                self.assertEqual(c.kraken_markets(Path(root))["pairs"], first["pairs"])
            with patch.object(c, "kraken_request", side_effect=c.SourceError("down")), \
                    patch.object(c.time, "time", return_value=first["checkedAt"] + 8 * 86400), self.assertRaises(c.SourceError):
                c.kraken_markets(Path(root))

    def test_kraken_errors_are_normalized(self):
        cases = {"EAPI:Invalid key": True, "EAPI:Invalid signature": True, "EGeneral:Permission denied": True,
                 "EAuth:Account temporary disabled": True, "EAPI:Invalid nonce": False, "EService:Busy": False,
                 "EGeneral:Temporary lockout": False, "EFuture:Something new": False}
        for code, auth in cases.items():
            request, _ = kraken({"/0/private/Balance": {"error": [code], "result": {}}})
            with self.subTest(code=code), tempfile.TemporaryDirectory() as root, \
                    patch.object(c, "request_json", side_effect=request), self.assertRaises(c.SourceError) as caught:
                c.kraken_private("Balance", CREDENTIALS, Path(root))
            self.assertEqual(caught.exception.auth, auth)
            self.assertNotIn(code, str(caught.exception))
        self.assertIn("Query Funds", str(c.KrakenError("EGeneral:Permission denied")))
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=c.HTTPFailure(429, 600)), \
                self.assertRaises(c.SourceError) as caught:
            c.kraken_private("Balance", CREDENTIALS, Path(root))
        self.assertIn("rate limiting", str(caught.exception))
        self.assertEqual(caught.exception.retry_after, 600)

    def test_warnings_do_not_fail_a_valid_response(self):
        with patch.object(c, "request_json", return_value={"error": ["WGeneral:Deprecated"], "result": {"ok": 1}}):
            self.assertEqual(c.kraken_request("/0/public/Time"), {"ok": 1})

    def test_validation_reports_a_readable_reason(self):
        request, _ = kraken({"/0/private/Balance": {"error": ["EGeneral:Permission denied"], "result": {}}})
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=request):
            self.assertEqual(c.validate_kraken_key(CREDENTIALS, Path(root)),
                             {"valid": False, "error": "This Kraken API key needs the Query Funds permission."})
        request, _ = kraken()
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=request):
            self.assertEqual(c.validate_kraken_key(CREDENTIALS, Path(root)), {"valid": True})

    def test_new_credentials_or_currency_never_reuse_the_cached_portfolio(self):
        with tempfile.TemporaryDirectory() as root, \
                patch.object(c, "fetch_kraken", return_value={"kraken": {"currency": "EUR", "assets": []}}) as fetch:
            c.collect("kraken", config=CREDENTIALS, cache_dir=root, currency="EUR")
            c.collect("kraken", config=CREDENTIALS, cache_dir=root, currency="EUR")
            self.assertEqual(fetch.call_count, 1)
            c.collect("kraken", config={**CREDENTIALS, "apiKey": "L" * 56}, cache_dir=root, currency="EUR")
            c.collect("kraken", config={**CREDENTIALS, "apiKey": "L" * 56}, cache_dir=root, currency="USD")
            self.assertEqual(fetch.call_count, 3)


if __name__ == "__main__":
    unittest.main()
