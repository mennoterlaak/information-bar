#!/usr/bin/env python3
"""Read-only account collectors. Only normalized metrics leave this process.

Uses Python's standard library. Credentials never appear in stdout, cache,
errors, command arguments, or this repository. See docs/data-sources.md.
"""
import argparse
import concurrent.futures
import contextlib
import datetime as dt
import email.utils
import fcntl
import json
import math
import os
from pathlib import Path
import selectors
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

APP_SUPPORT = Path.home() / "Library/Application Support/Information Bar"
NAMES = {"codex": "ChatGPT", "claude": "Claude", "cursor": "Cursor", "vast": "Vast.ai"}
LINKS = {
    "codex": "https://chatgpt.com/codex/settings/usage",
    "claude": "https://claude.ai/settings/usage",
    "cursor": "https://cursor.com/dashboard?tab=usage",
    "vast": "https://cloud.vast.ai/host/machines/",
}
TTL = {"codex": 60, "claude": 300, "cursor": 60, "vast": 60}
# The app passes its bundle version; "dev" when run directly.
VERSION = os.environ.get("INFORMATION_BAR_VERSION", "dev")
SOURCES = {"codex": "Codex app server", "claude": "Claude account usage", "cursor": "Cursor account usage", "vast": "Vast.ai host API"}
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


def request_json(url, token=None, *, body=None, headers=None):
    if urllib.parse.urlparse(url).hostname not in {"api.anthropic.com", "api2.cursor.sh", "console.vast.ai", "api.frankfurter.dev"}:
        raise SourceError("Unrecognized provider endpoint.")
    hdr = {"Accept": "application/json", "User-Agent": "InformationBar/" + VERSION}
    if token:
        hdr["Authorization"] = "Bearer " + token
    hdr.update(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        hdr["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=hdr)
    try:
        with urllib.request.build_opener(NoRedirect()).open(req, timeout=20) as response:
            value = json.loads(response.read(4 * 1024 * 1024))
            if not isinstance(value, dict):
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


def collect(provider, force=False, provided=None, cache_dir=None, currency="USD", utilization_days=None):
    root = Path(cache_dir) if cache_dir is not None else APP_SUPPORT / "Cache"
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    cache_path = root / (provider + ".json")
    lock_fd = os.open(str(root / (provider + ".lock")), os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(lock_fd, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        now = time.time()
        old = {}
        try:
            old = json.loads(cache_path.read_text())
        except (OSError, ValueError):
            pass
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
                       "vast": lambda: fetch_vast(provided, utilization_days, old)}
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
        if provider == "vast" and currency != "USD":
            rates = exchange_rate(root, currency)
            if rates:
                result["rates"] = rates["rates"]
                result["ratesDate"] = rates.get("date")
        private_write(cache_path, result)
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", choices=[*NAMES, "all"], default="all")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--credential-stdin", action="store_true")
    parser.add_argument("--validate-vast-key", action="store_true")
    parser.add_argument("--currency", default="USD")
    parser.add_argument("--utilization-days", type=int, default=None)
    args = parser.parse_args()
    credential = None
    if args.credential_stdin:
        try:
            credential = json.loads(sys.stdin.read(16384)).get("vastKey")
        except ValueError:
            pass
    if args.validate_vast_key:
        try:
            parse_machines(vast_request("/api/v0/machines/", vast_token(credential), {"owner": "me"}))
            print(json.dumps({"valid": True}))
        except Exception:
            print(json.dumps({"valid": False, "error": "Could not validate this key. Check the key and its host read permissions."}))
        return
    if args.provider == "all":
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            rows = list(pool.map(lambda p: collect(p, args.force, credential, currency=args.currency, utilization_days=args.utilization_days), NAMES))
        print(json.dumps({"providers": rows}, allow_nan=False))
    else:
        print(json.dumps(collect(args.provider, args.force, credential, currency=args.currency, utilization_days=args.utilization_days), allow_nan=False))


if __name__ == "__main__":
    main()
