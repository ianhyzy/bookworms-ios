#!/usr/bin/env python3
"""Keeps this Mac unlocked and dark for an overnight run of click tests, and puts it back after.

  on             on the home network only: keeps the display from sleeping through Amphetamine,
                 so macOS never locks, and turns the built-in display's brightness to zero
  off            puts back the display-sleep setting and the brightness that `on` found
  status         prints whether `on` is in effect and what it changed
  remember-home  records the current router as home

The Mac locks when its display turns off, and the lid must stay open: closing it turns the
display off. `on` changes no password or lock setting; the screen saver stays as Amphetamine's
session already sets it. Home is recognized by the router's hardware address, so it works over
Wi-Fi or a wired connection, and the address stays in `~/.config/bookworms/home-router`, out of
the repository. What `on` changed is saved in `~/.config/bookworms/overnight.json` until `off`.

Run it with the Bash sandbox off, because it talks to Amphetamine and the display.
Exit codes: 0 done, 1 not on the home network or nothing to do, 2 failed.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

CONFIG = Path.home() / ".config" / "bookworms"
HOME_ROUTER = CONFIG / "home-router"
STATE = CONFIG / "overnight.json"

# Reads or sets the built-in display's brightness (0 to 1) through DisplayServices, the private
# framework that the brightness keys use; no public API sets it.
BRIGHTNESS = r"""
import CoreGraphics
import Foundation
let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
typealias Set = @convention(c) (UInt32, Float) -> Int32
let get = unsafeBitCast(dlsym(handle, "DisplayServicesGetBrightness"), to: Get.self)
let set = unsafeBitCast(dlsym(handle, "DisplayServicesSetBrightness"), to: Set.self)
var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &count)
guard let display = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
    print("none"); exit(0)
}
if CommandLine.arguments.count > 1, let level = Float(CommandLine.arguments[1]) {
    exit(set(display, level))
}
var level: Float = 0
exit(get(display, &level) == 0 ? { print(level); return 0 }() : 1)
"""


def run(*command, **options):
    return subprocess.run(command, capture_output=True, text=True, **options)


def amphetamine(command):
    result = run("osascript", "-e", f'tell application "Amphetamine" to {command}')
    if result.returncode != 0:
        raise RuntimeError(f"Amphetamine: {result.stderr.strip()}")
    return result.stdout.strip()


def brightness(level=None):
    """Returns the built-in display's brightness, or None without one; sets it when given."""
    result = run("swift", "-", *([] if level is None else [str(level)]), input=BRIGHTNESS)
    if result.returncode != 0:
        raise RuntimeError(f"brightness: {result.stderr.strip()}")
    out = result.stdout.strip()
    return None if out == "none" or level is not None else float(out)


def router():
    """Returns the hardware address of the primary connection's router, as macOS recorded it.

    `arp` would need Local Network permission for whatever runs this script, and without it
    macOS hides the address; the system configuration store has no such limit.
    """
    def show(key):
        return run("scutil", input=f"show {key}\n").stdout

    service = re.search(r"PrimaryService : (\S+)", show("State:/Network/Global/IPv4"))
    if not service:
        return None
    found = re.search(r"ARPResolvedHardwareAddress : (\S+)",
                      show(f"State:/Network/Service/{service.group(1)}/IPv4"))
    return found.group(1) if found else None


def on():
    if STATE.exists():
        print("already on")
        return 1
    if not HOME_ROUTER.exists():
        print("no home router recorded; run `remember-home` on the home network first")
        return 1
    if router() != HOME_ROUTER.read_text().strip():
        print("not on the home network; nothing changed")
        return 1
    state = {"sessionWasActive": amphetamine("session is active") == "true"}
    if state["sessionWasActive"]:
        state["displaySleepAllowed"] = amphetamine("display sleep allowed") == "true"
        amphetamine("prevent display sleep")
    else:
        amphetamine("start new session with options "
                    "{duration:0, interval:0, displaySleepAllowed:false}")
    state["brightness"] = brightness()
    CONFIG.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state))
    if state["brightness"] is not None:
        brightness(0)
    print("on: the display stays awake and dark; keep the lid open")
    return 0


def off():
    if not STATE.exists():
        print("already off")
        return 1
    state = json.loads(STATE.read_text())
    if not state["sessionWasActive"]:
        amphetamine("end session")
    elif state.get("displaySleepAllowed"):
        amphetamine("allow display sleep")
    if state.get("brightness") is not None:
        brightness(state["brightness"])
    STATE.unlink()
    print("off: Amphetamine and the brightness are as they were")
    return 0


def status():
    if STATE.exists():
        print(f"on; saved before it: {STATE.read_text()}")
    else:
        print("off")
    home = HOME_ROUTER.exists() and router() == HOME_ROUTER.read_text().strip()
    print(f"home network: {'yes' if home else 'no'}")
    return 0


def remember_home():
    address = router()
    if not address:
        print("no router found")
        return 2
    CONFIG.mkdir(parents=True, exist_ok=True)
    HOME_ROUTER.write_text(address + "\n")
    print("recorded this router as home")
    return 0


if __name__ == "__main__":
    commands = {"on": on, "off": off, "status": status, "remember-home": remember_home}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        print(f"usage: {sys.argv[0]} {'|'.join(commands)}", file=sys.stderr)
        sys.exit(2)
    try:
        sys.exit(commands[sys.argv[1]]())
    except RuntimeError as error:
        print(error, file=sys.stderr)
        sys.exit(2)
