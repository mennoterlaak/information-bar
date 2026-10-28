#!/usr/bin/env python3
"""Read-only account collectors. Only normalized metrics leave this process.

Uses Python's standard library. Credentials never appear in stdout, cache,
errors, command arguments, or this repository. See docs/data-sources.md.
"""
import argparse
import base64
import binascii
import concurrent.futures
import contextlib
import datetime as dt
import email.utils
import fcntl
import hashlib
import hmac
import http.client
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import socket
import ssl
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

APP_SUPPORT = Path.home() / "Library/Application Support/Information Bar"
NAMES = {"codex": "ChatGPT", "claude": "Claude", "cursor": "Cursor", "vast": "Vast.ai", "pearl": "Pearl", "power": "Power", "kraken": "Kraken"}
LINKS = {
    "codex": "https://chatgpt.com/codex/settings/usage",
    "claude": "https://claude.ai/settings/usage",
    "cursor": "https://cursor.com/dashboard?tab=usage",
    "vast": "https://cloud.vast.ai/host/machines/",
    "pearl": "https://pool.kryptex.com/prl",
    "power": "https://api-documentation.homewizard.com/docs/getting-started/",
    "kraken": "https://pro.kraken.com/app/portfolio",
}
TTL = {"codex": 60, "claude": 300, "cursor": 60, "vast": 60, "pearl": 60, "power": 60, "kraken": 60}
# The app passes its bundle version; "dev" when run directly.
VERSION = os.environ.get("INFORMATION_BAR_VERSION", "dev")
SOURCES = {"codex": "Codex app server", "claude": "Claude account usage", "cursor": "Cursor account usage", "vast": "Vast.ai host API", "pearl": "Kryptex · Pearl explorer · CoinGecko", "power": "HomeWizard local API", "kraken": "Kraken REST API"}
# European Central Bank reference rates, no credential involved.
RATES_URL = "https://api.frankfurter.dev/v1/latest"


class SourceError(Exception):
    def __init__(self, message, retry_after=60, auth=False):
        super().__init__(message)
        self.retry_after = retry_after
        self.auth = auth


class HTTPFailure(SourceError):
    def __init__(self, status, retry_after=60):
        self.status = status
        message = {
            401: "Sign in again to refresh this account's credentials.",
            403: "This account does not grant access to usage data.",
            429: "The provider is rate limiting requests. Refresh will retry later.",
        }.get(status, "The provider is unavailable (HTTP %s)." % status)
        super().__init__(message, retry_after, auth=status in (401, 403))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    # Never forward a bearer credential through a redirect, even on provider error.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def retry_after_seconds(header):
    numeric = number(header)
    if numeric is not None:
        return max(60, numeric)
    try:
        return max(60, email.utils.parsedate_to_datetime(header).timestamp() - time.time())
    except (TypeError, ValueError, OverflowError):
        return 300


def request_json(url, token=None, *, body=None, headers=None, form=None, response_type=dict):
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname not in {"api.anthropic.com", "api2.cursor.sh", "console.vast.ai", "api.frankfurter.dev", "pool.kryptex.com", "api.coingecko.com", "blockbook.pearlresearch.ai", "api.kraken.com"}:
        raise SourceError("Unrecognized provider endpoint.")
    hdr = {"Accept": "application/json", "User-Agent": "InformationBar/" + VERSION}
    if token:
        hdr["Authorization"] = "Bearer " + token
    hdr.update(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        hdr["Content-Type"] = "application/json"
    elif form is not None:
        # Already encoded, because a signed request must send exactly the bytes it signed.
        data = form.encode()
        hdr["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8"
    req = urllib.request.Request(url, data=data, headers=hdr)
    try:
        with urllib.request.build_opener(NoRedirect()).open(req, timeout=20) as response:
            value = json.loads(response.read(4 * 1024 * 1024))
            if not isinstance(value, response_type):
                raise SourceError("The provider returned an unrecognized response.")
            return value
    except urllib.error.HTTPError as exc:
        header = exc.headers.get("Retry-After")
        # Without a server hint: sign-in problems are fixed by the user, so retry soon; outages and rate limits wait longer.
        retry = retry_after_seconds(header) if header else (60 if exc.code in (401, 403) else 300)
        raise HTTPFailure(exc.code, retry) from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise SourceError("Could not reach the provider. Check your connection.") from None
    except (ValueError, UnicodeError):
        raise SourceError("The provider returned an unrecognized response.") from None


def number(value):
    if value is None or isinstance(value, bool):
        return None
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (ValueError, TypeError):
        return None


def timestamp(value):
    numeric = number(value)
    if numeric is not None:
        return numeric / 1000 if numeric > 1e11 else numeric
    if isinstance(value, str):
        try:
            return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except ValueError:
            pass
    return None


def window(identifier, label, used, reset, main=True):
    used = number(used)
    if used is None or used < 0:
        return None
    # main: an account-wide or per-model pool, listed first and eligible for the menu bar value.
    return {"id": identifier, "label": label, "usedPercent": used, "resetAt": timestamp(reset), "main": bool(main)}


def scope_name(value):
    if isinstance(value, dict):
        value = value.get("display_name")
    return value.strip() if isinstance(value, str) and value.strip() else None


def slug(name):
    return "".join(c if c.isalnum() else "_" for c in name.lower()).strip("_")


def duration_label(minutes, fallback):
    minutes = number(minutes)
    if minutes == 10080:
        return "Weekly"
    if minutes is None or minutes <= 0:
        return fallback
    if minutes % 1440 == 0:
        return "%g-day" % (minutes / 1440)
    if minutes % 60 == 0:
        return "%g-hour" % (minutes / 60)
    return "%g-minute" % minutes


def executable(name):
    found = shutil.which(name)
    if found:
        return found
    for root in (Path.home() / ".local/bin", Path("/opt/homebrew/bin"), Path("/usr/local/bin")):
        path = root / name
        if os.access(path, os.X_OK):
            return str(path)
    raise SourceError("Install %s and sign in to connect this account." % name, auth=True)


def keychain_read(service, account=None):
    args = ["/usr/bin/security", "find-generic-password", "-s", service]
    if account:
        args += ["-a", account]
    args += ["-w"]
    result = subprocess.run(args, capture_output=True, timeout=15)
    return result.stdout.decode().strip() if result.returncode == 0 else None


def codex_rpc():
    process = subprocess.Popen([executable("codex"), "app-server"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               cwd=tempfile.gettempdir(), start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    buffer = b""
    deadline = time.monotonic() + 25

    def send(message):
        process.stdin.write(json.dumps(message).encode() + b"\n")
        process.stdin.flush()

    def receive(identifier):
        nonlocal buffer
        while time.monotonic() < deadline:
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    response = json.loads(line)
                except ValueError:
                    continue
                if response.get("id") == identifier:
                    if "error" in response:
                        # Provider errors can include URLs or account details. Never echo them.
                        raise SourceError("Codex could not read subscription limits. Check its signed-in account.", auth=True)
                    return response["result"]
            if selector.select(min(0.2, max(0, deadline - time.monotonic()))):
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                buffer += chunk
                if len(buffer) > 4 * 1024 * 1024:
                    break
        raise SourceError("Codex usage did not respond in time.")

    try:
        send({"id": 0, "method": "initialize", "params": {"clientInfo": {"name": "information_bar", "title": "Information Bar", "version": VERSION}}})
        receive(0)
        send({"method": "initialized", "params": {}})
        send({"id": 1, "method": "account/rateLimits/read"})
        return receive(1)
    finally:
        selector.close()
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        process.stdin.close()
        process.stdout.close()


def parse_codex(data):
    buckets = data.get("rateLimitsByLimitId") or {}
    main = buckets.get("codex") or data.get("rateLimits")
    if not isinstance(main, dict):
        raise SourceError("Codex did not return subscription limits. Sign in with a ChatGPT account.", auth=True)
    windows = []
    ordered = [("codex", main)] + [(k, v) for k, v in sorted(buckets.items()) if k != "codex"]
    for key, bucket in ordered:
        for part in ("primary", "secondary"):
            raw = bucket.get(part)
            if not isinstance(raw, dict):
                continue
            label = duration_label(raw.get("windowDurationMins"), part.title())
            if key != "codex":
                label = (bucket.get("limitName") or key) + " · " + label
            parsed = window(key + ":" + part, label, raw.get("usedPercent"), raw.get("resetsAt"), main=key == "codex")
            if parsed:
                windows.append(parsed)
    if not windows:
        raise SourceError("Codex returned no metered subscription windows.")
    return {"plan": str(main.get("planType") or "Subscription").title(), "windows": windows}


def fetch_claude():
    raw = keychain_read("Claude Code-credentials")
    if not raw:
        path = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))) / ".credentials.json"
        if path.exists():
            raw = path.read_text()
    if not raw:
        raise SourceError("Sign in to Claude Code to connect your Claude subscription.", auth=True)
    oauth = json.loads(raw).get("claudeAiOauth", {})
    token = oauth.get("accessToken")
    if not token:
        raise SourceError("Claude Code has no subscription login. Run claude and sign in.", auth=True)
    expires = timestamp(oauth.get("expiresAt"))
    if expires and expires <= time.time():
        raise SourceError("Open Claude Code to refresh its expired login, then retry.", auth=True)
    data = request_json("https://api.anthropic.com/api/oauth/usage", token,
                        headers={"anthropic-beta": "oauth-2025-04-20"})
    return parse_claude(data, oauth.get("subscriptionType"))


CLAUDE_MAIN = {"five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"}


def parse_claude(data, plan=None):
    windows = []
    seen = set()
    labels = {"five_hour": "5-hour", "seven_day": "Weekly", "seven_day_sonnet": "Sonnet · weekly", "seven_day_opus": "Opus · weekly", "seven_day_cowork": "Cowork · weekly", "seven_day_oauth_apps": "Connected apps · weekly"}
    for key, label in labels.items():
        raw = data.get(key)
        if isinstance(raw, dict):
            parsed = window(key, label, raw.get("utilization"), raw.get("resets_at"), main=key in CLAUDE_MAIN)
            if parsed:
                windows.append(parsed)
                seen.add(key)
    # Newer responses also carry a `limits` list whose entries can be scoped to a model or a
    # surface. Model-specific weekly caps (Fable, for example) appear only there. Entries that
    # duplicate a window above are skipped; unknown kinds are not shown.
    for entry in data.get("limits") or []:
        if not isinstance(entry, dict):
            continue
        scope = entry.get("scope") if isinstance(entry.get("scope"), dict) else {}
        model = scope_name(scope.get("model"))
        surface = scope_name(scope.get("surface"))
        kind = entry.get("kind")
        if kind == "session":
            identifier, label, main = "five_hour", "5-hour", True
        elif kind == "weekly_all":
            identifier, label, main = "seven_day", "Weekly", True
        elif kind == "weekly_scoped" and model:
            identifier, label, main = "seven_day_" + slug(model), model + " · weekly", True
        elif kind == "weekly_scoped" and surface:
            identifier, label, main = "seven_day_" + slug(surface), surface.title() + " · weekly", False
        else:
            continue
        if identifier in seen:
            continue
        parsed = window(identifier, label, entry.get("percent"), entry.get("resets_at"), main=main)
        if parsed:
            windows.append(parsed)
            seen.add(identifier)
    if not windows:
        raise SourceError("Claude returned no subscription usage windows.")
    return {"plan": str(plan or "Subscription").title(), "windows": windows}


def fetch_cursor():
    path = Path.home() / "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    if not path.exists():
        raise SourceError("Open Cursor and sign in to connect its subscription.", auth=True)
    with contextlib.closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2)) as db:
        entries = dict(db.execute("SELECT key, value FROM ItemTable WHERE key IN (?, ?)", ("cursorAuth/accessToken", "cursorAuth/stripeMembershipType")))
    token = entries.get("cursorAuth/accessToken")
    if not token:
        raise SourceError("Sign in to Cursor to connect its subscription.", auth=True)
    data = request_json("https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage", token,
                        body={}, headers={"Connect-Protocol-Version": "1"})
    return parse_cursor(data, entries.get("cursorAuth/stripeMembershipType"))


def parse_cursor(data, plan=None):
    usage = data.get("planUsage")
    if not isinstance(usage, dict):
        raise SourceError("Cursor did not return a subscription allowance for this account.")
    windows = []
    for key, label in (("autoPercentUsed", "Cursor models"), ("apiPercentUsed", "Other models")):
        parsed = window(key, label, usage.get(key), data.get("billingCycleEnd"))
        if parsed:
            windows.append(parsed)
    if not windows:
        used = number(usage.get("totalPercentUsed"))
        limit = number(usage.get("limit"))
        included = number(usage.get("includedSpend"))
        if used is None and limit is not None and limit > 0 and included is not None:
            used = 100 * included / limit
        parsed = window("monthly", "Monthly allowance", used, data.get("billingCycleEnd"))
        if parsed:
            windows.append(parsed)
    if not windows:
        raise SourceError("Cursor returned no measurable subscription allowance.")
    return {"plan": str(plan or "Subscription").title(), "windows": windows,
            "billingStart": timestamp(data.get("billingCycleStart")),
            "billingEnd": timestamp(data.get("billingCycleEnd"))}


def vast_token(provided=None):
    if provided:
        return provided.strip()
    value = os.environ.get("VAST_API_KEY")
    if value:
        return value.strip()
    for path in (Path.home() / ".config/vastai/vast_api_key", Path.home() / ".vast_api_key"):
        if path.exists():
            value = path.read_text().strip()
            if value:
                return value
    raise SourceError("Add your Vast.ai API key in Settings to connect rental status and earnings.", auth=True)


def vast_request(path, token, query=None):
    suffix = "?" + urllib.parse.urlencode(query) if query else ""
    data = request_json("https://console.vast.ai" + path + suffix, token)
    if data.get("success") is False:
        raise SourceError("Vast.ai could not complete this report. Check the API key permissions.")
    return data


def parse_machines(data):
    raw = data.get("machines")
    if not isinstance(raw, list):
        raise SourceError("Vast.ai returned an unrecognized machine list.")
    result = []
    for machine in raw:
        identifier = machine.get("id", machine.get("machine_id"))
        if identifier is None:
            raise SourceError("Vast.ai returned a machine without an identifier.")
        running = number(machine.get("current_rentals_running"))
        stored = number(machine.get("current_rentals_resident"))
        status = "Unknown"
        if running is not None:
            if running > 0:
                status = "Rented"
            elif stored is not None and stored > 0:
                status = "Stored only"
            else:
                status = "Available" if machine.get("listed") is True else "Unlisted" if machine.get("listed") is False else "Idle"
        occupancy = machine.get("gpu_occupancy")
        gpu_count = number(machine.get("num_gpus"))
        rented_gpus = None
        # Each D/I/R character is an occupied GPU; missing/unknown codes are not zero.
        if isinstance(occupancy, str) and gpu_count is not None:
            codes = [c for c in occupancy if not c.isspace()]
            if all(c in "DIR_-." for c in codes) and len(codes) <= gpu_count:
                rented_gpus = sum(c in "DIR" for c in codes)
        price = number(machine.get("listed_gpu_cost"))
        rate = None
        if running == 0:
            rate = 0.0
        elif running is not None and running > 0 and rented_gpus and price is not None:
            rate = rented_gpus * price
        result.append({"id": str(identifier), "name": str(machine.get("hostname") or "Machine " + str(identifier)),
                       "gpu": str(machine.get("gpu_name") or "GPU"), "gpuCount": gpu_count,
                       "status": status, "running": running, "stored": stored,
                       "verification": machine.get("verification"), "estimatedHourly": rate,
                       "reportedHourly": number(machine.get("earn_hour")),
                       "reportedDaily": number(machine.get("earn_day")),
                       "listedHourly": price,
                       "gpuTemperature": number(machine.get("gpu_max_cur_temp")),
                       "reliability": number(machine.get("reliability2")),
                       "cpu": machine.get("cpu_name") if isinstance(machine.get("cpu_name"), str) else None,
                       "listed": machine.get("listed") if isinstance(machine.get("listed"), bool) else None,
                       "utilization": None})
    return sorted(result, key=lambda m: m["id"])


def earnings_amount(row):
    # Rental revenue, including storage/network and SLA adjustments; referrals excluded.
    fields = ("gpu_earn", "sto_earn", "bwu_earn", "bwd_earn")
    values = [number(row.get(field)) for field in fields]
    if any(value is None for value in values):
        raise SourceError("Vast.ai returned incomplete earnings amounts.")
    sla = number(row.get("sla_earn", 0))
    if sla is None:
        raise SourceError("Vast.ai returned an invalid earnings adjustment.")
    return sum(values) + sla


def parse_earnings(data, today):
    rows = data.get("rows", data.get("per_day"))
    if not isinstance(rows, list):
        raise SourceError("Vast.ai returned an unrecognized earnings report.")
    days = {day: 0.0 for day in range(today - 7, today + 1)}
    breakdown = {"gpu": 0.0, "storage": 0.0, "network": 0.0, "adjustments": 0.0}
    seen = set()
    for row in rows:
        day = number(row.get("day"))
        if day is None or day != int(day):
            raise SourceError("Vast.ai returned an invalid earnings day.")
        day = int(day)
        if day not in days:
            continue
        if day in seen:
            raise SourceError("Vast.ai returned duplicate daily earnings rows.")
        seen.add(day)
        days[day] = earnings_amount(row)
        if day < today:
            breakdown["gpu"] += number(row["gpu_earn"])
            breakdown["storage"] += number(row["sto_earn"])
            breakdown["network"] += number(row["bwu_earn"]) + number(row["bwd_earn"])
            breakdown["adjustments"] += number(row.get("sla_earn", 0))
    history = [{"day": day, "amount": days[day]} for day in range(today - 7, today)]
    total = sum(item["amount"] for item in history)
    return {"todayEarnings": days[today], "sevenDayTotal": total, "sevenDayAverage": total / 7,
            "daily": history, "currency": "USD", "earningsBreakdown": breakdown}


def fetch_earnings(token, today):
    query = {"select_filters": json.dumps({"day": {"gte": today - 7, "lte": today}}),
             "group_by": '"day"', "limit": 100,
             "order_by": json.dumps([{"col": "day", "dir": "desc"}])}
    try:
        data = vast_request("/api/v1/user/earnings/", token, query)
        if not isinstance(data.get("rows"), list):
            raise SourceError("Vast.ai returned an unrecognized earnings report.")
        rows = list(data["rows"])
        seen_tokens = set()
        while data.get("next_token"):
            next_token = data["next_token"]
            marker = json.dumps(next_token, sort_keys=True)
            if marker in seen_tokens or len(seen_tokens) >= 20:
                raise SourceError("Vast.ai earnings pagination did not finish.")
            seen_tokens.add(marker)
            query["after_token"] = next_token if isinstance(next_token, str) else json.dumps(next_token)
            data = vast_request("/api/v1/user/earnings/", token, query)
            if not isinstance(data.get("rows"), list):
                raise SourceError("Vast.ai returned an incomplete earnings page.")
            rows.extend(data["rows"])
        return parse_earnings({"rows": rows}, today)
    except HTTPFailure as exc:
        if exc.status not in (403, 404, 405):
            raise
        # Documented older endpoint for accounts/keys without the dashboard API.
        data = vast_request("/api/v0/users/me/machine-earnings/", token,
                            {"owner": "me", "sday": today - 7, "eday": today})
        return parse_earnings(data, today)


def fetch_machine_earnings(token, start, end):
    """GPU revenue per machine id over an inclusive day range; the documented endpoint first."""
    try:
        data = vast_request("/api/v0/users/me/machine-earnings/", token, {"owner": "me", "sday": start, "eday": end})
        rows = data.get("per_machine")
        if not isinstance(rows, list):
            raise SourceError("Vast.ai returned no per-machine earnings.")
    except SourceError:
        query = {"select_filters": json.dumps({"day": {"gte": start, "lte": end}}), "group_by": '"machine_id"', "limit": 100}
        data = vast_request("/api/v1/user/earnings/", token, query)
        rows = data.get("rows")
        if not isinstance(rows, list):
            raise SourceError("Vast.ai returned no per-machine earnings.")
    result = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        identifier = row.get("machine_id", row.get("machine"))
        earned = number(row.get("gpu_earn"))
        if identifier is not None and earned is not None:
            result[str(identifier)] = result.get(str(identifier), 0.0) + earned
    return result


def utilization_window(days, now):
    """(first day, last day, hours): today so far for 0, else the previous complete days."""
    today = int(now // 86400)
    if days <= 0:
        return today, today, max(1.0, (now % 86400) / 3600)
    return today - days, today - 1, days * 24.0


def apply_utilization(machines, result, token, days, previous):
    """Revenue-based share of listed GPU hours per machine; reused for five minutes."""
    now = time.time()
    result["utilizationDays"] = days
    checked = number(previous.get("utilizationCheckedAt")) or 0
    if previous.get("utilizationDays") == days and now - checked < 300:
        known = {m.get("id"): m.get("utilization") for m in previous.get("machines") or [] if isinstance(m, dict)}
        for machine in machines:
            machine["utilization"] = known.get(machine["id"])
        result["utilizationCheckedAt"] = checked
        if previous.get("utilizationError"):
            result["utilizationError"] = previous["utilizationError"]
        return
    result["utilizationCheckedAt"] = now
    start, end, hours = utilization_window(days, now)
    try:
        earned = fetch_machine_earnings(token, start, end)
    except SourceError as exc:
        result["utilizationError"] = "Utilization unavailable: " + str(exc)
        return
    for machine in machines:
        possible = (machine["listedHourly"] or 0) * (machine["gpuCount"] or 0) * hours
        machine["utilization"] = min(1.0, earned.get(machine["id"], 0.0) / possible) if possible > 0 else None


def fetch_vast(provided=None, utilization_days=None, previous=None):
    token = vast_token(provided)
    machines = parse_machines(vast_request("/api/v0/machines/", token, {"owner": "me", "include_offline": 1}))
    known = all(m["running"] is not None for m in machines)
    rates = [m["estimatedHourly"] for m in machines]
    result = {"machines": machines, "machineCount": len(machines),
              "rentedCount": sum(m["status"] == "Rented" for m in machines) if known else None,
              "estimatedHourly": sum(rates) if all(v is not None for v in rates) else None,
              "currency": "USD"}
    try:
        result.update(fetch_earnings(token, int(time.time() // 86400)))
    except SourceError as exc:
        result.update({"status": "partial", "error": str(exc), "nextRetryAt": time.time() + exc.retry_after})
    if utilization_days is not None:
        apply_utilization(machines, result, token, utilization_days, previous or {})
    return result


def exchange_rate(root, currency):
    """USD to `currency` from the ECB reference rates, cached for twelve hours; stale beats none."""
    path = root / "rates.json"
    cached = {}
    try:
        cached = json.loads(path.read_text())
    except (OSError, ValueError):
        pass
    if time.time() - (number(cached.get("fetchedAt")) or 0) < 12 * 3600 and number((cached.get("rates") or {}).get(currency)):
        return cached
    try:
        data = request_json(RATES_URL + "?" + urllib.parse.urlencode({"base": "USD", "symbols": currency}))
        rate = number((data.get("rates") or {}).get(currency))
        if rate is None or rate <= 0:
            raise SourceError("The exchange rate service returned no rate.")
        cached = {"rates": {currency: rate}, "date": str(data.get("date") or ""), "fetchedAt": time.time()}
        private_write(path, cached)
    except SourceError:
        pass
    return cached if number((cached.get("rates") or {}).get(currency)) else None


def private_write(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temp = tempfile.mkstemp(prefix=".metrics-", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(payload, stream, allow_nan=False)
        os.replace(temp, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temp)


def local_endpoint(raw, default_path=None, scheme=None):
    """Validate a user-configured LAN endpoint; never accept credentials in a URL."""
    if not isinstance(raw, str) or not raw.strip():
        raise SourceError("Enter the local API address in Settings.")
    raw = raw.strip()
    if "://" not in raw:
        raw = (scheme or "http") + "://" + raw
    try:
        url = urllib.parse.urlsplit(raw)
        port = url.port
    except ValueError:
        raise SourceError("Enter a valid local API address.") from None
    if (url.scheme not in ("http", "https") or (scheme and url.scheme != scheme)
            or not url.hostname or url.username is not None or url.password is not None
            or url.query or url.fragment):
        raise SourceError("Use a local HTTP(S) address without a password, query or fragment.")
    path = url.path.rstrip("/")
    if default_path:
        if path not in ("", default_path):
            raise SourceError("Enter the device address or its measurement endpoint.")
        path = default_path
    # Resolve once and connect to the checked address, avoiding DNS rebinding and proxies.
    try:
        addresses = socket.getaddrinfo(url.hostname, port or (443 if url.scheme == "https" else 80), type=socket.SOCK_STREAM)
        ips = list(dict.fromkeys(entry[4][0] for entry in addresses))
        if not ips or any(not (ipaddress.ip_address(ip).is_private or ipaddress.ip_address(ip).is_loopback)
                          or ipaddress.ip_address(ip).is_unspecified or ipaddress.ip_address(ip).is_multicast for ip in ips):
            raise SourceError("The API must be on your local network.")
    except OSError:
        raise SourceError("The local device could not be found. Check its address and your network.") from None
    return url, ips[0], port or (443 if url.scheme == "https" else 80), path or "/"


def local_json(raw, *, path=None, version=None, token=None, certificate_name=None):
    url, address, port, path = local_endpoint(raw, path, "https" if version == "v2" else "http" if version == "v1" else None)
    connection = None
    try:
        if url.scheme == "https":
            if version == "v2":
                if not token:
                    raise SourceError("Save this HomeWizard device's API token in Power Settings.")
                if not certificate_name or not certificate_name.startswith("appliance/"):
                    raise SourceError("Set the HomeWizard device type and serial number.")
                ca = Path(__file__).with_name("homewizard-ca.pem")
                context = ssl.create_default_context(cafile=str(ca))
                context.hostname_checks_common_name = True
                hostname = certificate_name
            else:
                context = ssl.create_default_context()
                hostname = url.hostname
            # TLS authenticates the configured device name; the TCP destination is the vetted IP.
            connection = http.client.HTTPConnection(address, port, timeout=8)
            connection.connect()
            connection.sock = context.wrap_socket(connection.sock, server_hostname=hostname)
        else:
            connection = http.client.HTTPConnection(address, port, timeout=8)
        headers = {"Accept": "application/json", "Host": url.netloc, "User-Agent": "InformationBar/" + VERSION}
        if version == "v2":
            headers.update({"Authorization": "Bearer " + token, "X-Api-Version": "2"})
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        if response.status != 200:
            # No redirects, error bodies, URLs or credentials in diagnostics.
            raise SourceError("Local API returned HTTP %d. Check the API settings and connection." % response.status)
        data = json.loads(response.read(1024 * 1024))
        if not isinstance(data, dict):
            raise ValueError()
        return data
    except SourceError:
        raise
    except ssl.SSLError:
        raise SourceError("Could not verify the device certificate. Check its type and serial number.") from None
    except (OSError, http.client.HTTPException):
        raise SourceError("Could not reach the local API. Check the address and that the API is running.") from None
    except (ValueError, UnicodeError):
        raise SourceError("The local API returned an unrecognized response.") from None
    finally:
        if connection:
            connection.close()


def parse_homewizard(data, version):
    value = number(data.get("power_w" if version == "v2" else "active_power_w"))
    if value is None:
        raise SourceError("This device did not report a power measurement.")
    # Negative values mean export, not a negative operating cost.
    return value


def fetch_power(config, tokens):
    devices = config.get("devices") or []
    if not isinstance(devices, list) or len(devices) > 32:
        raise SourceError("Configure up to 32 HomeWizard devices in Power Settings.")
    def read(device):
        row = {"id": device["id"], "name": device.get("name") or "HomeWizard"}
        try:
            version = device.get("apiVersion", "v1")
            if version not in ("v1", "v2"):
                raise SourceError("Select HomeWizard API v1 or v2.")
            data = local_json(device.get("address"), path="/api/measurement" if version == "v2" else "/api/v1/data",
                              version=version, token=tokens.get(device["id"]),
                              certificate_name="appliance/%s/%s" % (device.get("productType", "p1dongle"), device.get("serial", "").lower()))
            row.update(watts=parse_homewizard(data, version), updatedAt=time.time(), status="ok")
        except SourceError as exc:
            row.update(status="error", error=str(exc))
        return row
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        rows = list(pool.map(read, devices))
    failures = sum(row["status"] != "ok" for row in rows)
    result = {"powerDevices": rows}
    if failures:
        result.update(status="partial", error="%d HomeWizard device(s) unavailable. Check Power Settings." % failures)
    return result


def parse_pool_workers(data, wallet, worker=""):
    """Kryptex v3 reports accepted 30m/3h/24h averages in H/s, including numeric strings."""
    rows = data.get("results")
    if (not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows)
            or data.get("next") or ("count" in data and number(data["count"]) != len(rows))):
        raise SourceError("Kryptex did not return a complete list of Pearl workers.")
    selected = [row for row in rows if not worker or row.get("worker") == worker]
    if not selected:
        raise SourceError("Worker not found on Kryptex. Check the worker name or leave it empty."
                          if worker else "No Pearl workers found on Kryptex for this wallet yet.")
    if any(row.get("miner") != wallet or row.get("coin") != "prl"
           or row.get("status") not in ("online", "offline") for row in selected):
        raise SourceError("Kryptex returned unrecognized Pearl worker data.")

    def average(field, *, current=False):
        values = [0.0 if current and row["status"] == "offline" else number(row.get(field))
                  for row in selected]
        if any(value is None or value < 0 for value in values):
            return None
        total = sum(values)
        return total if math.isfinite(total) else None

    hashrate = average("avg_hashrate_30m", current=True)
    if hashrate is None:
        raise SourceError("Kryptex has not reported a valid 30-minute hashrate yet.")
    return {"hashrate": hashrate, "hashrate3h": average("avg_hashrate_3h"),
            "hashrate24h": average("avg_hashrate_24h"),
            "onlineWorkers": sum(row["status"] == "online" for row in selected),
            "workerCount": len(selected), "supportsPPS": all(row.get("scheme") == "pps" for row in selected)}


def pearl_yield(pool, hashrate):
    per_hash = number(pool.get("estimated_profit_day"))
    pool_fee = number(pool.get("fee"))
    if (str(pool.get("ticker", "")).lower() != "prl" or per_hash is None or per_hash <= 0
            or pool_fee is None or not 0 <= pool_fee < 1):
        raise SourceError("Kryptex did not report a valid Pearl yield or fee.")
    # Accepted shares already exclude time spent on the miner's developer-fee wallet.
    return hashrate * per_hash * (1 - pool_fee), pool_fee * 100


def pearl_source(path, ttl, loader):
    """Independent public-source caching/backoff, so a price outage never stops pool polling."""
    now = time.time()
    old = {}
    try:
        old = json.loads(path.read_text())
    except (OSError, ValueError):
        pass
    retry = number(old.get("nextRetryAt")) or 0
    if now < retry:
        raise SourceError(old.get("error") or "The Pearl data source is waiting before retrying.", retry - now)
    if now - (number(old.get("checkedAt")) or 0) < ttl:
        return old
    try:
        result = {**loader(), "checkedAt": now}
    except SourceError as exc:
        private_write(path, {"nextRetryAt": now + exc.retry_after, "error": str(exc)})
        raise
    private_write(path, result)
    return result


def pearl_price(root):
    def load():
        data = request_json("https://api.coingecko.com/api/v3/simple/price?ids=pearl-2&vs_currencies=usd&include_last_updated_at=true")
        coin = data.get("pearl-2") or {}
        if not isinstance(coin, dict):
            raise SourceError("Pearl's market price is unavailable or stale.")
        price, updated = number(coin.get("usd")), timestamp(coin.get("last_updated_at"))
        if price is None or price <= 0 or updated is None or not -60 <= time.time() - updated < 900:
            raise SourceError("Pearl's market price is unavailable or stale.")
        return {"priceUSD": price, "updatedAt": updated}
    result = pearl_source(root / "pearl-price.json", 120, load)
    # Even within the cache TTL, don't display a quote past its freshness limit.
    if time.time() - result["updatedAt"] >= 900:
        raise SourceError("Pearl's market price is unavailable or stale.")
    return result


def pearl_pool(root):
    def load():
        data = request_json("https://pool.kryptex.com/prl/api/v1/pool/info")
        pearl_yield(data, 0)  # Validate before caching a normalized subset.
        return {key: data[key] for key in ("ticker", "estimated_profit_day", "fee")}
    return pearl_source(root / "pearl-pool.json", 60, load)


def pearl_wallet_address(config):
    wallet = str(config.get("walletAddress") or "").strip()
    if not re.fullmatch(r"prl1[0-9a-z]{20,120}", wallet):
        raise SourceError("Enter the public PRL mining wallet address in Pearl Settings.")
    return wallet


def pearl_workers(config, root):
    wallet = pearl_wallet_address(config)
    worker = str(config.get("workerName") or "").strip()

    def load():
        try:
            data = request_json("https://pool.kryptex.com/prl/api/v3/miner/workers/"
                                + urllib.parse.quote(wallet, safe=""))
        except HTTPFailure as exc:
            if exc.status == 404:
                raise SourceError("Kryptex could not find this Pearl mining wallet.", exc.retry_after) from None
            raise
        return parse_pool_workers(data, wallet, worker)

    # Only normalized metrics are cached, separately for each wallet/worker selection.
    key = hashlib.sha256(json.dumps([wallet, worker]).encode()).hexdigest()
    result = pearl_source(root / ("pearl-workers-" + key + ".json"), 60, load)
    return {key: value for key, value in result.items() if key != "checkedAt"}


def parse_pearl_history(data):
    """Time-weight the raw ten-minute samples across a complete seven-day chart window."""
    window, interval = 7 * 86400, 600
    if not isinstance(data, list) or len(data) < 2:
        raise SourceError("Kryptex has not reported seven days of hashrate history yet.")
    points = []
    for row in data:
        at = timestamp(row.get("timestamp")) if isinstance(row, dict) else None
        rate = number(row.get("hashrate")) if isinstance(row, dict) else None
        if at is None or rate is None or rate < 0:
            raise SourceError("Kryptex returned invalid hashrate history.")
        points.append((at, rate))
    points.sort()
    end = points[-1][0]
    start = end - window
    if not -60 <= time.time() - end < 1800:
        raise SourceError("Kryptex's seven-day hashrate history is stale.")
    if points[0][0] > start:
        raise SourceError("Kryptex has not reported seven days of hashrate history yet.")
    weighted = []
    for (at, rate), (next_at, _) in zip(points, points[1:]):
        if next_at <= at:
            raise SourceError("Kryptex returned duplicate hashrate history timestamps.")
        if next_at <= start:
            continue
        # Missing intervals are unknown, never downtime. Explicit zero samples do count.
        if next_at - at != interval:
            raise SourceError("Kryptex's seven-day hashrate history has missing intervals.")
        weighted.append(rate * ((next_at - max(at, start)) / window))
    average = math.fsum(weighted)
    if not math.isfinite(average):
        raise SourceError("Kryptex returned invalid hashrate history.")
    return {"hashrate7d": average, "historyUpdatedAt": end}


def pearl_history(config, root):
    wallet = pearl_wallet_address(config)
    worker = str(config.get("workerName") or "").strip()
    path = urllib.parse.quote(wallet, safe="")
    if worker:
        path += "/" + urllib.parse.quote(worker, safe="")
    key = hashlib.sha256(json.dumps([wallet, worker]).encode()).hexdigest()

    def load():
        data = request_json("https://pool.kryptex.com/prl/api/v1/miner/chart/" + path + "?days=7",
                            response_type=list)
        return parse_pearl_history(data)

    result = pearl_source(root / ("pearl-history-v1-" + key + ".json"), 300, load)
    if not -60 <= time.time() - result["historyUpdatedAt"] < 1800:
        raise SourceError("Kryptex's seven-day hashrate history is stale.")
    return {key: value for key, value in result.items() if key != "checkedAt"}


def pearl_account_source(config, root, source, path, parser):
    wallet = pearl_wallet_address(config)
    key = hashlib.sha256(wallet.encode()).hexdigest()

    def load():
        data = request_json(path + urllib.parse.quote(wallet, safe=""))
        return parser(data)

    result = pearl_source(root / ("pearl-" + source + "-" + key + ".json"), 60, load)
    return {key: value for key, value in result.items() if key != "checkedAt"}


def parse_pearl_balance(data):
    fields = {name: number(data.get(key)) for name, key in (
        ("poolBalance", "total"), ("poolConfirmed", "confirmed"),
        ("poolUnconfirmed", "unconfirmed"), ("payoutThreshold", "threshold"))}
    if any(value is None or value < 0 for value in fields.values()) or fields["payoutThreshold"] <= 0:
        raise SourceError("Kryptex did not report valid pool balances and payout threshold.")
    if not math.isclose(fields["poolBalance"], fields["poolConfirmed"] + fields["poolUnconfirmed"], rel_tol=1e-8, abs_tol=1e-8):
        raise SourceError("Kryptex's confirmed and unconfirmed balances do not match its total.")
    return fields


def pearl_balance(config, root):
    return pearl_account_source(config, root, "balance", "https://pool.kryptex.com/prl/api/v1/miner/balance/", parse_pearl_balance)


def parse_pearl_payouts(data, wallet):
    rows, count = data.get("results"), number(data.get("count"))
    if (not isinstance(rows, list) or count is None or count < len(rows) or not count.is_integer()
            or (count > 0 and not rows)):
        raise SourceError("Kryptex did not return a valid payout history.")
    payouts = []
    statuses = {"FINISHED": "Paid", "PENDING": "Pending", "WAITING": "Pending",
                "PROCESSING": "Processing", "SENDING": "Sending", "SENT": "Sent",
                "FAILED": "Failed", "ERROR": "Failed", "REJECTED": "Rejected",
                "CANCELLED": "Cancelled", "CANCELED": "Cancelled"}
    for row in rows:
        if not isinstance(row, dict) or row.get("address", wallet) != wallet:
            raise SourceError("Kryptex returned unrecognized payout data.")
        date, amount = timestamp(row.get("date")), number(row.get("received"))
        state = str(row.get("status") or "").upper()
        # Pending rows may not have a received amount yet. Never present the planned amount as paid.
        if amount is None and state != "FINISHED":
            amount = number(row.get("amount"))
        if date is None or date <= 0 or amount is None or amount < 0:
            raise SourceError("Kryptex returned an invalid payout amount or date.")
        txid = row.get("txid")
        txid = txid.lower() if isinstance(txid, str) and re.fullmatch(r"[0-9a-fA-F]{64}", txid) else None
        normalized = {"date": date, "amount": amount, "status": statuses.get(state, "Unknown"), "txid": txid}
        normalized["id"] = hashlib.sha256(json.dumps(normalized, sort_keys=True).encode()).hexdigest()
        payouts.append(normalized)
    payouts.sort(key=lambda row: row["date"], reverse=True)
    # Only the newest page is fetched. All-time paid comes from the separate stats endpoint.
    return {"payouts": payouts[:5], "payoutCount": int(count)}


def pearl_payouts(config, root):
    wallet = pearl_wallet_address(config)
    return pearl_account_source(config, root, "payouts", "https://pool.kryptex.com/prl/api/v1/miner/payouts/",
                                lambda data: parse_pearl_payouts(data, wallet))


def parse_pearl_paid(data):
    paid = number(data.get("paid"))
    if paid is None or paid < 0:
        raise SourceError("Kryptex did not report a valid total paid amount.")
    return {"totalPaid": paid}


def pearl_paid(config, root):
    wallet = pearl_wallet_address(config)
    key = hashlib.sha256(wallet.encode()).hexdigest()
    result = pearl_source(root / ("pearl-paid-" + key + ".json"), 60,
                          lambda: parse_pearl_paid(request_json("https://pool.kryptex.com/prl/api/v1/miner/payouts/"
                                                               + urllib.parse.quote(wallet, safe="") + "/stats")))
    return {"totalPaid": result["totalPaid"]}


def parse_pearl_chain_status(data):
    book, backend = data.get("blockbook"), data.get("backend")
    if (not isinstance(book, dict) or not isinstance(backend, dict) or book.get("coin") != "Pearl"
            or backend.get("chain") != "mainnet" or book.get("inSync") is not True
            or book.get("initialSync") is not False or book.get("decimals") != 8):
        raise SourceError("Pearl's explorer is not synchronized with mainnet.")
    updated = timestamp(book.get("lastBlockTime"))
    if updated is None or not -60 <= time.time() - updated < 1800:
        raise SourceError("Pearl's explorer has not reported a recent block.")
    return {"blockUpdatedAt": updated}


def parse_pearl_wallet(data, wallet):
    raw = data.get("balance")
    if data.get("address") != wallet or not isinstance(raw, str) or not re.fullmatch(r"[0-9]{1,19}", raw):
        raise SourceError("Pearl's explorer did not report a valid wallet balance.")
    # Blockbook amounts are integer base units; mainnet advertises 8 decimals.
    return {"walletBalance": int(raw) / 100_000_000}


def pearl_wallet(config, root):
    wallet = pearl_wallet_address(config)
    key = hashlib.sha256(wallet.encode()).hexdigest()

    def load():
        status = pearl_source(root / "pearl-chain.json", 60,
                              lambda: parse_pearl_chain_status(request_json("https://blockbook.pearlresearch.ai/api/v2")))
        if time.time() - status["blockUpdatedAt"] >= 1800:
            raise SourceError("Pearl's explorer has not reported a recent block.")
        data = request_json("https://blockbook.pearlresearch.ai/api/v2/address/"
                            + urllib.parse.quote(wallet, safe="") + "?details=basic")
        return parse_pearl_wallet(data, wallet)

    result = pearl_source(root / ("pearl-wallet-" + key + ".json"), 60, load)
    return {"walletBalance": result["walletBalance"]}


def fetch_pearl(config, root):
    window = config.get("averageWindow", "7d")
    fields = {"30m": "hashrate30m", "3h": "hashrate3h", "24h": "hashrate24h", "7d": "hashrate7d"}
    if window not in fields:
        raise SourceError("Choose a hashrate average in Pearl Settings.")
    metrics, errors, results = {"averageWindow": window}, [], {}
    loaders = {"Price": lambda: pearl_price(root), "Hashrate": lambda: pearl_workers(config, root),
               "7-day average": lambda: pearl_history(config, root),
               "Pool yield": lambda: pearl_pool(root), "Wallet balance": lambda: pearl_wallet(config, root),
               "Pool balance": lambda: pearl_balance(config, root), "Payout history": lambda: pearl_payouts(config, root),
               "Total paid": lambda: pearl_paid(config, root)}
    # Independent requests keep an explorer outage from erasing healthy pool/mining data
    # and bound refresh duration below the app's collector watchdog.
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(loaders)) as pool:
        jobs = {name: pool.submit(loader) for name, loader in loaders.items()}
        for name, job in jobs.items():
            try:
                results[name] = job.result()
            except SourceError as exc:
                # An unavailable optional average must not flag a healthy shorter selection.
                if name != "7-day average" or window == "7d":
                    errors.append(name + ": " + str(exc))
    if price := results.get("Price"):
        metrics.update(priceUSD=price["priceUSD"], priceUpdatedAt=price["updatedAt"])
    workers = dict(results.get("Hashrate", {}))
    supports_pps = workers.pop("supportsPPS", False)
    if "hashrate" in workers:
        workers["hashrate30m"] = workers.pop("hashrate")
    metrics.update(workers)
    metrics.update(results.get("7-day average", {}))
    # Require the current worker response to validate this selection and its PPS scheme.
    if workers and metrics.get(fields[window]) is not None:
        metrics["hashrate"] = metrics[fields[window]]
    elif workers and (window != "7d" or "7-day average" in results):
        errors.append("Kryptex has not reported the selected hashrate average yet.")
    for name in ("Wallet balance", "Pool balance", "Payout history", "Total paid"):
        metrics.update(results.get(name, {}))
    if metrics.get("hashrate") is not None:
        try:
            if not supports_pps:
                raise SourceError("Profit projections require Kryptex PPS+ workers.")
            if pool := results.get("Pool yield"):
                coins, pool_fee = pearl_yield(pool, metrics["hashrate"])
                metrics.update(coinsPerDay=coins, poolFeePercent=pool_fee)
        except SourceError as exc:
            errors.append(str(exc))
    result = {"pearl": metrics}
    if errors:
        result.update(status="partial", error=" ".join(errors))
    return result


KRAKEN = "https://api.kraken.com"
# Balance-key suffixes for staked or reward-earning funds. Others (HOLD, CORE, ...) are the same
# asset held elsewhere in the spot wallet.
KRAKEN_EARN = {"S", "M", "B", "F", "P"}
KRAKEN_RENAMES = {"XBT": "BTC", "XDG": "DOGE"}
KRAKEN_FIAT = {"USD", "EUR", "GBP", "CAD", "JPY", "CHF", "AUD", "AED"}
KRAKEN_QUOTES = {"USD": "ZUSD", "EUR": "ZEUR"}
# Assets without a market in the portfolio currency are priced through one of these.
KRAKEN_BRIDGES = ("ZUSD", "ZEUR", "XXBT", "XETH", "USDT", "USDC")
KRAKEN_ERRORS = {
    "EAPI:Invalid key": ("Kraken rejected the API key. Check it in Kraken Settings.", 300, True),
    "EAPI:Invalid signature": ("Kraken rejected the private key. Check it in Kraken Settings.", 300, True),
    "EGeneral:Permission denied": ("This Kraken API key needs the Query Funds permission.", 300, True),
    "EAPI:Invalid nonce": ("Kraken rejected the request order. Use an API key only for Information Bar.", 300, False),
    "EGeneral:Temporary lockout": ("Kraken temporarily locked this API key. Refresh will retry later.", 900, False),
    "EAPI:Rate limit exceeded": ("Kraken is rate limiting requests. Refresh will retry later.", 300, False),
    "EQuery:Unknown asset pair": ("Kraken no longer lists one of the price markets.", 300, False),
}
# OpenPositions and TradeBalance need more than the Query Funds permission that Balance needs.
KRAKEN_MARGIN_PERMISSION = "Margin positions need the Query Open Orders & Trades permission on this API key."


class KrakenError(SourceError):
    def __init__(self, code):
        if code in KRAKEN_ERRORS:
            message, retry, auth = KRAKEN_ERRORS[code]
        elif "rate limit" in code.lower() or "too many" in code.lower():
            message, retry, auth = KRAKEN_ERRORS["EAPI:Rate limit exceeded"]
        elif code.startswith("EAuth:"):
            message, retry, auth = "Kraken did not authorize this API key.", 300, True
        elif code.startswith("EService:") or code == "EGeneral:Internal error":
            message, retry, auth = "Kraken is unavailable right now. Refresh will retry later.", 300, False
        else:
            message, retry, auth = "Kraken could not complete the request.", 300, False
        super().__init__(message, retry, auth)
        self.code = code


def kraken_request(path, query=None, **kwargs):
    # Commas stay literal: Kraken lists several pairs as pair=A,B.
    url = KRAKEN + path + ("?" + urllib.parse.urlencode(query, safe=",") if query else "")
    try:
        data = request_json(url, **kwargs)
    except HTTPFailure as exc:
        if exc.status == 429:
            raise SourceError(KRAKEN_ERRORS["EAPI:Rate limit exceeded"][0], exc.retry_after) from None
        raise SourceError("Kraken is unavailable (HTTP %s)." % exc.status, exc.retry_after) from None
    errors = data.get("error")
    # Codes starting with W are warnings that accompany a valid result.
    errors = [e for e in errors if isinstance(e, str) and e.startswith("E")] if isinstance(errors, list) else []
    if errors:
        raise KrakenError(errors[0])
    result = data.get("result")
    if not isinstance(result, dict):
        raise SourceError("Kraken returned an unrecognized response.")
    return result


def kraken_credentials(config):
    key = str(config.get("apiKey") or "").strip()
    secret = str(config.get("privateKey") or "").strip()
    if not key or not secret:
        raise SourceError("Add a Kraken API key in Settings to show your portfolio.", auth=True)
    # The pattern also keeps line breaks out of the request headers.
    if not re.fullmatch(r"[A-Za-z0-9+/=]{16,256}", key):
        raise SourceError("That Kraken API key is incomplete. Paste it again in Kraken Settings.", auth=True)
    try:
        decoded = base64.b64decode(secret, validate=True)
    except (binascii.Error, ValueError):
        decoded = b""
    if len(decoded) < 32:
        raise SourceError("That Kraken private key is incomplete. Paste it again in Kraken Settings.", auth=True)
    return key, decoded


def kraken_signature(path, postdata, nonce, secret):
    """API-Sign: HMAC-SHA512 over the URI path and SHA-256(nonce + POST data), keyed by the decoded private key."""
    message = path.encode() + hashlib.sha256((str(nonce) + postdata).encode()).digest()
    return base64.b64encode(hmac.new(secret, message, hashlib.sha512).digest()).decode()


def kraken_nonce(root):
    """Milliseconds, persisted so the nonce keeps increasing across runs and clock corrections.
    Callers hold the provider lock."""
    path = root / "kraken-nonce.json"
    try:
        last = int(json.loads(path.read_text())["nonce"])
    except (OSError, ValueError, TypeError, KeyError):
        last = 0
    nonce = max(int(time.time() * 1000), last + 1)
    private_write(path, {"nonce": nonce})
    return nonce


def kraken_private(method, config, root, params=None):
    key, secret = kraken_credentials(config)
    path = "/0/private/" + method
    nonce = kraken_nonce(root)
    postdata = urllib.parse.urlencode({"nonce": nonce, **(params or {})})
    return kraken_request(path, form=postdata, headers={"API-Key": key, "API-Sign": kraken_signature(path, postdata, nonce, secret)})


def kraken_markets(root, refresh=False):
    """Asset names and online pairs, refreshed daily. A list up to a week old beats none."""
    path = root / "kraken-markets.json"
    cached = {}
    try:
        cached = json.loads(path.read_text())
    except (OSError, ValueError):
        pass
    valid = isinstance(cached.get("assets"), dict) and isinstance(cached.get("pairs"), list)
    age = time.time() - (number(cached.get("checkedAt")) or 0)
    if valid and age < 86400 and not refresh:
        return cached
    try:
        assets, pairs = kraken_request("/0/public/Assets"), kraken_request("/0/public/AssetPairs")
        listed = {key: info for key, info in pairs.items()
                  if isinstance(info, dict) and isinstance(info.get("base"), str) and isinstance(info.get("quote"), str)}
        result = {
            "assets": {key: {"altname": info["altname"], "decimals": int(info.get("display_decimals", 8))}
                       for key, info in assets.items() if isinstance(info, dict) and isinstance(info.get("altname"), str)},
            "pairs": [[key, info["base"], info["quote"], str(info.get("wsname") or key)]
                      for key, info in listed.items() if info.get("status") == "online"],
            # Every pair whatever its status, by REST name: a margin position can stay open on a
            # market that no longer trades. Margin call and liquidation are margin levels in percent.
            "lookup": {key: [info["base"], info["quote"], str(info.get("wsname") or key),
                             number(info.get("margin_call")), number(info.get("margin_stop"))]
                       for key, info in listed.items()},
            "checkedAt": time.time(),
        }
    except (SourceError, TypeError, ValueError) as exc:
        if valid and age < 7 * 86400:
            return cached
        raise SourceError("Kraken's market list is unavailable. Refresh will retry later.", getattr(exc, "retry_after", 300)) from None
    private_write(path, result)
    return result


def kraken_holdings(balances, markets):
    """Folds staked, earning and held variants (DOT.S, DOT28.S, XBT.M, EUR.HOLD) into their asset."""
    assets = markets["assets"]
    by_name = {info["altname"]: key for key, info in assets.items()}
    traded = {asset for _, base, quote, _ in markets["pairs"] for asset in (base, quote)}

    def resolve(name):
        return name if name in assets else by_name.get(name)

    holdings = {}
    for raw, value in balances.items():
        amount = number(value)
        if not isinstance(raw, str) or amount is None or amount <= 0:
            continue
        base, _, suffix = raw.partition(".")
        earn = suffix in KRAKEN_EARN or base == "ETH2"
        key = resolve(base)
        if earn and key not in traded:
            # Bonded staking assets such as DOT28 and ETH2 have no market of their own. Assets
            # that merely end in digits (C98, USDT0) are left alone.
            key = resolve(base.rstrip("0123456789")) or key
        if key == "KFEE":
            continue  # Trading-fee credits, not an asset.
        name = assets[key]["altname"] if key else base
        holding = holdings.setdefault(key or base, {
            "key": key, "symbol": KRAKEN_RENAMES.get(name, name), "amount": 0.0, "earn": 0.0,
            "decimals": assets[key]["decimals"] if key else 8})
        holding["amount"] += amount
        if earn:
            holding["earn"] += amount
    return list(holdings.values())


def kraken_routes(holdings, markets, quote):
    """Market legs from each asset to the portfolio currency: direct, inverted, or through one bridge."""
    pairs = {(base, counter): (key, name) for key, base, counter, name in markets["pairs"]}

    def leg(source, target):
        if (source, target) in pairs:
            return [(*pairs[(source, target)], False)]
        if (target, source) in pairs:
            return [(*pairs[(target, source)], True)]
        return None

    routes = {}
    for holding in holdings:
        key = holding["key"]
        if key is None:
            continue
        route = [] if key == quote else leg(key, quote)
        for bridge in KRAKEN_BRIDGES:
            if route is not None:
                break
            if bridge not in (key, quote) and (first := leg(key, bridge)) and (second := leg(bridge, quote)):
                route = first + second
        if route is not None:
            routes[key] = route
    return routes


def kraken_priced(balances, positions, root, quote):
    """Markets, holdings, routes and one batched ticker for the holdings, the markets of open
    positions and the currencies those are quoted in. A delisted pair fails the whole ticker
    request, and a position can be on a market newer than the list, so the list is refetched once."""
    traded = {position["pair"] for position in positions.values() if isinstance(position.get("pair"), str)}
    for refresh in (False, True):
        markets = kraken_markets(root, refresh)
        lookup = markets.get("lookup") or {}
        outdated = "lookup" not in markets or time.time() - (number(markets.get("checkedAt")) or 0) > 3600
        if not refresh and outdated and not traded <= lookup.keys():
            continue
        holdings = kraken_holdings(balances, markets)
        quotes = [{"key": lookup[pair][1]} for pair in traded if pair in lookup]
        routes = kraken_routes(holdings + quotes, markets, quote)
        online = {pair[0] for pair in markets["pairs"]}
        names = sorted({leg[0] for route in routes.values() for leg in route} | (traded & online))
        try:
            return markets, holdings, routes, kraken_request("/0/public/Ticker", {"pair": ",".join(names)}) if names else {}
        except KrakenError as exc:
            if exc.code != "EQuery:Unknown asset pair" or refresh:
                raise


def kraken_rate(route, tickers, field):
    """Product of each leg's last trade ("c") or today's open ("o"), inverted where the pair is."""
    rate = 1.0
    for name, _, inverse in route:
        value = (tickers.get(name) or {}).get(field)
        price = number(value[0] if isinstance(value, list) and value else value)
        if price is None or price <= 0:
            return None
        rate *= 1 / price if inverse else price
    return rate


def kraken_symbol(name):
    """A pair as Kraken's WebSocket feed and website name it: XBT/EUR is BTC/EUR."""
    return "/".join(KRAKEN_RENAMES.get(part, part) for part in name.split("/"))


def kraken_rollover(terms):
    """Share of the borrowed amount charged per day, from terms such as "0.0100% per 4 hours"."""
    match = re.fullmatch(r"\s*([0-9]*\.?[0-9]+)\s*%\s*per\s*([0-9]+)\s*hours?\s*", terms if isinstance(terms, str) else "")
    if not match or int(match.group(2)) <= 0:
        return None
    return float(match.group(1)) / 100 * 24 / int(match.group(2))


def kraken_open_positions(config, root):
    """Open margin positions by trade id, valued by Kraken."""
    positions = kraken_private("OpenPositions", config, root, {"docalcs": "true"})
    return {txid: position for txid, position in positions.items()
            if isinstance(position, dict) and position.get("posstatus", "open") == "open"}


def kraken_trade_balance(config, root, quote):
    """Kraken's margin account figures in the portfolio currency."""
    trade = kraken_private("TradeBalance", config, root, {"asset": quote})
    return {"equity": number(trade.get("e")), "tradeBalance": number(trade.get("tb")),
            "used": number(trade.get("m")), "unrealized": number(trade.get("n"))}


def kraken_positions(positions, markets, routes, tickers, quote):
    """Open positions per market and side, largest first. Kraken lists every fill as its own
    position; fills are summed, and cost and margin count only the part still open."""
    lookup, assets = markets.get("lookup") or {}, markets["assets"]
    midnight = time.time() // 86400 * 86400

    def total(fills, field, share=False):
        values = [fill[field] * (fill["share"] if share else 1) for fill in fills if fill[field] is not None]
        return sum(values) if len(values) == len(fills) else None

    def display(key):
        name = assets[key]["altname"]
        return KRAKEN_RENAMES.get(name, name)

    groups = {}
    for position in positions.values():
        pair, side = position.get("pair"), position.get("type")
        volume, closed = number(position.get("vol")), number(position.get("vol_closed")) or 0.0
        cost = number(position.get("cost"))
        if not isinstance(pair, str) or side not in ("buy", "sell") or not volume or volume <= closed or cost is None:
            continue
        terms = position.get("terms") if isinstance(position.get("terms"), str) else None
        groups.setdefault((pair, side), []).append({
            "amount": volume - closed, "share": (volume - closed) / volume, "entry": cost / volume, "cost": cost,
            "margin": number(position.get("margin")), "fee": number(position.get("fee")),
            "value": number(position.get("value")), "net": number(position.get("net")),
            "time": number(position.get("time")), "terms": terms, "rollover": kraken_rollover(terms),
            "next": number(position.get("rollovertm"))})
    rows, levels = [], []
    for (pair, side), fills in groups.items():
        base, counter, name, call, stop = lookup.get(pair) or [None, None, pair, None, None]
        if call and stop:
            levels.append((call, stop))
        sign = 1 if side == "buy" else -1
        amount, cost = sum(fill["amount"] for fill in fills), total(fills, "cost", share=True)
        # The last trade, or Kraken's own valuation for a market without a ticker.
        price = kraken_rate([(pair, name, False)], tickers, "c")
        if price is None and (value := total(fills, "value")):
            price = value / amount
        net = total(fills, "net")
        if net is None and price is not None:
            net = sign * (amount * price - cost)
        # Value at today's 00:00 UTC open, or at entry for fills opened since.
        open_price = kraken_rate([(pair, name, False)], tickers, "o")
        references = [open_price if (fill["time"] or 0) < midnight else fill["entry"] for fill in fills]
        # Kraken lends the cost of a long and the base amount of a short.
        borrowed = [fill["cost"] * fill["share"] if sign > 0 else fill["amount"] * (price or 0) for fill in fills]
        rollover = sum(fill["rollover"] * lent for fill, lent in zip(fills, borrowed)) \
            if all(fill["rollover"] is not None for fill in fills) and (sign > 0 or price) else None
        route = [] if counter == quote else routes.get(counter)
        rate = kraken_rate(route, tickers, "c") if route is not None else None
        terms = {fill["terms"] for fill in fills}
        upcoming = [fill["next"] for fill in fills if fill["next"]]
        rows.append({
            "symbol": kraken_symbol(name), "side": "long" if sign > 0 else "short",
            "base": display(base) if base in assets else name, "quote": display(counter) if counter in assets else "",
            "amount": amount, "decimals": assets[base]["decimals"] if base in assets else 8,
            "entryPrice": cost / amount, "price": price, "openPrice": open_price,
            "openValue": sum(fill["amount"] * reference for fill, reference in zip(fills, references))
            if None not in references else None,
            "cost": cost, "margin": total(fills, "margin", share=True), "fee": total(fills, "fee"), "net": net,
            # Quote currency to the portfolio currency, as for holdings.
            "rate": rate,
            "route": [{"symbol": kraken_symbol(leg), "invert": inverse} for _, leg, inverse in route] if route is not None else None,
            "rolloverPerDay": rollover * rate if rollover is not None and rate is not None else None,
            "terms": terms.pop() if len(terms) == 1 else None, "nextRollover": min(upcoming) if upcoming else None,
            "opened": min((fill["time"] for fill in fills if fill["time"]), default=None), "fills": len(fills)})
    rows.sort(key=lambda row: (-(row["cost"] * (row["rate"] or 0)), row["symbol"], row["side"]))
    # The strictest market sets the account's thresholds.
    return rows, ({"marginCall": max(call for call, _ in levels), "liquidation": max(stop for _, stop in levels)} if levels else {})


def fetch_kraken(config, root, currency):
    currency = currency if currency in KRAKEN_QUOTES else "USD"
    quote = KRAKEN_QUOTES[currency]
    balances = kraken_private("Balance", config, root)
    errors, positions, margin = [], {}, None
    if config.get("margin", True):
        try:
            positions = kraken_open_positions(config, root)
            margin = {}
        except KrakenError as exc:
            if exc.code != "EGeneral:Permission denied":
                errors.append("Margin: " + str(exc))
            else:
                # A key made for balances only is not a failed refresh.
                margin = {"error": KRAKEN_MARGIN_PERMISSION}
        except SourceError as exc:
            errors.append("Margin: " + str(exc))
        if positions:
            try:
                margin.update(kraken_trade_balance(config, root, quote))
            except SourceError as exc:
                errors.append("Margin: " + str(exc))
    priced = True
    try:
        markets, holdings, routes, tickers = kraken_priced(balances, positions, root, quote)
    except SourceError as exc:
        # Balances stay useful without prices.
        markets, priced = kraken_markets(root), False
        holdings, routes, tickers = kraken_holdings(balances, markets), {}, {}
        errors.insert(0, "Prices: " + str(exc))
    if margin is not None and "error" not in margin:
        rows, levels = kraken_positions(positions, markets, routes, tickers, quote)
        margin.update(positions=rows, **levels)
    assets, total, change = [], 0.0, 0.0
    for holding in holdings:
        route = routes.get(holding["key"])
        price = kraken_rate(route, tickers, "c") if route is not None else None
        opened = kraken_rate(route, tickers, "o") if route is not None else None
        value = holding["amount"] * price if price is not None else None
        if value is not None:
            total += value
            if opened is not None:
                change += value - holding["amount"] * opened
        # The app reprices these exact legs from Kraken's live feed, so they must match the price.
        assets.append({"symbol": holding["symbol"], "amount": holding["amount"], "earn": holding["earn"],
                       "decimals": holding["decimals"], "fiat": holding["symbol"] in KRAKEN_FIAT,
                       "price": price, "openPrice": opened, "value": value,
                       "route": [{"symbol": kraken_symbol(name), "invert": inverse} for _, name, inverse in route]
                       if route else None})
    assets.sort(key=lambda asset: (asset["value"] is None, -(asset["value"] or 0), asset["symbol"]))
    # Balances and their change; the app adds the margin positions to both.
    result = {"kraken": {"currency": currency, "totalValue": total if priced else None,
                         "changeValue": change if priced else None, "assets": assets}}
    if margin is not None:
        result["kraken"]["margin"] = margin
    if errors:
        result.update(status="partial", error=" ".join(errors))
    return result


@contextlib.contextmanager
def provider_lock(root, provider):
    lock_fd = os.open(str(root / (provider + ".lock")), os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(lock_fd, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def validate_kraken_key(config, root):
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        # Shares the collector's lock so the two never send the same nonce.
        with provider_lock(root, "kraken"):
            kraken_private("Balance", config, root)
        return {"valid": True}
    except SourceError as exc:
        return {"valid": False, "error": str(exc)}


def collect(provider, force=False, provided=None, cache_dir=None, currency="USD", utilization_days=None, config=None, device_tokens=None):
    root = Path(cache_dir) if cache_dir is not None else APP_SUPPORT / "Cache"
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    cache_path = root / (provider + ".json")
    with provider_lock(root, provider):
        now = time.time()
        old = {}
        try:
            old = json.loads(cache_path.read_text())
        except (OSError, ValueError):
            pass
        config = config or {}
        device_tokens = device_tokens or {}
        # Never reuse one device/endpoint's readings after editing its connection. Only a digest
        # goes to disk, not the config, URLs, tokens or wallet addresses.
        config_key = hashlib.sha256(json.dumps([config, device_tokens, currency, utilization_days], sort_keys=True).encode()).hexdigest()
        if provider == "pearl":
            config_key = "kryptex-average-v2:" + config_key
        if provider in ("pearl", "power", "kraken") and old.get("configKey") != config_key:
            old = {}
        retry = number(old.get("nextRetryAt")) or 0
        last_attempt = number(old.get("checkedAt")) or 0
        # Manual refresh also respects server backoff and Claude's 5-minute minimum.
        minimum = 300 if provider == "claude" else 15
        interval = minimum if force else TTL[provider]
        if now < retry or now - last_attempt < interval:
            return old
        base = {"id": provider, "name": NAMES[provider], "source": SOURCES[provider], "url": LINKS[provider], "checkedAt": now}
        try:
            loaders = {"codex": lambda: parse_codex(codex_rpc()), "claude": fetch_claude, "cursor": fetch_cursor,
                       "vast": lambda: fetch_vast(provided, utilization_days, old),
                       "pearl": lambda: fetch_pearl(config, root), "power": lambda: fetch_power(config, device_tokens),
                       "kraken": lambda: fetch_kraken(config, root, currency)}
            result = {**base, "status": "ok", "updatedAt": now, **loaders[provider]()}
        except Exception as exc:
            if isinstance(exc, SourceError):
                message, delay, auth = str(exc), exc.retry_after, exc.auth
            elif isinstance(exc, subprocess.TimeoutExpired):
                message, delay, auth = "The local account helper timed out.", 60, False
            else:
                message, delay, auth = "Could not read this provider's usage data. Check its app login and try again.", 60, False
            age = now - (number(old.get("updatedAt")) or 0)
            previous = old if age < 86400 else {}
            result = {**previous, **base, "status": "stale" if previous.get("updatedAt") else "disconnected" if auth else "error",
                      "error": message, "nextRetryAt": now + delay}
        if provider in ("vast", "pearl", "power"):
            # Always fetch EUR: the tariff and revenue can have different currencies.
            rates = exchange_rate(root, "EUR")
            if rates:
                result["rates"] = rates["rates"]
                result["ratesDate"] = rates.get("date")
        if provider in ("pearl", "power", "kraken"):
            result["configKey"] = config_key
        private_write(cache_path, result)
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", choices=[*NAMES, "all"], default="all")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--credential-stdin", action="store_true")
    parser.add_argument("--validate-vast-key", action="store_true")
    parser.add_argument("--validate-kraken-key", action="store_true")
    parser.add_argument("--currency", default="USD")
    parser.add_argument("--utilization-days", type=int, default=None)
    args = parser.parse_args()
    credential, payload = None, {}
    if args.credential_stdin:
        try:
            payload = json.loads(sys.stdin.read(262144))
            credential = payload.get("vastKey")
        except (ValueError, AttributeError):
            payload = {}
            pass
    if args.validate_vast_key:
        try:
            parse_machines(vast_request("/api/v0/machines/", vast_token(credential), {"owner": "me"}))
            print(json.dumps({"valid": True}))
        except Exception:
            print(json.dumps({"valid": False, "error": "Could not validate this key. Check the key and its host read permissions."}))
        return
    if args.validate_kraken_key:
        try:
            print(json.dumps(validate_kraken_key(payload.get("kraken") or {}, APP_SUPPORT / "Cache")))
        except Exception:
            print(json.dumps({"valid": False, "error": "Could not validate this key with Kraken. Try again."}))
        return
    if args.provider == "all":
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            rows = list(pool.map(lambda p: collect(p, args.force, credential, currency=args.currency, utilization_days=args.utilization_days,
                                                config=payload.get(p), device_tokens=payload.get("deviceTokens")), NAMES))
        print(json.dumps({"providers": rows}, allow_nan=False))
    else:
        print(json.dumps(collect(args.provider, args.force, credential, currency=args.currency, utilization_days=args.utilization_days,
                                 config=payload.get(args.provider), device_tokens=payload.get("deviceTokens")), allow_nan=False))


if __name__ == "__main__":
    main()
