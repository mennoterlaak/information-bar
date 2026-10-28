#!/bin/bash
# Installs a private, read-only HTTPS companion; no provider credentials are copied.
set -euo pipefail
umask 077

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_python="$(command -v python3)"
task_mobile="$HOME/Library/Application Support/Information Bar/Mobile"
task_agents="$HOME/Library/LaunchAgents"
task_label="dev.starecat.InformationBar.mobile-bridge"
task_plist="$task_agents/$task_label.plist"

mkdir -p "$task_mobile" "$task_agents"
chmod 700 "$task_mobile"
"$task_python" "$task_root/scripts/mobile_bridge.py" --setup "$@"
install -m 600 "$task_root/scripts/mobile_bridge.py" "$task_mobile/mobile_bridge.py"

"$task_python" - "$task_python" "$task_mobile" "$task_plist" "$task_label" <<'PY'
import os
import json
from pathlib import Path
import plistlib
import sys
import tempfile
from urllib.parse import urlsplit

python, mobile, target, label = sys.argv[1:]
port = urlsplit(json.loads((Path(mobile) / "pairing.local.json").read_text())["endpoint"]).port
payload = {
    "Label": label,
    "ProgramArguments": [python, str(Path(mobile) / "mobile_bridge.py"), "--serve", "--port", str(port)],
    "RunAtLoad": True,
    "KeepAlive": True,
    "ThrottleInterval": 10,
    "ProcessType": "Background",
    "Umask": 0o077,
    "StandardOutPath": "/dev/null",
    "StandardErrorPath": "/dev/null",
    "AssociatedBundleIdentifiers": ["dev.starecat.InformationBar"],
}
fd, temporary = tempfile.mkstemp(prefix=".mobile-bridge-", dir=Path(target).parent)
try:
    with os.fdopen(fd, "wb") as output:
        plistlib.dump(payload, output)
    os.replace(temporary, target)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY

launchctl bootout "gui/$(id -u)/$task_label" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$task_plist"
launchctl kickstart "gui/$(id -u)/$task_label"
printf '%s\n' 'Information Bar mobile bridge installed and started.'
