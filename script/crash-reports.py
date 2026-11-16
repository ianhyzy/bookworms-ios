#!/usr/bin/env python3
"""Collects Bookworms crash reports and prints the ones it hasn't seen before.

Sources, each skipped with a note when it can't be reached:

  mac         `~/Library/Logs/DiagnosticReports` and its `Retired` folder on this Mac, where
              macOS writes a report for every copy of the app (TestFlight and development).
              For a report whose crash is still in the system log, the summary adds Swift's
              `Fatal error` line, which the report itself doesn't carry.
  iphone      the paired iPhones' crash logs, copied with `devicectl` over the network.
  testflight  crashes a tester shared from TestFlight's prompt, for the iPhone and Mac app
              and the Apple TV app, read with the App Store Connect API key that
              `script/release.sh` uses (`. ~/.appstoreconnect/bookworms.env` first).

Apple TV devices are never contacted, so the script is safe during TV quiet hours; Apple TV
crashes arrive only through TestFlight. Reports are copied to `.local/crash-reports/<source>/`,
and `.local/crash-reports/seen.json` records which ones were printed. Run it with the Bash
sandbox off, because `devicectl` and `log` need it.

Usage: script/crash-reports.py [--all]   (--all prints every report, seen or not)
Exit codes: 0 no new reports, 1 new reports printed, 2 a source failed.
"""
import argparse
import base64
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STORE = ROOT / ".local" / "crash-reports"
SEEN = STORE / "seen.json"
API = "https://api.appstoreconnect.apple.com"
# The iPhone and Mac app and the Apple TV app.
BUNDLES = ("gay.ian.Bookworms.iOS", "gay.ian.Bookworms")
NAME = re.compile(r"^Bookworms[-_.]")


def summary(text):
    """Returns when, which build, what, and where from an `.ips` report's text."""
    header, _, body = text.partition("\n")
    try:
        head, report = json.loads(header), json.loads(body)
    except json.JSONDecodeError:
        return text.strip().splitlines()[:8]
    exception = report.get("exception", {})
    lines = [
        f"{head.get('timestamp', '?')}  {head.get('bundleID', '?')} "
        f"{head.get('app_version', '?')} ({head.get('build_version', '?')})  "
        f"{report.get('modelCode', '?')} {head.get('os_version', '?')}",
        f"{exception.get('type', '?')} {exception.get('signal', '')}".strip(),
    ]
    images = report.get("usedImages", [])
    threads = report.get("threads", [])
    crashed = next((t for t in threads if t.get("triggered")), None)
    for frame in (crashed or {}).get("frames", [])[:6]:
        index = frame.get("imageIndex", -1)
        image = images[index].get("name", "?") if 0 <= index < len(images) else "?"
        lines.append(f"  {image}  {frame.get('symbol', hex(frame.get('imageOffset', 0)))}")
    return lines


def fatal_error(text):
    """Returns Swift's `Fatal error` line logged just before a Mac crash, when the log has it."""
    try:
        report = json.loads(text.partition("\n")[2])
        pid, when = report["pid"], report["captureTime"][:19]
        start = datetime.datetime.strptime(when, "%Y-%m-%d %H:%M:%S")
    except (json.JSONDecodeError, KeyError, ValueError):
        return None
    window = [(start + datetime.timedelta(seconds=s)).strftime("%Y-%m-%d %H:%M:%S") for s in (-5, 2)]
    result = subprocess.run(
        ["/usr/bin/log", "show", "--start", window[0], "--end", window[1], "--style", "compact",
         "--predicate", f'processID == {pid} AND eventMessage CONTAINS "Fatal error"'],
        capture_output=True, text=True)
    found = [line for line in result.stdout.splitlines() if "Fatal error" in line]
    return found[-1].split(") ", 1)[-1] if found else None


def from_mac():
    folder = Path.home() / "Library" / "Logs" / "DiagnosticReports"
    reports = [*folder.glob("Bookworms*.ips"), *folder.glob("Retired/Bookworms*.ips")]
    for path in sorted(reports, key=lambda path: path.name):
        yield "mac", path.name, path.read_text(errors="replace")


def from_iphones():
    with tempfile.TemporaryDirectory() as scratch:
        listing = Path(scratch) / "devices.json"
        subprocess.run(["xcrun", "devicectl", "list", "devices", "--json-output", str(listing)],
                       capture_output=True, check=True)
        devices = json.loads(listing.read_text())["result"]["devices"]
        phones = [d for d in devices
                  if d["hardwareProperties"].get("deviceType") == "iPhone"
                  and d["hardwareProperties"].get("reality") == "physical"
                  and d["connectionProperties"].get("pairingState") == "paired"]
        for phone in phones:
            udid = phone["hardwareProperties"]["udid"]
            files = Path(scratch) / f"{udid}.json"
            result = subprocess.run(
                ["xcrun", "devicectl", "device", "info", "files", "--device", udid,
                 "--domain-type", "systemCrashLogs", "--json-output", str(files)],
                capture_output=True)
            if result.returncode != 0:
                print(f"iphone: {phone['deviceProperties']['name']} unreachable, skipped")
                continue
            for item in json.loads(files.read_text())["result"]["files"]:
                name = item["relativePath"]
                if not NAME.match(Path(name).name):
                    continue
                copy = Path(scratch) / Path(name).name
                subprocess.run(
                    ["xcrun", "devicectl", "device", "copy", "from", "--device", udid,
                     "--domain-type", "systemCrashLogs", "--source", name,
                     "--destination", str(copy)], capture_output=True, check=True)
                yield "iphone", copy.name, copy.read_text(errors="replace")


def token():
    """Signs a 10-minute App Store Connect token with the release key (ES256 through openssl)."""
    def b64(data):
        return base64.urlsafe_b64encode(data).rstrip(b"=").decode()
    now = int(datetime.datetime.now().timestamp())
    signing_input = (
        b64(json.dumps({"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}).encode())
        + "."
        + b64(json.dumps({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600,
                          "aud": "appstoreconnect-v1"}).encode()))
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.environ["ASC_KEY_PATH"]],
                         input=signing_input.encode(), capture_output=True, check=True).stdout
    # The DER signature is SEQUENCE { INTEGER r, INTEGER s }; JWT wants r and s as 32 bytes each.
    r_length = der[3]
    r = der[4:4 + r_length]
    s = der[6 + r_length:]
    raw = r[-32:].rjust(32, b"\0") + s[-32:].rjust(32, b"\0")
    return signing_input + "." + b64(raw)


def from_testflight():
    if "ASC_KEY_PATH" not in os.environ:
        print("testflight: no API key; run `. ~/.appstoreconnect/bookworms.env` first, skipped")
        return
    auth = {"Authorization": f"Bearer {token()}"}

    def get(path):
        with urllib.request.urlopen(urllib.request.Request(API + path, headers=auth)) as reply:
            return json.load(reply)

    for app in get("/v1/apps?fields[apps]=bundleId")["data"]:
        if app["attributes"]["bundleId"] not in BUNDLES:
            continue
        path = f"/v1/apps/{app['id']}/betaFeedbackCrashSubmissions?limit=200"
        for crash in get(path)["data"]:
            log = get(f"/v1/betaFeedbackCrashSubmissions/{crash['id']}/crashLog")
            text = log["data"]["attributes"].get("logText") or ""
            comment = crash["attributes"].get("comment")
            if comment:
                text = f"Tester's comment: {comment}\n{text}"
            yield "testflight", f"{crash['id']}.ips", text


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--all", action="store_true", help="print every report, seen or not")
    args = parser.parse_args()
    seen = set(json.loads(SEEN.read_text())) if SEEN.exists() else set()
    new, failed = 0, False
    for source in (from_mac, from_iphones, from_testflight):
        try:
            for origin, name, text in source():
                key = f"{origin}/{name}"
                copy = STORE / origin / name
                copy.parent.mkdir(parents=True, exist_ok=True)
                copy.write_text(text)
                if key in seen and not args.all:
                    continue
                seen.add(key)
                new += 1
                print(f"\n== {key}  ({copy})")
                print("\n".join(summary(text)))
                fatal = fatal_error(text) if origin == "mac" else None
                if fatal:
                    print(f"  {fatal}")
        except Exception as error:  # One unreachable source must not hide the others' reports.
            print(f"{source.__name__[5:]}: failed: {error}", file=sys.stderr)
            failed = True
    STORE.mkdir(parents=True, exist_ok=True)
    SEEN.write_text(json.dumps(sorted(seen), indent=1))
    print(f"\n{new} new report{'s' if new != 1 else ''}")
    sys.exit(2 if failed else 1 if new else 0)


if __name__ == "__main__":
    main()
