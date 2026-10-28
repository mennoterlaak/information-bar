#!/usr/bin/env python3
"""Read-only, paired HTTPS access to Information Bar's normalized Mac cache.

No provider login, Keychain item, collector or raw account store is accessed here.
Pairing material is private and is never printed, including on failed commands.
"""

import argparse
import base64
import hashlib
import hmac
import ipaddress
import json
import math
import os
from pathlib import Path
import plistlib
import re
import secrets
import socket
import ssl
import stat
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


APP_SUPPORT = Path.home() / "Library/Application Support/Information Bar"
PRIVATE_DIR = APP_SUPPORT / "Mobile"
CACHE_DIR = APP_SUPPORT / "Cache"
DOMAIN = "dev.starecat.InformationBar"
DEFAULT_BUNDLE_ID = "dev.starecat.InformationBar.mobile"
PORT = 8943
MAX_FILE_BYTES = 512 * 1024
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
NAMES = {
    "codex": "ChatGPT", "claude": "Claude", "cursor": "Cursor", "vast": "Vast.ai",
    "pearl": "Pearl", "kraken": "Kraken", "power": "Power",
}


class BridgeError(Exception):
    """Messages are fixed public diagnostics, never provider or command output."""


def read_private_file(path, maximum=MAX_FILE_BYTES):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
            raise BridgeError("The local data file is invalid or too large.")
        data = stream.read(maximum + 1)
        if len(data) > maximum:
            raise BridgeError("The local data file is too large.")
        return data


def write_private_file(path, payload):
    descriptor, temporary = tempfile.mkstemp(prefix=".mobile-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def encoded_json(value):
    return json.dumps(value, allow_nan=False, separators=(",", ":")).encode()


def command(arguments, timeout=15):
    """Do not let an external process's diagnostics reveal pairing material."""
    try:
        result = subprocess.run(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise BridgeError("A required local command could not finish.") from None
    if result.returncode:
        raise BridgeError("A required local command did not succeed.")
    return result.stdout


def read_preferences():
    try:
        raw = command(["/usr/bin/defaults", "export", DOMAIN, "-"])
        if len(raw) > MAX_FILE_BYTES:
            raise BridgeError("The preferences file is too large.")
        domain = plistlib.loads(raw)
        if not isinstance(domain, dict):
            raise ValueError("Invalid preferences")
        payload = domain.get("preferences.v2")
        if not isinstance(payload, (bytes, str)):
            return {}
        parsed = json.loads(payload)
        if not isinstance(parsed, dict):
            raise ValueError("Invalid preferences")
        return parsed
    except (BridgeError, ValueError, TypeError, plistlib.InvalidFileException):
        # Unknown visibility must not expose a disabled provider's old cached balances.
        raise BridgeError("Open Information Bar on the Mac before syncing its settings.") from None


# Explicit nested allowlists prevent future collector fields from silently leaving the Mac.
WINDOW = {"id": str, "label": str, "usedPercent": float, "resetAt": float, "main": bool}
MACHINE = {"id": str, "name": str, "gpu": str, "status": str,
           **{key: float for key in ("gpuCount", "running", "stored", "estimatedHourly",
              "reportedHourly", "reportedDaily", "listedHourly", "gpuTemperature",
              "reliability", "utilization")}, "verification": str, "cpu": str, "listed": bool}
PAYOUT = {"id": str, "date": float, "amount": float, "status": str, "txid": str}
PEARL = {key: float for key in (
    "priceUSD", "priceUpdatedAt", "hashrate", "hashrate30m", "hashrate3h", "hashrate24h",
    "hashrate7d", "historyUpdatedAt", "coinsPerDay", "poolFeePercent", "walletBalance",
    "poolBalance", "poolConfirmed", "poolUnconfirmed", "payoutThreshold", "totalPaid")}
PEARL.update({"averageWindow": str, "onlineWorkers": int, "workerCount": int,
              "payoutCount": int, "payouts": [PAYOUT]})
POWER = {"id": str, "name": str, "watts": float, "status": str, "updatedAt": float}
LEG = {"symbol": str, "invert": bool}
ASSET = {"symbol": str, "amount": float, "earn": float, "decimals": int, "fiat": bool,
         "price": float, "openPrice": float, "value": float, "route": [LEG]}
KRAKEN = {"currency": str, "totalValue": float, "changeValue": float, "assets": [ASSET]}
EARNING_DAY = {"day": int, "amount": float}
BREAKDOWN = {key: float for key in ("gpu", "storage", "network", "adjustments")}
PROVIDER = {
    "id": str, "name": str, "status": str, "plan": str, "windows": [WINDOW],
    "updatedAt": float, "checkedAt": float, "nextRetryAt": float, "machines": [MACHINE],
    "machineCount": int, "rentedCount": int, "estimatedHourly": float,
    "todayEarnings": float, "sevenDayTotal": float, "sevenDayAverage": float,
    "daily": [EARNING_DAY], "currency": str,
    "billingStart": float, "billingEnd": float,
    "earningsBreakdown": BREAKDOWN,
    "rates": {"EUR": float, "USD": float}, "ratesDate": str, "utilizationDays": int,
    "pearl": PEARL, "powerDevices": [POWER], "kraken": KRAKEN,
}
REQUIRED = {
    id(WINDOW): ("id", "label", "usedPercent"), id(MACHINE): ("id", "name", "gpu", "status"),
    id(PAYOUT): ("id", "date", "amount", "status"), id(POWER): ("id", "name", "status"),
    id(LEG): ("symbol", "invert"), id(ASSET): ("symbol", "amount", "earn", "decimals", "fiat"),
    id(KRAKEN): ("currency", "assets"),
    id(EARNING_DAY): ("day", "amount"), id(BREAKDOWN): tuple(BREAKDOWN),
}


def project(value, schema):
    if value is None:
        return None
    if isinstance(schema, dict):
        if not isinstance(value, dict):
            raise ValueError("Invalid object")
        result = {}
        for key, rule in schema.items():
            if key in value:
                result[key] = project(value[key], rule)
        if any(result.get(key) is None for key in REQUIRED.get(id(schema), ())):
            raise ValueError("Missing required field")
        return result
    if isinstance(schema, list):
        if not isinstance(value, list) or len(value) > 2048 or any(item is None for item in value):
            raise ValueError("Invalid list")
        return [project(item, schema[0]) for item in value]
    if schema is str:
        if not isinstance(value, str) or len(value) > 1024:
            raise ValueError("Invalid text")
    elif schema is bool:
        if not isinstance(value, bool):
            raise ValueError("Invalid boolean")
    elif schema is int:
        if not isinstance(value, int) or isinstance(value, bool):
            raise ValueError("Invalid integer")
    elif schema is float:
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
            raise ValueError("Invalid number")
    return value


def choice(value, choices, default):
    return value if isinstance(value, str) and value in choices else default


def object_value(value):
    return value if isinstance(value, dict) else {}


def safe_preferences(raw):
    raw = object_value(raw)
    provider_options = object_value(raw.get("providers"))
    result = {"providers": {}, "theme": choice(raw.get("theme"), ("system", "light", "dark"), "system"),
              "refreshInterval": 120 if raw.get("refreshInterval") == 120 else 60,
              "gaugeStyle": choice(raw.get("gaugeStyle"), ("ring", "ringValue", "bar"), "ring")}
    for identifier in NAMES:
        options = object_value(provider_options.get(identifier))
        exported = {"enabled": options.get("enabled") is not False,
                    "currency": choice(options.get("currency"), ("USD", "EUR"), "USD"),
                    "utilizationPeriod": choice(options.get("utilizationPeriod"), ("day", "week", "month"), "week"),
                    "earningsView": choice(options.get("earningsView"), ("gross", "net", "both"), "gross")}
        for key in ("showAdditional", "showResetDates", "showEarningsHistory", "showMachineDetails", "livePrices"):
            if isinstance(options.get(key), bool):
                exported[key] = options[key]
        # Menu composition is Mac-specific; omission uses the shared model's defaults.
        result["providers"][identifier] = exported
    pearl = object_value(raw.get("pearl"))
    result["pearl"] = {"walletAddress": "", "workerName": "",
                       "averageWindow": choice(pearl.get("averageWindow"), ("30m", "3h", "24h", "7d"), "7d")}
    power = object_value(raw.get("power"))
    cleaned_power = {"currency": choice(power.get("currency"), ("USD", "EUR"), "USD"), "devices": []}
    price = power.get("pricePerKWh")
    if isinstance(price, (float, int)) and not isinstance(price, bool) and math.isfinite(price) and price >= 0:
        cleaned_power["pricePerKWh"] = price
    devices = power.get("devices", [])
    if isinstance(devices, list):
        for device in devices[:128]:
            if not isinstance(device, dict):
                continue
            identifier, name = device.get("id"), device.get("name")
            if not isinstance(identifier, str) or not 0 < len(identifier) <= 128:
                continue
            cleaned_power["devices"].append({
                "id": identifier, "name": name[:256] if isinstance(name, str) else "HomeWizard",
                "address": "", "serial": "", "apiVersion": "v1", "productType": "p1dongle",
                "assignment": choice(device.get("assignment"), ("none", "pearl", "vast"), "none"),
            })
    selection = power.get("displayDeviceID")
    if any(item["id"] == selection for item in cleaned_power["devices"]):
        cleaned_power["displayDeviceID"] = selection
    result["power"] = cleaned_power
    return result


def snapshot(cache_dir=CACHE_DIR, preferences=None, now=None):
    preferences = safe_preferences(read_preferences() if preferences is None else preferences)
    providers = []
    for identifier, name in NAMES.items():
        if not preferences["providers"][identifier]["enabled"]:
            continue
        placeholder = {"id": identifier, "name": name, "status": "disconnected"}
        try:
            raw = json.loads(read_private_file(Path(cache_dir) / (identifier + ".json")))
            if not isinstance(raw, dict) or raw.get("id") != identifier:
                raise ValueError("Provider mismatch")
            item = project(raw, PROVIDER)
            item["name"] = name
            item["status"] = choice(item.get("status"),
                                    ("ok", "partial", "stale", "disconnected", "error", "loading"), "error")
            if item.get("pearl") and "averageWindow" in item["pearl"]:
                item["pearl"]["averageWindow"] = choice(item["pearl"]["averageWindow"], ("30m", "3h", "24h", "7d"), "7d")
            providers.append(item)
        except (OSError, BridgeError, ValueError, TypeError, OverflowError):
            providers.append(placeholder)
    result = {"version": 1, "generatedAt": time.time() if now is None else now,
              "providers": providers, "preferences": preferences}
    if len(encoded_json(result)) > MAX_RESPONSE_BYTES:
        raise BridgeError("The normalized snapshot is too large.")
    return result


def valid_host(host):
    if not isinstance(host, str) or not host or len(host) > 253:
        raise BridgeError("Enter a local hostname or IP address.")
    try:
        return str(ipaddress.ip_address(host))
    except ValueError:
        if re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", host) and ".." not in host:
            return host.lower()
    raise BridgeError("Enter a local hostname or IP address.")


def local_hostname():
    try:
        hostname = command(["/usr/sbin/scutil", "--get", "LocalHostName"]).decode().strip()
    except (BridgeError, UnicodeError):
        hostname = socket.gethostname().split(".")[0]
    return valid_host(hostname + ("" if hostname.endswith(".local") else ".local"))


def certificate_digest(certificate):
    der = ssl.PEM_cert_to_DER_cert(read_private_file(certificate).decode("ascii"))
    return hashlib.sha256(der).hexdigest()


def load_pairing(directory=PRIVATE_DIR):
    try:
        pairing = json.loads(read_private_file(Path(directory) / "pairing.local.json", 16384))
        if (pairing.get("version") != 1 or not isinstance(pairing.get("token"), str)
                or not re.fullmatch(r"[A-Za-z0-9_-]{40,128}", pairing["token"])
                or not isinstance(pairing.get("endpoint"), str)
                or not re.fullmatch(r"[0-9a-f]{64}", pairing.get("certificateSHA256", ""))):
            raise ValueError("Invalid pairing")
        endpoint = urlsplit(pairing["endpoint"])
        if (endpoint.scheme != "https" or not endpoint.hostname or endpoint.username
                or endpoint.password or endpoint.path or endpoint.query or endpoint.fragment
                or not endpoint.port or valid_host(endpoint.hostname) != endpoint.hostname):
            raise ValueError("Invalid pairing endpoint")
        return pairing
    except (OSError, ValueError, TypeError, AttributeError):
        raise BridgeError("Run bridge setup before serving or pairing a device.") from None


def setup(directory=PRIVATE_DIR, host=None, port=PORT):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if directory.is_symlink():
        raise BridgeError("The private bridge directory must not be a symbolic link.")
    os.chmod(directory, 0o700)
    host = valid_host(host) if host else local_hostname()
    endpoint = "https://" + ("[" + host + "]" if ":" in host else host) + ":" + str(port)
    certificate, private_key = directory / "certificate.pem", directory / "private-key.pem"
    if not certificate.exists() or not private_key.exists():
        # Private temporary paths, never stdout; openssl command contains no secret value.
        with tempfile.TemporaryDirectory(prefix=".identity-", dir=directory) as temporary:
            temporary = Path(temporary)
            command(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                     "-keyout", str(temporary / "key.pem"), "-out", str(temporary / "cert.pem"),
                     "-days", "3650", "-sha256", "-subj", "/CN=Information Bar Mobile"], timeout=30)
            write_private_file(private_key, read_private_file(temporary / "key.pem"))
            write_private_file(certificate, read_private_file(temporary / "cert.pem"))
    for path in (certificate, private_key):
        if path.is_symlink():
            raise BridgeError("Bridge identity files must not be symbolic links.")
        os.chmod(path, 0o600)
    try:
        token = load_pairing(directory)["token"]
    except BridgeError:
        token = secrets.token_urlsafe(32)
    pairing = {"version": 1, "endpoint": endpoint, "token": token,
               "certificateSHA256": certificate_digest(certificate)}
    write_private_file(directory / "pairing.local.json", encoded_json(pairing))
    return pairing


class SnapshotServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, pairing, snapshot_loader, tls_context):
        self.pairing = pairing
        self.snapshot_loader = snapshot_loader
        self.tls_context = tls_context
        self.connections = threading.BoundedSemaphore(24)
        super().__init__(address, SnapshotHandler)

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(5)
        return connection, address

    def process_request_thread(self, request, client_address):
        # TLS handshakes happen off the accept loop, so an idle client cannot block all peers.
        try:
            try:
                secure = self.tls_context.wrap_socket(request, server_side=True)
            except (ssl.SSLError, OSError):
                self.shutdown_request(request)
                return
            super().process_request_thread(secure, client_address)
        finally:
            self.connections.release()

    def process_request(self, request, client_address):
        if not self.connections.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.connections.release()
            raise

    def handle_error(self, request, client_address):
        pass


class SnapshotHandler(BaseHTTPRequestHandler):
    server_version = "InformationBar"
    sys_version = ""

    def log_message(self, format, *arguments):
        pass

    def reply(self, status, body=b""):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path != "/v1/snapshot":
            self.reply(404)
            return
        headers = self.headers.get_all("Authorization", [])
        expected = ("Bearer " + self.server.pairing["token"]).encode("utf-8")
        supplied = headers[0].encode("utf-8") if len(headers) == 1 else b""
        if not hmac.compare_digest(supplied, expected):
            self.reply(401)
            return
        try:
            body = encoded_json(self.server.snapshot_loader())
            if len(body) > MAX_RESPONSE_BYTES:
                raise BridgeError("The snapshot is too large.")
        except Exception:
            self.reply(503)
            return
        self.reply(200, body)

    def do_HEAD(self):
        self.reply(404)

    def __getattr__(self, name):
        if name.startswith("do_"):
            return self.do_HEAD
        raise AttributeError(name)

    do_POST = do_HEAD
    do_PUT = do_HEAD
    do_PATCH = do_HEAD
    do_DELETE = do_HEAD
    do_OPTIONS = do_HEAD
    do_TRACE = do_HEAD
    do_CONNECT = do_HEAD


def make_server(directory=PRIVATE_DIR, bind="0.0.0.0", port=PORT, snapshot_loader=snapshot):
    directory = Path(directory)
    pairing = load_pairing(directory)
    if not hmac.compare_digest(pairing["certificateSHA256"], certificate_digest(directory / "certificate.pem")):
        raise BridgeError("The bridge certificate changed. Run setup and pair the app again.")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(str(directory / "certificate.pem"), str(directory / "private-key.pem"))
    return SnapshotServer((bind, port), pairing, snapshot_loader, context)


def pair_device(identifier, directory=PRIVATE_DIR, bundle_id=DEFAULT_BUNDLE_ID):
    pairing = load_pairing(directory)
    payload = base64.urlsafe_b64encode(encoded_json(pairing)).decode("ascii").rstrip("=")
    url = "informationbar://pair?payload=" + payload
    digest = hashlib.sha256(url.encode("utf-8")).hexdigest()
    # devicectl receives this argument over the existing paired-device transport. Suppress
    # stdout/stderr because its success and failure diagnostics may repeat the launch URL.
    command(["/usr/bin/xcrun", "devicectl", "device", "process", "launch", "--device", identifier,
             "--terminate-existing", "--payload-url", url, bundle_id, "--accept-pairing-launch",
             "--pairing-digest", digest], timeout=45)


def status(directory=PRIVATE_DIR):
    pairing = load_pairing(directory)
    certificate_matches = hmac.compare_digest(
        pairing["certificateSHA256"], certificate_digest(Path(directory) / "certificate.pem"))
    current = snapshot()
    return {"endpoint": pairing["endpoint"], "certificateMatches": certificate_matches,
            "providers": [{key: item[key] for key in ("id", "status", "updatedAt", "checkedAt") if key in item}
                          for item in current["providers"]]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--setup", action="store_true")
    action.add_argument("--serve", action="store_true")
    action.add_argument("--status", action="store_true", help="Print connection metadata, never pairing secrets or metrics")
    action.add_argument("--pair-device", metavar="DEVICE_ID")
    parser.add_argument("--host", help="Reachable Mac hostname or IP saved in pairing settings")
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--bind", default="0.0.0.0", help="HTTPS listener address")
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("port must be between 1 and 65535")
    os.umask(0o077)
    try:
        if args.setup:
            setup(host=args.host, port=args.port)
            print("Bridge identity and private pairing file are ready.")
        elif args.pair_device:
            pair_device(args.pair_device, bundle_id=args.bundle_id)
            print("Pairing settings delivered to the iPhone app.")
        elif args.status:
            print(json.dumps(status(), indent=2))
        else:
            with make_server(bind=args.bind, port=args.port) as server:
                print("Information Bar HTTPS bridge is running.", flush=True)
                server.serve_forever()
    except KeyboardInterrupt:
        pass
    except BridgeError as error:
        parser.exit(1, str(error) + "\n")
    except Exception:
        parser.exit(1, "The bridge could not finish. Check the local setup and retry.\n")


if __name__ == "__main__":
    main()
