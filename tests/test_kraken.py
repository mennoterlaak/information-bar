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
    return {"wsname": names[base] + "/" + names[quote], "base": base, "quote": quote, "status": status,
            "margin_call": 80, "margin_stop": 40}


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
# Margin positions are read at a fixed time: 2027-01-15 08:00 UTC.
NOW = 1_800_000_000.0
MIDNIGHT = NOW // 86400 * 86400


def position(pair, side, opened, cost, vol, margin, value, net, closed="0.00000000", terms="0.0100% per 4 hours", fee="1.0"):
    return {"ordertxid": "OQCLML-BW3P3-BUCMWZ", "posstatus": "open", "pair": pair, "time": opened, "type": side,
            "ordertype": "limit", "cost": cost, "fee": fee, "vol": vol, "vol_closed": closed, "margin": margin,
            "value": value, "net": net, "terms": terms, "rollovertm": str(int(NOW + 3600)), "misc": "", "oflags": ""}


POSITIONS = {
    # One long filled twice, before and after midnight, priced through BTC/USD in a EUR portfolio.
    "TF5GVO-T7ZZ2-6NBKBI": position("XXBTZUSD", "buy", MIDNIGHT - 3600, "5000.00000", "0.10000000", "1000.00000",
                                    "5500.0", "+500.0000", fee="13.00000"),
    "T24DOR-TAFLM-ID3NYP": position("XXBTZUSD", "buy", MIDNIGHT + 3600, "2700.00000", "0.05000000", "540.00000",
                                    "2750.0", "+50.0000", fee="7.00000"),
    # A short with half its volume closed, quoted in BTC.
    "TYMRFG-URRG5-2ZTQSD": position("XETHXXBT", "sell", MIDNIGHT - 86400, "0.22000000", "4.00000000", "0.05500000",
                                    "0.1", "+0.0100", closed="2.00000000", terms="0.0200% per 4 hours", fee="0.00050000"),
    "TAFGBN-TZNFC-7CCYIM": {**position("XXBTZUSD", "sell", MIDNIGHT, "100.0", "0.002", "20.0", "110.0", "-10.0"),
                            "posstatus": "closed"},
}
TRADE = {"eb": "16000.0000", "tb": "15000.0000", "m": "2000.0000", "n": "1000.0000", "c": "12000.0000",
         "v": "13000.0000", "e": "16000.0000", "mf": "14000.0000", "ml": "800.00"}


def ok(result):
    return {"error": [], "result": result}


def kraken(overrides=None):
    """A fake request_json serving Kraken paths, recording each call. No margin positions by default."""
    responses = {"/0/public/Assets": ok(ASSETS), "/0/public/AssetPairs": ok(PAIRS),
                 "/0/public/Ticker": ok(TICKER), "/0/private/Balance": ok(BALANCE),
                 "/0/private/OpenPositions": ok({}), "/0/private/TradeBalance": ok(TRADE), **(overrides or {})}
    calls = []

    def request(url, token=None, **kwargs):
        calls.append((url, kwargs))
        value = responses[urllib.parse.urlparse(url).path]
        return value(url, kwargs) if callable(value) else value
    return request, calls


def markets():
    return {"assets": {key: {"altname": info["altname"], "decimals": info["display_decimals"]} for key, info in ASSETS.items()},
            "pairs": [[key, info["base"], info["quote"], info["wsname"]] for key, info in PAIRS.items() if info["status"] == "online"],
            "lookup": {key: [info["base"], info["quote"], info["wsname"], 80, 40] for key, info in PAIRS.items()}}


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

    def test_open_positions_are_grouped_per_market_and_valued_in_the_portfolio_currency(self):
        request, calls = kraken({"/0/private/OpenPositions": ok(POSITIONS)})
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=request), \
                patch.object(c.time, "time", return_value=NOW):
            result = c.fetch_kraken(CREDENTIALS, Path(root), "EUR")
        self.assertNotIn("status", result)
        margin = result["kraken"]["margin"]
        # Kraken's own account figures, asked for in the portfolio currency.
        self.assertEqual({key: margin[key] for key in ("equity", "tradeBalance", "used", "unrealized")},
                         {"equity": 16000, "tradeBalance": 15000, "used": 2000, "unrealized": 1000})
        self.assertEqual((margin["marginCall"], margin["liquidation"]), (80, 40))
        # Balances are unchanged by positions; the app adds their P&L to the total.
        self.assertAlmostEqual(result["kraken"]["totalValue"], 7500 + 5000 + 2000 + 150 + 100)
        btc, eth = margin["positions"]  # Largest first; the closed entry is left out.
        self.assertEqual((btc["symbol"], btc["base"], btc["quote"], btc["side"], btc["fills"]), ("BTC/USD", "BTC", "USD", "long", 2))
        self.assertAlmostEqual(btc["amount"], 0.15)
        self.assertAlmostEqual(btc["cost"], 7700)
        self.assertAlmostEqual(btc["entryPrice"], 7700 / 0.15)
        self.assertAlmostEqual(btc["margin"], 1540)
        self.assertAlmostEqual(btc["net"], 550)
        self.assertAlmostEqual(btc["fee"], 20)
        self.assertEqual((btc["price"], btc["openPrice"]), (55000, 54000))
        # The fill from before midnight counts from today's open, the later one from its entry.
        self.assertAlmostEqual(btc["openValue"], 0.1 * 54000 + 0.05 * 54000)
        self.assertAlmostEqual(btc["rate"], 1 / 1.1)
        self.assertEqual(btc["route"], [{"symbol": "EUR/USD", "invert": True}])
        # 0.01% every 4 hours of the 7,700 USD lent for a long, in euros.
        self.assertAlmostEqual(btc["rolloverPerDay"], 7700 * 0.0001 * 6 / 1.1)
        self.assertEqual((btc["terms"], btc["opened"], btc["nextRollover"]), ("0.0100% per 4 hours", MIDNIGHT - 3600, NOW + 3600))
        self.assertEqual((eth["symbol"], eth["base"], eth["quote"], eth["side"]), ("ETH/BTC", "ETH", "BTC", "short"))
        self.assertAlmostEqual(eth["amount"], 2)
        # Only the open half counts toward cost and margin.
        self.assertAlmostEqual(eth["cost"], 0.11)
        self.assertAlmostEqual(eth["margin"], 0.0275)
        self.assertAlmostEqual(eth["entryPrice"], 0.055)
        self.assertAlmostEqual(eth["net"], 0.01)
        self.assertEqual((eth["rate"], eth["route"]), (50000, [{"symbol": "BTC/EUR", "invert": False}]))
        # A short borrows the base amount: 0.02% every 4 hours of 2 ETH at 0.05 BTC, in euros.
        self.assertAlmostEqual(eth["rolloverPerDay"], 2 * 0.05 * 0.0002 * 6 * 50000)

        paths = [urllib.parse.urlparse(url).path for url, _ in calls]
        self.assertEqual(paths.count("/0/private/OpenPositions"), 1)
        for method, field in (("OpenPositions", "docalcs=true"), ("TradeBalance", "asset=ZEUR")):
            kwargs = next(kwargs for url, kwargs in calls if url.endswith("/0/private/" + method))
            nonce = int(urllib.parse.parse_qs(kwargs["form"])["nonce"][0])
            self.assertIn(field, kwargs["form"])
            self.assertEqual(kwargs["headers"]["API-Sign"],
                             c.kraken_signature("/0/private/" + method, kwargs["form"], nonce, base64.b64decode(SECRET)))
        ticker = next(url for url, _ in calls if "/0/public/Ticker" in url)
        self.assertIn("pair=TAOUSD,XETHXXBT,XXBTZEUR,XXBTZUSD,ZEURZUSD", ticker)

    def test_without_open_positions_the_account_figures_are_not_requested(self):
        request, calls = kraken()
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=request):
            result = c.fetch_kraken(CREDENTIALS, Path(root), "EUR")
        self.assertEqual(result["kraken"]["margin"], {"positions": []})
        self.assertFalse(any("TradeBalance" in url for url, _ in calls))

    def test_a_key_for_balances_only_explains_the_missing_permission_without_failing(self):
        request, calls = kraken({"/0/private/OpenPositions": {"error": ["EGeneral:Permission denied"], "result": {}}})
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=request):
            result = c.fetch_kraken(CREDENTIALS, Path(root), "EUR")
        self.assertNotIn("status", result)
        self.assertEqual(result["kraken"]["margin"], {"error": c.KRAKEN_MARGIN_PERMISSION})
        self.assertIn("Query Open Orders & Trades", c.KRAKEN_MARGIN_PERMISSION)
        self.assertIsNotNone(result["kraken"]["totalValue"])
        self.assertFalse(any("TradeBalance" in url for url, _ in calls))

    def test_margin_can_be_turned_off(self):
        request, calls = kraken({"/0/private/OpenPositions": ok(POSITIONS)})
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=request):
            result = c.fetch_kraken({**CREDENTIALS, "margin": False}, Path(root), "EUR")
        self.assertNotIn("margin", result["kraken"])
        self.assertEqual([urllib.parse.urlparse(url).path for url, _ in calls if "/private/" in url], ["/0/private/Balance"])

    def test_margin_outages_keep_the_balances_and_say_what_is_missing(self):
        request, _ = kraken({"/0/private/OpenPositions": {"error": ["EService:Unavailable"], "result": {}}})
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=request):
            result = c.fetch_kraken(CREDENTIALS, Path(root), "EUR")
        self.assertEqual(result["status"], "partial")
        self.assertTrue(result["error"].startswith("Margin: Kraken is unavailable"))
        self.assertNotIn("margin", result["kraken"])
        self.assertAlmostEqual(result["kraken"]["totalValue"], 7500 + 5000 + 2000 + 150 + 100)

        request, _ = kraken({"/0/private/OpenPositions": ok(POSITIONS),
                             "/0/private/TradeBalance": {"error": ["EAPI:Rate limit exceeded"], "result": {}}})
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=request):
            result = c.fetch_kraken(CREDENTIALS, Path(root), "EUR")
        self.assertEqual(result["status"], "partial")
        self.assertIn("rate limiting", result["error"])
        # The positions themselves are still listed, without Kraken's account figures.
        self.assertEqual(len(result["kraken"]["margin"]["positions"]), 2)
        self.assertNotIn("equity", result["kraken"]["margin"])

    def test_positions_without_prices_keep_krakens_valuation(self):
        request, _ = kraken({"/0/private/OpenPositions": ok(POSITIONS),
                             "/0/public/Ticker": {"error": ["EService:Unavailable"], "result": {}}})
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=request), \
                patch.object(c.time, "time", return_value=NOW):
            result = c.fetch_kraken(CREDENTIALS, Path(root), "EUR")
        self.assertTrue(result["error"].startswith("Prices: "))
        positions = {row["symbol"]: row for row in result["kraken"]["margin"]["positions"]}
        self.assertAlmostEqual(positions["BTC/USD"]["price"], (5500 + 2750) / 0.15)
        self.assertAlmostEqual(positions["BTC/USD"]["net"], 550)
        self.assertIsNone(positions["BTC/USD"]["rate"])
        self.assertIsNone(positions["BTC/USD"]["openValue"])
        self.assertEqual(result["kraken"]["margin"]["equity"], 16000)

    def test_an_older_market_list_is_refreshed_to_name_positions(self):
        request, calls = kraken({"/0/private/OpenPositions": ok(POSITIONS)})
        with tempfile.TemporaryDirectory() as root, patch.object(c, "request_json", side_effect=request), \
                patch.object(c.time, "time", return_value=NOW):
            older = {key: value for key, value in markets().items() if key != "lookup"}
            c.private_write(Path(root) / "kraken-markets.json", {**older, "checkedAt": NOW - 60})
            result = c.fetch_kraken(CREDENTIALS, Path(root), "EUR")
        self.assertEqual(sum("/0/public/AssetPairs" in url for url, _ in calls), 1)
        self.assertEqual([row["symbol"] for row in result["kraken"]["margin"]["positions"]], ["BTC/USD", "ETH/BTC"])

    def test_rollover_terms_are_read_as_a_daily_rate(self):
        self.assertAlmostEqual(c.kraken_rollover("0.0100% per 4 hours"), 0.0006)
        self.assertAlmostEqual(c.kraken_rollover("0.02 % per 24 hours"), 0.0002)
        for terms in (None, "", "n/a", "0.01% per 0 hours", {"rate": 1}):
            self.assertIsNone(c.kraken_rollover(terms))

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
